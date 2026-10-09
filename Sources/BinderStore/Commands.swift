import Darwin
import Foundation
import SpravaKit

/// The commands that change binders. The runtime runs them for the app over XPC; a development CLI can run them
/// too, refusing any folder lifeproj's registry lists. Requests and replies are JSON text, so the XPC interface
/// stays a few strings and the same code is tested in-process.
///
/// This part is who runs them (support folder, device, client) and the record of the cards Sprava wrote, which
/// every writer of cards uses; the command table itself is in the Services target.
public struct Commands: Sendable {
    public let support: URL
    public let deviceID: String
    public let client: String

    public init(support: URL, deviceID: String, client: String = "sprava/0.1") {
        self.support = support
        self.deviceID = deviceID
        self.client = client
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }

        package init(message: String) { self.message = message }
    }

    /// Proposal digests recorded when the runtime wrote or listed them, so an approval applies exactly what the
    /// person saw (architecture 4.6). Kept in Sprava's own state.
    package var digestsURL: URL { support.appendingPathComponent("runtime/proposal-digests.json") }

    /// Empty only when the file does not exist. One that exists but cannot be read or decoded throws, so it is never
    /// saved over with a few entries, which would leave every other waiting card unapprovable.
    package func loadDigests() throws -> [String: String] {
        do { return try StateFile.read([String: String].self, from: digestsURL) ?? [:] } catch {
            throw Failure(message: "Sprava's record of the cards it wrote cannot be read; it was left as it is")
        }
    }

    /// Fails loudly: a card whose digest was not kept cannot be approved, so its source must not be marked handled.
    func saveDigests(_ d: [String: String]) throws {
        try AtomicFile.makePrivateFolder(digestsURL.deletingLastPathComponent())
        try AtomicFile.write(try JSONEncoder().encode(d), to: digestsURL)
    }

    /// Records the digests of proposals Sprava itself just wrote (the clerk, the MCP listener, adoption).
    /// Only the ids Sprava just saved are trusted; a file another program dropped into the folder never is.
    /// Throws when the digests cannot be kept; the caller then treats the card as not made.
    public func trustProposals(_ ids: [String], in folder: URL) throws { try recordDigests(ids, in: folder) }

    /// Records a digest the caller took from bytes it read and checked itself, such as a stored card found to hold
    /// exactly what a retried request asks for. Throws `ProposalStore.Tampered` when the file no longer has them.
    public func trustChecked(_ id: String, digest: String, in folder: URL) throws {
        _ = try ProposalStore.load(id, in: folder, expectedDigest: digest)
        try withDigestsLock {
            var digests = try loadDigests()
            digests[key(folder, id)] = digest
            try saveDigests(digests)
        }
    }

    /// Runs a read, change and write of the digests file under a lock beside it. The file is shared by every binder
    /// and every process of this support folder, so a binder's lock cannot keep two updates from losing one.
    func withDigestsLock<T>(_ body: () throws -> T) throws -> T {
        try AtomicFile.makePrivateFolder(digestsURL.deletingLastPathComponent())
        let lockURL = digestsURL.deletingPathExtension().appendingPathExtension("lock")
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure(message: "Sprava's record of the cards it wrote cannot be locked") }
        defer { close(fd) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw Failure(message: "Sprava's record of the cards it wrote cannot be locked") }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    package func key(_ folder: URL, _ id: String) -> String { folder.path + "#" + id }

    /// Records the digest of the bytes `ProposalStore.save` wrote in this process, never one read back from the
    /// file afterwards: another program could have replaced it in between (architecture 4.6). A card this process
    /// did not write throws, and so does one whose file no longer holds those bytes.
    package func recordDigests(_ ids: [String], in folder: URL) throws {
        guard !ids.isEmpty else { return }
        try withDigestsLock {
            var digests = try loadDigests()
            for id in Set(ids) {
                guard let written = ProposalStore.writtenDigest(id, in: folder) else {
                    throw Failure(message: "proposal \(id) was not written by Sprava here; it is not trusted")
                }
                _ = try ProposalStore.load(id, in: folder, expectedDigest: written)
                digests[key(folder, id)] = written
            }
            try saveDigests(digests)
        }
    }

    /// The digests recorded for a card, under its folder as given and standardized; empty when none was recorded.
    func recordedDigests(_ id: String, in folder: URL) throws -> [String] {
        let digests = try loadDigests()
        return [folder, folder.standardizedFileURL].compactMap { digests[key($0, id)] }
    }

    /// Whether the binder holds this card exactly as Sprava last wrote it.
    public func isTrusted(_ id: String, in folder: URL) -> Bool {
        guard let recorded = try? recordedDigests(id, in: folder) else { return false }
        return ProposalStore.list(in: folder).contains { $0.0.id == id && recorded.contains($0.1) }
    }

    /// A stored card as Sprava last wrote it (architecture 4.6). Throws `ProposalStore.Tampered` when no digest was
    /// recorded for it or its bytes differ from the recorded ones: what another program wrote is never built on.
    public func loadTrusted(_ id: String, in folder: URL) throws -> Proposal {
        let recorded = try recordedDigests(id, in: folder)
        let current = ProposalStore.list(in: folder).first { $0.0.id == id }?.1
        guard let expected = recorded.first(where: { $0 == current }) ?? recorded.first else { throw ProposalStore.Tampered(id: id) }
        return try ProposalStore.load(id, in: folder, expectedDigest: expected)
    }

    /// Rewrites a stored card Sprava wrote and trusts the result. Every rewrite of a stored card goes through here:
    /// the bytes on disk are checked against the recorded digest first, so a card another program changed is left
    /// as it is, unverified, and a rewrite never makes it trusted again. Throws `ProposalStore.Tampered` then. The
    /// result is trusted by the digest of the bytes written, never by a read of the file afterwards.
    @discardableResult
    public func rewriteTrusted(_ id: String, in folder: URL, transform: (Proposal) throws -> Proposal) throws -> Proposal {
        let rewritten = try transform(try loadTrusted(id, in: folder))
        guard rewritten.id == id else { throw ProposalStore.Tampered(id: id) }
        try ProposalStore.save(rewritten, in: folder)
        try trustProposals([id], in: folder)
        return rewritten
    }
}

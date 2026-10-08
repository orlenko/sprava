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

    package func key(_ folder: URL, _ id: String) -> String { folder.path + "#" + id }

    package func recordDigests(_ ids: [String], in folder: URL) throws {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        var digests = try loadDigests()
        for (p, d) in ProposalStore.list(in: folder) where wanted.contains(p.id) { digests[key(folder, p.id)] = d }
        try saveDigests(digests)
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
    /// as it is, unverified, and a rewrite never makes it trusted again. Throws `ProposalStore.Tampered` then.
    @discardableResult
    public func rewriteTrusted(_ id: String, in folder: URL, transform: (Proposal) throws -> Proposal) throws -> Proposal {
        let rewritten = try transform(try loadTrusted(id, in: folder))
        guard rewritten.id == id else { throw ProposalStore.Tampered(id: id) }
        try ProposalStore.save(rewritten, in: folder)
        try trustProposals([id], in: folder)
        return rewritten
    }
}

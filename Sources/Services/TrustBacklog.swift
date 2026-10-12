import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Cards Sprava itself wrote (a recovery card from an outside edit, a hub completion's card) whose digests could not
/// be recorded, because Sprava's record of the cards it wrote could not be read or written (architecture 4.6). Each is
/// kept by the digest of the bytes this process wrote, in memory and in `runtime/trust-backlog.json`, and recorded on
/// a later pass through `Commands.trustChecked`, which owns that record. Never by what the file holds by then: a card
/// another program changed or removed in between is dropped from the backlog and stays untrusted.
public final class TrustBacklog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    /// Record key (`<folder>#<id>`) to the digest Sprava wrote.
    private var held: [String: String] = [:]

    public init(support: URL) {
        url = support.appendingPathComponent("runtime/trust-backlog.json")
    }

    /// How many cards wait to be trusted (those in memory; the file's are counted when it is read).
    public var count: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    /// A card this process did not write: there are no written bytes to trust it by.
    public struct NotWrittenHere: Error, CustomStringConvertible {
        public let id: String
        public var description: String { "proposal \(id) was not written by Sprava here; it is not trusted" }
    }

    /// Trusts `ids`, which Sprava just wrote in `folder`, by the digests of the bytes it wrote. Throws when they or
    /// earlier ones could not be recorded; they are kept for `retry`. An id this process did not write is never kept.
    public func trust(_ ids: [String], in folder: URL, commands: Commands) throws {
        var fresh: [String: String] = [:]
        var notWritten: String?
        for id in Set(ids) {
            if let digest = ProposalStore.writtenDigest(id, in: folder) { fresh[commands.key(folder, id)] = digest } else { notWritten = id }
        }
        try record(fresh, commands: commands)
        if let notWritten { throw NotWrittenHere(id: notWritten) }
    }

    /// Records the cards held back earlier. Throws while they still cannot be recorded.
    public func retry(commands: Commands) throws { try record([:], commands: commands) }

    /// `<folder>#<id>` back into its parts; a proposal id never holds `#`.
    static func split(_ key: String) -> (folder: URL, id: String)? {
        guard let hash = key.lastIndex(of: "#") else { return nil }
        let id = String(key[key.index(after: hash)...])
        guard ProposalStore.isValidID(id) else { return nil }
        return (URL(fileURLWithPath: String(key[..<hash]), isDirectory: true), id)
    }

    private func record(_ fresh: [String: String], commands: Commands) throws {
        lock.lock()
        defer { lock.unlock() }
        var pending = held.merging(fresh) { _, new in new }
        // A backlog file that cannot be read is left as it is and reported; what is in memory is still recorded.
        var backlogError: Error?
        do {
            let saved = try StateFile.read([String: String].self, from: url) ?? [:]
            pending.merge(saved) { mine, _ in mine }
        } catch {
            backlogError = error
        }
        guard !pending.isEmpty else {
            if let backlogError { throw backlogError }
            return
        }
        // Each card through BinderStore's own record (`proposal-digests.json` is its file), which checks the bytes
        // on disk against the digest first. The first failure to record keeps that card and every one after it.
        var kept: [String: String] = [:]
        var recordError: Error?
        for (key, digest) in pending.sorted(by: { $0.key < $1.key }) {
            guard let (folder, id) = Self.split(key) else { continue }
            // A card whose file no longer holds the bytes Sprava wrote (changed or removed) is never recorded.
            do { _ = try ProposalStore.load(id, in: folder, expectedDigest: digest) }
            catch is ProposalStore.Tampered { continue }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { continue }
            catch {
                kept[key] = digest
                if recordError == nil { recordError = error }
                continue
            }
            if recordError == nil {
                do { try commands.trustChecked(id, digest: digest, in: folder); continue } catch { recordError = error }
            }
            kept[key] = digest
        }
        held = kept
        if kept.isEmpty {
            if backlogError == nil { unlink(url.path) }
        } else if backlogError == nil, let data = try? JSONEncoder().encode(kept) {
            try? AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
            try? AtomicFile.write(data, to: url)
        }
        if let recordError { throw recordError }
        if let backlogError { throw backlogError }
    }
}

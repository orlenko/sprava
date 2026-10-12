import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Outside edits reach the op log when a background reader sees them, not only on Sprava's next write
/// (architecture 4.5): a hand edit followed by no write still becomes an `external_edit`.
public enum OutsideEdits {
    /// Settles each adopted binder this Mac owns. Returns the cards absorbing wrote ("an outside edit undid N
    /// changes"), by folder, for the caller to trust, and the folders that could not be settled.
    public static func settle(_ rows: [ShelfRow], deviceID: String, now: Date = Date()) -> (cards: [(URL, [String])], failed: [URL]) {
        var cards: [(URL, [String])] = []
        var failed: [URL] = []
        for row in rows where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            let store = TekaStore(folder: row.folder)
            do {
                try store.settle(now: now)
                if !store.createdProposals.isEmpty { cards.append((row.folder, store.createdProposals)) }
            } catch {
                failed.append(row.folder)
            }
        }
        return (cards, failed)
    }
}

extension OutsideEdits {
    /// One settling pass: binders settled, cards written and trusted, and what failed (counts only).
    public struct Settled: Sendable, Equatable {
        public var cards = 0
        /// Binders that could not be settled.
        public var unsettled = 0
        /// Cards Sprava wrote whose digests could not be recorded yet, these and earlier ones; `TrustBacklog` keeps
        /// them for the next pass.
        public var untrusted = 0

        public init() {}
    }

    /// Settles each binder this Mac owns, then trusts the cards that wrote, together with any held back before, on
    /// the command queue (`onCommandQueue`), where the commands that read the record run. A trust that fails is a
    /// failure of the job, never dropped: the card would otherwise wait forever and could not be approved.
    public static func settleAndTrust(_ rows: [ShelfRow], commands: Commands, backlog: TrustBacklog, now: Date = Date(),
                                      onCommandQueue: (() -> Void) -> Void) -> Settled {
        let settled = settle(rows, deviceID: commands.deviceID, now: now)
        var out = Settled()
        out.unsettled = settled.failed.count
        out.cards = settled.cards.count
        var failed = false
        onCommandQueue {
            do { try backlog.retry(commands: commands) } catch { failed = true }
            for (folder, ids) in settled.cards {
                do { try backlog.trust(ids, in: folder, commands: commands) } catch { failed = true }
            }
        }
        // A backlog file that cannot be read holds an unknown number: at least one.
        if failed { out.untrusted = max(1, backlog.count) }
        return out
    }
}

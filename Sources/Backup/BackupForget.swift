import BinderFormat
import Foundation
import SpravaKit

/// Forgetting a document for good (docs/backup.md §3.5): when a document is deleted for good from a binder
/// (binder-v0's expunge), its bytes leave the backups too, from every snapshot of the binder in the mirror and in
/// the second backup.
extension Backup {
    public struct Forgetting: Codable, Sendable, Equatable {
        public var backupID: String
        /// The document's path inside the binder ("documents/deed.pdf").
        public var path: String
        public var at: String
        /// When neither backup held it any more; nil while it waits.
        public var done: String?
        /// Why the last attempt failed; it is tried again at the next scheduled run.
        public var error: String?
    }

    /// Takes a document deleted for good out of every snapshot of its binder, in the mirror and the second backup,
    /// then prunes, so its bytes leave the backups as well. The request is recorded before restic runs, so one that
    /// fails (a disconnected disk) is retried by `maintain`, and `status().forgetting` tells the person when the
    /// backups no longer hold the document. Returns true once they do not.
    @discardableResult
    public func forgetDocument(in folder: URL, path: String, now: Date = Date()) throws -> Bool {
        guard DocumentPaths.isSafe(path, forFiling: false) else { throw Failure(message: "that document is not in the binder") }
        // A binder never backed up has no snapshot to hold the document.
        guard try Self.storedBackupID(folder) != nil else { return true }
        // Forgetting rewrites every snapshot under the binder's backup id: a copy that carries another live binder's
        // id would rewrite that binder's backups too, so it is refused (`claim`).
        var st = try state()
        let id = try claim(folder, &st)
        try save(st)
        step("forget.claimed")
        return try forget(id, path: path, now: now)
    }

    func forget(_ id: String, path: String, now: Date) throws -> Bool {
        var st = try state()
        if !st.forgetting.contains(where: { $0.backupID == id && $0.path == path && $0.done == nil }) {
            st.forgetting.append(Forgetting(backupID: id, path: path, at: ISOTime.string(now)))
            try save(st)
            step("forget.recorded")
        }
        try forgetPending(now: now)
        return try !state().forgetting.contains { $0.backupID == id && $0.path == path && $0.done == nil }
    }

    /// Runs every forgetting that waits, in each repository that may hold the binder's snapshots: the current two,
    /// and those its offload records name. Snapshots a rewrite replaced are renamed in every record that pins
    /// them, so an offloaded binder still restores. Returns how many still wait. Finished ones are shown for 30 days.
    @discardableResult
    func forgetPending(now: Date) throws -> Int {
        let s = try settings()
        var st = try state()
        st.forgetting.removeAll { f in f.done.flatMap { ISOTime.date($0) }.map { now.timeIntervalSince($0) > 30 * 86_400 } ?? false }
        for i in st.forgetting.indices where st.forgetting[i].done == nil {
            let f = st.forgetting[i]
            let records = st.offloaded.filter { $0.backupID == f.backupID }
            var repositories: [String] = []
            for repo in [s.primary, s.second] + records.flatMap({ [$0.repository, $0.secondRepository] }) {
                if let repo, !repositories.contains(repo) { repositories.append(repo) }
            }
            do {
                for repo in repositories {
                    let r = try engine(repo)
                    let tag = "binder:\(f.backupID)"
                    // The snapshots are journaled before restic replaces them, and renamed in the records only from
                    // what the repository shows afterwards, so a rewrite cut off at any point is reconciled later.
                    try reconcileRewrites(&st, in: repo)
                    st.rewrites.append(State.Rewrite(repository: repo, tag: tag, before: try r.snapshots(tag: tag).map(\.id)))
                    try save(st)
                    step("forget.journaled")
                    try r.rewrite(tag: tag, excluding: f.path)
                    step("forget.rewritten")
                    try reconcileRewrites(&st, in: repo)
                    step("forget.renamed")
                    try r.prune()
                }
                st.forgetting[i].done = ISOTime.string(now)
                st.forgetting[i].error = nil
            } catch {
                st.forgetting[i].error = "\(error)"
            }
            try save(st)
        }
        return st.forgetting.filter { $0.done == nil }.count
    }

    /// Renames, in every record, the snapshots that journaled rewrites replaced (in `repository` only, when given),
    /// then drops those journals. restic names the replaced snapshot in each new one's `original`, so this works
    /// whether the rewrite finished, was cut off partway (the rest are rewritten next time), or never started. A
    /// repository that cannot be read keeps its journal, and throws.
    func reconcileRewrites(_ st: inout State, in repository: String? = nil) throws {
        for journal in st.rewrites where repository == nil || journal.repository == repository {
            st.rename(try engine(journal.repository).replacements(of: Set(journal.before), tag: journal.tag))
            st.rewrites.removeAll { $0 == journal }
            try save(st)
        }
    }
}

extension Backup.State {
    /// Puts each snapshot a rewrite replaced under its new id, wherever a record names it.
    mutating func rename(_ ids: [String: String]) {
        guard !ids.isEmpty else { return }
        func renamed(_ id: String?) -> String? { id.map { ids[$0] ?? $0 } }
        for i in offloaded.indices {
            offloaded[i].snapshot = ids[offloaded[i].snapshot] ?? offloaded[i].snapshot
            offloaded[i].secondSnapshot = renamed(offloaded[i].secondSnapshot)
        }
        offloads = offloads.mapValues { job in
            var job = job
            job.snapshot = renamed(job.snapshot)
            job.secondSnapshot = renamed(job.secondSnapshot)
            return job
        }
        func renamed(_ r: Restored) -> Restored {
            var r = r
            r.snapshot = ids[r.snapshot] ?? r.snapshot
            r.secondSnapshot = renamed(r.secondSnapshot)
            return r
        }
        restored = restored.mapValues(renamed)
        restoredContents = restoredContents.mapValues { c in
            var c = c
            c.baseline = c.baseline.map(renamed)
            return c
        }
        binders = binders.mapValues { b in
            var b = b
            b.snapshot = renamed(b.snapshot)
            return b
        }
    }
}

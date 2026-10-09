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
        guard let id = try Self.storedBackupID(folder) else { return true }
        return try forget(id, path: path, now: now)
    }

    func forget(_ id: String, path: String, now: Date) throws -> Bool {
        var st = try state()
        if !st.forgetting.contains(where: { $0.backupID == id && $0.path == path && $0.done == nil }) {
            st.forgetting.append(Forgetting(backupID: id, path: path, at: ISOTime.string(now)))
            try save(st)
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
                    st.rename(try r.rewrite(tag: "binder:\(f.backupID)", excluding: f.path))
                    try save(st)
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
        restored = restored.mapValues { r in
            var r = r
            r.snapshot = ids[r.snapshot] ?? r.snapshot
            r.secondSnapshot = renamed(r.secondSnapshot)
            return r
        }
        binders = binders.mapValues { b in
            var b = b
            b.snapshot = renamed(b.snapshot)
            return b
        }
    }
}

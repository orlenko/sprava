import BinderFormat
import Foundation
import SpravaKit

/// Forgetting a document for good (docs/backup.md §3.5): when a document is deleted for good from a binder
/// (binder-v0's expunge), its bytes leave the backups too, from every snapshot of the binder in every repository that
/// may hold one. Only the snapshots made before the request are touched: a document filed later at the same path is
/// another document, and its backups stay.
extension Backup {
    public struct Forgetting: Codable, Sendable, Equatable {
        public var backupID: String
        /// The document's path inside the binder ("documents/deed.pdf").
        public var path: String
        public var at: String
        /// When no repository held it any more; nil while it waits.
        public var done: String?
        /// Why the last attempt failed; it is tried again at the next scheduled run.
        public var error: String?
        /// The moment of the request on this Mac's clock, which also dates restic's snapshots: only snapshots taken
        /// before it are rewritten (nil in older requests: `at` is used).
        public var requested: Double?
        /// Each repository that may hold the binder's snapshots, with the snapshots the request covers there and
        /// whether it is done there. Kept with the request, so a repository that was away is still done later.
        public var scopes: [Scope] = []
        /// The deletion this request is for (the caller's id for it, such as its op's id): asking again for the same
        /// deletion retries it, and a later deletion at the same path is a request of its own, with its own cutoff
        /// (nil in older requests).
        public var request: String?

        public struct Scope: Codable, Sendable, Equatable {
            public var repository: String
            /// The snapshots the request covers, renamed as rewrites replace them.
            public var snapshots: [String]
            public var done: Bool
            public var error: String?
        }

        init(backupID: String, path: String, at: String, requested: Double?, scopes: [Scope], request: String) {
            self.backupID = backupID
            self.path = path
            self.at = at
            self.requested = requested
            self.scopes = scopes
            self.request = request
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            backupID = try c.decode(String.self, forKey: .backupID)
            path = try c.decode(String.self, forKey: .path)
            at = try c.decode(String.self, forKey: .at)
            done = try c.decodeIfPresent(String.self, forKey: .done)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            requested = try c.decodeIfPresent(Double.self, forKey: .requested)
            scopes = try c.decodeIfPresent([Scope].self, forKey: .scopes) ?? []
            request = try c.decodeIfPresent(String.self, forKey: .request)
        }

        /// The latest snapshot time the request covers.
        var cutoff: Date? { requested.map { Date(timeIntervalSince1970: $0) } ?? ISOTime.date(at) }
    }

    /// Takes a document deleted for good out of every snapshot of its binder made before now, in every repository
    /// that may hold one, then prunes, so its bytes leave the backups as well. The request is recorded, with the
    /// snapshots it covers, before restic runs, so one that fails (a disconnected disk) is retried by `maintain`, and
    /// `status().forgetting` tells the person when the backups no longer hold the document. Returns true once they
    /// do not.
    ///
    /// `request` names the deletion (the id of the op that deleted the document): calling again with it retries
    /// that request, whose cutoff stays the first call's; a later deletion at the same path passes its own, so a
    /// document filed there in between is forgotten too, by its own request.
    @discardableResult
    public func forgetDocument(in folder: URL, path: String, request: String, now: Date = Date()) throws -> Bool {
        guard DocumentPaths.isSafe(path, forFiling: false) else { throw Failure(message: "that document is not in the binder") }
        // A binder never backed up has no snapshot to hold the document.
        guard try Self.storedBackupID(folder) != nil else { return true }
        // Forgetting rewrites every snapshot under the binder's backup id: a copy that carries another binder's id
        // would rewrite that binder's backups too, so it is refused (`claim`).
        var st = try state()
        let id = try claim(folder, &st)
        try save(st)
        step("forget.claimed")
        return try forget(id, path: path, request: request, now: now)
    }

    func forget(_ id: String, path: String, request: String, now: Date) throws -> Bool {
        guard !request.isEmpty else { throw Failure(message: "a deletion to forget needs its id") }
        var st = try state()
        let mine = { (f: Forgetting) in f.request == request && f.backupID == id && f.path == path }
        if let other = st.forgetting.first(where: { $0.request == request && !mine($0) }) {
            throw Failure(message: "request \(request) already forgets \(other.path) in another binder")
        }
        // A request finished long ago has left the list but not its tombstone: asking again is answered from it, and
        // never starts a new request that would reach snapshots made after it (a document filed later at the path).
        if let done = st.forgotten.first(where: { $0.request == request }) {
            guard done.backupID == id, done.path == path else {
                throw Failure(message: "request \(request) already forgot \(done.path) in another binder")
            }
            return true
        }
        if !st.forgetting.contains(where: mine) {
            let requested = Date()
            // The snapshots each reachable repository holds now; one that is away gets its share by time, later.
            let scopes = repositories(for: id, try settings(), st).map { repo in
                Forgetting.Scope(repository: repo, snapshots: (try? engine(repo).snapshots(tag: "binder:\(id)").map(\.id)) ?? [],
                                 done: false)
            }
            st.forgetting.append(Forgetting(backupID: id, path: path, at: ISOTime.string(now), requested: requested.timeIntervalSince1970,
                                            scopes: scopes, request: request))
            try save(st)
            step("forget.recorded")
        }
        try forgetPending(now: now)
        // A finished request is shown for 30 days, then only its tombstone stays (`forgotten`).
        let after = try state()
        return after.forgetting.first(where: mine).map { $0.done != nil } ?? after.forgotten.contains { $0.request == request }
    }

    /// Every repository that may hold a binder's snapshots: the current two, and every one a record names for it
    /// (offloaded, restored, being offloaded or being restored), since the person may have changed destinations.
    func repositories(for id: String, _ s: Settings, _ st: State) -> [String] {
        var out: [String] = []
        let restored = [st.restored[id], st.restoredContents[id]?.baseline].compactMap { $0 }
        let named: [String?] = [s.primary, s.second]
            + (st.binders[id]?.repositories ?? []).map(Optional.some)
            + st.offloaded.filter { $0.backupID == id }.flatMap { [$0.repository, $0.secondRepository] }
            + restored.flatMap { [$0.repository, $0.secondRepository] }
            + [st.offloads[id]?.repository, st.offloads[id]?.secondRepository]
        for repo in named { if let repo, !out.contains(repo) { out.append(repo) } }
        return out
    }

    /// Runs every forgetting that waits, repository by repository; each one done stays done. In each, the request
    /// covers the snapshots it listed (renamed as rewrites replace them) and any other taken before the request (a
    /// repository that was away, or a copy made since of an older snapshot); never one taken after it. Snapshots a
    /// rewrite replaced are renamed in every record that pins them, so an offloaded binder still restores. Returns
    /// how many still wait. Finished ones are shown for 30 days.
    @discardableResult
    func forgetPending(now: Date) throws -> Int {
        let s = try settings()
        var st = try state()
        // Finished requests are shown for 30 days; then only a tombstone of each stays, for good, so the same deletion
        // asked for again is known as done (`forget`).
        let expired = { (f: Forgetting) in f.done.flatMap { ISOTime.date($0) }.map { now.timeIntervalSince($0) > 30 * 86_400 } ?? false }
        for f in st.forgetting where expired(f) {
            guard let request = f.request, let done = f.done, !st.forgotten.contains(where: { $0.request == request }) else { continue }
            st.forgotten.append(State.Forgotten(request: request, backupID: f.backupID, path: f.path, done: done))
        }
        if st.forgetting.contains(where: expired) {
            st.forgetting.removeAll(where: expired)
            try save(st)
        }
        for i in st.forgetting.indices where st.forgetting[i].done == nil {
            let id = st.forgetting[i].backupID, path = st.forgetting[i].path
            // A repository a record has named since (destinations changed) is added, and kept with the request.
            for repo in repositories(for: id, s, st) where !st.forgetting[i].scopes.contains(where: { $0.repository == repo }) {
                st.forgetting[i].scopes.append(.init(repository: repo, snapshots: [], done: false))
            }
            for j in st.forgetting[i].scopes.indices where !st.forgetting[i].scopes[j].done {
                let repo = st.forgetting[i].scopes[j].repository
                do {
                    let r = try engine(repo)
                    let tag = "binder:\(id)"
                    try reconcileRewrites(&st, in: repo)
                    let listed = try r.snapshots(tag: tag)
                    let cutoff = st.forgetting[i].cutoff
                    let covered = Set(st.forgetting[i].scopes[j].snapshots)
                    let targets = listed.filter { snap in
                        covered.contains(snap.id) || (cutoff.flatMap { c in snap.date.map { $0 <= c } } ?? false)
                    }.map(\.id)
                    st.forgetting[i].scopes[j].snapshots = targets
                    if !targets.isEmpty {
                        // The snapshots are journaled before restic replaces them, and renamed in the records (this
                        // request's among them) only from what the repository shows afterwards, so a rewrite cut off
                        // at any point is reconciled later.
                        st.rewrites.append(State.Rewrite(repository: repo, tag: tag, before: listed.map(\.id)))
                        try save(st)
                        step("forget.journaled")
                        try r.rewrite(snapshots: targets, excluding: path)
                        step("forget.rewritten")
                        try reconcileRewrites(&st, in: repo)
                        step("forget.renamed")
                        try r.prune()
                    }
                    st.forgetting[i].scopes[j].done = true
                    st.forgetting[i].scopes[j].error = nil
                } catch {
                    st.forgetting[i].scopes[j].error = "\(error)"
                }
                try save(st)
            }
            let failed = st.forgetting[i].scopes.filter { !$0.done }
            if failed.isEmpty {
                st.forgetting[i].done = ISOTime.string(now)
                st.forgetting[i].error = nil
            } else {
                st.forgetting[i].error = failed.map { "\($0.repository): \($0.error ?? "not done")" }.joined(separator: "; ")
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
            st.rename(try engine(journal.repository).replacements(of: Set(journal.before), tag: journal.tag), in: journal.repository)
            st.rewrites.removeAll { $0 == journal }
            try save(st)
        }
    }
}

extension Backup.State {
    /// Puts each snapshot a rewrite of `repository` replaced under its new id, wherever a record names it in that
    /// repository. A copy of a snapshot that a rewrite made can have the same id in both repositories, so a field that
    /// names another repository keeps its id: that repository still holds the old snapshot until it is rewritten too.
    /// A field whose repository is not recorded (older records) is renamed.
    mutating func rename(_ ids: [String: String], in repository: String) {
        guard !ids.isEmpty else { return }
        func renamed(_ id: String?, _ repo: String?) -> String? {
            guard repo == nil || repo == repository else { return id }
            return id.map { ids[$0] ?? $0 }
        }
        func renamed(_ id: String) -> String { ids[id] ?? id }
        for i in offloaded.indices {
            if offloaded[i].repository == nil || offloaded[i].repository == repository { offloaded[i].snapshot = renamed(offloaded[i].snapshot) }
            offloaded[i].secondSnapshot = renamed(offloaded[i].secondSnapshot, offloaded[i].secondRepository)
        }
        offloads = offloads.mapValues { job in
            var job = job
            job.snapshot = renamed(job.snapshot, job.repository)
            job.secondSnapshot = renamed(job.secondSnapshot, job.secondRepository)
            return job
        }
        func renamed(_ r: Restored) -> Restored {
            var r = r
            if r.repository == nil || r.repository == repository { r.snapshot = renamed(r.snapshot) }
            r.secondSnapshot = renamed(r.secondSnapshot, r.secondRepository)
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
            b.snapshot = renamed(b.snapshot, nil)
            return b
        }
        for i in forgetting.indices {
            for j in forgetting[i].scopes.indices where forgetting[i].scopes[j].repository == repository {
                forgetting[i].scopes[j].snapshots = forgetting[i].scopes[j].snapshots.map { ids[$0] ?? $0 }
            }
        }
    }
}

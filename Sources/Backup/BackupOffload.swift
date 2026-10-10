import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit

/// Offloading a finished binder (docs/backup.md §6.1, §6.4).
extension Backup {
    // MARK: - Offload (docs/backup.md §6.1)

    public enum OffloadProgress: Equatable, Sendable {
        case waitingForICloud(Int)
        case done(Offloaded)
    }

    /// Offloads a finished binder. Runs every step it can now; when iCloud has not uploaded yet, it stops, and the
    /// queued request runs it again later.
    public func offload(_ folder: URL, deviceID: String, confirmOpenItems: Bool, now: Date = Date()) throws -> OffloadProgress {
        let s = try settings()
        guard s.primary != nil else { throw Failure(message: "set up backup first") }
        guard s.second != nil else { throw Failure(message: "offloading needs a second backup; choose one in Backup settings") }
        // An offload that stopped after its folder went to the Trash only has its records left to finish.
        if !FileManager.default.fileExists(atPath: folder.path),
           let leaving = try state().offloads.first(where: { $0.value.path == folder.standardizedFileURL.path && $0.value.stage == "leaving" }) {
            return try continueOffload(leaving.key, now: now)
        }
        try refuseSharedFate(s)
        let teka = Teka.read(folder)
        guard teka.isAdopted, Owner.device(of: folder) == deviceID else { throw Failure(message: "this binder is not managed by this Mac") }
        // Its hub slice is named by its catalog, so a binder whose name differs from its folder's (an outside edit may
        // have given it another binder's name) or cannot be read is put right first (`removeHubSlice`).
        guard !teka.federationBlocked else { throw Failure(message: Self.notOffloadable(teka) + "; put it right, then offload again") }
        guard !ProposalStore.list(in: folder).contains(where: { $0.0.state == "proposed" }) else {
            throw Failure(message: "cards are waiting for this binder; approve or reject them first")
        }
        try refuseUnreadableCards(folder)
        // Nothing may wait in intake/ or outgoing/. In intake/, `_converted/` is regenerable text, and `mail/` is
        // looked into: its messages and their attachment folders wait like any file, while a mail monitor's `.env`
        // and `state.json` are never filed (binder-v0 §3.3). A hidden file waits like any other; only what restic
        // leaves out (`excludes`) does not.
        // Only a folder that is not there is empty; one that cannot be listed may hold anything.
        func waiting(_ sub: String, except: Set<String>) throws -> Bool {
            let url = folder.appendingPathComponent(sub)
            var info = stat()
            if lstat(url.path, &info) != 0 {
                guard errno == ENOENT else { throw Failure(message: "\(sub)/ cannot be checked; nothing was removed") }
                return false
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw Failure(message: "\(sub)/ is not a real folder; nothing was removed")
            }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                throw Failure(message: "\(sub)/ cannot be listed; nothing was removed")
            }
            return names.contains { !Self.leftOut($0) && !except.contains($0) }
        }
        if try waiting("intake", except: ["mail", "_converted"]) || waiting("intake/mail", except: [".env", "state.json"]) {
            throw Failure(message: "files are waiting in intake/; deal with them first")
        }
        if try waiting("outgoing", except: []) { throw Failure(message: "files are waiting in outgoing/; deal with them first") }
        let open = teka.items.filter { $0.declaredStatus != .done && !$0.isDismissed }
        if !open.isEmpty, !confirmOpenItems { throw NeedsConfirmation(openItems: open.map(\.title)) }

        var st = try state()
        let id = try claim(folder, &st)
        try refuseSharedID(id, folder: folder, &st)
        // Saved before restic writes anything under the id (`backUp`), including the repository that may then hold
        // a snapshot even if the process stops before its id is recorded.
        st.rememberRepositories([s.primary], for: id)
        try save(st)
        step("offload.claimed")
        var job = st.offloads[id] ?? InProgress(path: folder.standardizedFileURL.path, stage: "start")
        // The binder stays writable while an offload waits for iCloud, which can take hours. One that changed since
        // its snapshot was verified (or never got that far) starts over, so what leaves the Mac is what the backups hold.
        // So does one whose snapshot is in a mirror the person has since replaced.
        // The folder's own metadata is part of the binder too (`RootMetadata`).
        // Kept inside the binder, so both backups hold it and their verification compares it (`keepRootMetadata`).
        let root = try Self.keepRootMetadata(folder)
        if try job.stage == "snapshotted"
            || (job.stage != "start" && (job.manifestSHA != Self.digest(Self.manifest(folder)) || job.root != root || job.repository != s.primary)) {
            if job.stage == "leaving" { st.offloaded.removeAll { $0.backupID == id } }
            job = InProgress(path: job.path, stage: "start")
        }
        if job.stage == "start" {
            // Nothing changed since a restore: the pinned snapshots are still the binder (§6.4), and the earlier
            // offload already recorded the person's confirmation. Only while the mirror is the one the pinned snapshot
            // is in, and still holds it: a mirror the person has since replaced does not, so it is taken again.
            let primary = try engine(s.primary)
            let current = try Self.manifest(folder)
            let baseline = st.restored[id].flatMap {
                $0.repository != nil && $0.repository == s.primary && $0.manifest == current && $0.rootEntry == root.entry ? $0 : nil
            }
            let unchanged = try baseline.map { b in try primary.snapshots(tag: "binder:\(id)").contains { $0.id == b.snapshot } } ?? false
            if !open.isEmpty, !unchanged {
                // The person's confirmation goes into the binder's history before the snapshot, once: an offload cut
                // off after writing it finds it there when it starts over the same day.
                let title = "Offloaded with \(open.count) open item(s), confirmed"
                let date = CalendarDate.today(now: now).description
                let logged = (teka.catalog?["processing_log"]?.arrayValue ?? []).contains {
                    $0["action"]?.stringValue == "offloaded" && $0["title"]?.stringValue == title && $0["date"]?.stringValue == date
                }
                if !logged {
                    let entry = JSONObject([(key: "entry", value: .obj([("action", .str("offloaded")), ("title", .string(title)),
                                                                        ("date", .string(date))]))])
                    try TekaStore(folder: folder).apply([.init(op: "add_log_entry", args: entry,
                                                               actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
                    step("offload.confirmed")
                }
            }
            job.openItemsConfirmed = open.count
            let manifest = try Self.manifest(folder)
            job.manifestSHA = Self.digest(manifest)
            job.root = root
            job.repository = s.primary
            if unchanged, let restored = st.restored[id] {
                // No new snapshot, but the backups are checked now, before the folder leaves on them (§6.4): each must
                // pass `restic check` and give back the binder from the pinned snapshot. One that does not keeps it here.
                try checkPinned(restored.snapshot, in: primary, named: "the iCloud mirror", id: id, manifest: manifest)
                job.snapshot = restored.snapshot
                job.bytes = restored.bytes ?? 0
                // A copy in a second backup the person has since replaced, or no longer in it, does not count; it is
                // copied again.
                let copyHolds = try restored.secondSnapshot.map { copy in
                    try restored.secondRepository == s.second && engine(s.second).snapshots(tag: "binder:\(id)").contains { $0.id == copy }
                } ?? false
                if copyHolds, let copy = restored.secondSnapshot {
                    try checkPinned(copy, in: engine(s.second), named: "the second backup", id: id, manifest: manifest)
                }
                job.secondSnapshot = copyHolds ? restored.secondSnapshot : nil
                job.secondRepository = copyHolds ? restored.secondRepository : nil
                job.stage = copyHolds ? "copied" : "verified"
            } else {
                let result = try primary.backup(folder, tags: ["sprava", "binder:\(id)", "offloaded"], excludes: Self.excludes, skipIfUnchanged: false)
                guard let snap = result.snapshot else { throw Failure(message: "the snapshot was not written") }
                step("offload.written")
                job.snapshot = snap
                job.bytes = result.bytes
                job.stage = "snapshotted"
                st.offloads[id] = job
                try save(st)
                step("offload.snapshotted")
                // Verify by restoring into a private temporary folder and comparing every file.
                let restored = try restoredManifest(snap, from: primary, id: id)
                guard restored == manifest else {
                    let missing = Set(manifest.keys).subtracting(restored.keys).count
                    let differ = manifest.filter { restored[$0.key] != nil && restored[$0.key] != $0.value }.count
                    throw Failure(message: "the snapshot does not match the binder (\(missing) missing, \(differ) different); nothing was removed")
                }
                job.stage = "verified"
            }
            st.offloads[id] = job
            try save(st)
            step("offload.verified")
        }
        return try continueOffload(id, now: now)
    }

    /// A name restic never backs up (`excludes`): Finder's `.DS_Store`, the binder lock, a temporary file.
    static func leftOut(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".teka.lock" || (name.hasPrefix(".") && name.hasSuffix(".tmp"))
    }

    /// Every entry of the proposals folder must be a card `ProposalStore.list` read: a card that cannot be read (bad
    /// JSON, a name that is not its id, a link) may be one waiting, and would leave unseen. A proposals folder that is
    /// not a real folder, or cannot be listed, may hold anything.
    func refuseUnreadableCards(_ folder: URL) throws {
        let cards = folder.appendingPathComponent(".sprava/proposals", isDirectory: true)
        let unreadable = Failure(message: "a card of this binder cannot be read (in .sprava/proposals); nothing was removed. Put it right, then offload again")
        var info = stat()
        if lstat(cards.path, &info) != 0 {
            guard errno == ENOENT else { throw unreadable }
            return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: cards.path) else { throw unreadable }
        let read = Set(ProposalStore.list(in: folder).map { "\($0.0.id).json" })
        if names.contains(where: { !Self.leftOut($0) && !read.contains($0) }) { throw unreadable }
    }

    /// The iCloud upload gate (§3.4, §6.1 step 4): nil once macOS reports every file of the mirror uploaded, else how
    /// many still wait. A mirror macOS does not report as in iCloud at all (iCloud Drive off, or a folder outside it)
    /// is a copy on this Mac only, so nothing leaves the Mac on it.
    func uploadPending(_ repository: URL) throws -> Int? {
        switch uploadCheck(repository) {
        case .uploaded: return nil
        case .waiting(let n): return n
        case .notInICloud:
            throw Failure(message: "the backup mirror is not in iCloud (is iCloud Drive on?), so it is not yet a copy off this Mac; nothing was removed")
        }
    }

    func continueOffload(_ id: String, now: Date) throws -> OffloadProgress {
        let s = try settings()
        var st = try state()
        guard var job = st.offloads[id] else { throw Failure(message: "no offload in progress") }
        let folder = URL(fileURLWithPath: job.path, isDirectory: true)
        // A folder already in the Trash only has its records left to finish.
        if job.stage == "leaving", !FileManager.default.fileExists(atPath: folder.path) { return try leave(id, folder: folder, &st, now: now) }
        // The settings may have changed while the offload waited, also while it waited to leave. A snapshot in a
        // mirror the person has since replaced is not in the backups any more (nor is the state snapshot holding the
        // record); a copy in a replaced second backup is made again, with the record and its state snapshot; and two
        // repositories that now share a fate are not two copies.
        try refuseSharedFate(s)
        guard job.repository != nil, job.repository == s.primary else {
            st.offloads[id] = nil
            if job.stage == "leaving" { st.offloaded.removeAll { $0.backupID == id } }
            try save(st)
            throw Failure(message: "the mirror changed during the offload; nothing was removed. Offload again to back up into the new one")
        }
        if job.secondSnapshot != nil, job.secondRepository != s.second {
            job.secondSnapshot = nil
            job.secondRepository = nil
            if job.stage == "copied" || job.stage == "leaving" {
                if job.stage == "leaving" { st.offloaded.removeAll { $0.backupID == id } }
                job.stage = "verified"
                job.stateSaved = false
            }
        }
        if job.stage == "leaving" { return try leave(id, folder: folder, &st, now: now) }
        let primary = try engine(s.primary)
        if job.stage == "verified" || job.stage == "waiting_for_upload" {
            if let n = try uploadPending(primary.repository) {
                job.stage = "waiting_for_upload"
                st.offloads[id] = job
                try save(st)
                return .waitingForICloud(n)
            }
            try refuseIfChanged(id, folder: folder, job, &st)
            let second = try engine(s.second)
            if job.secondSnapshot == nil {
                // A copy may have landed even if restic or Sprava stops before its id is recorded.
                st.rememberRepositories([s.second], for: id)
                try save(st)
                try second.copy(job.snapshot!, from: primary)
                let copies = try second.snapshots(tag: "binder:\(id)")
                guard let copy = copies.last else { throw Failure(message: "the copy to the second backup did not appear") }
                // restic copies only the data the second backup's index lacks, and never reads back what it lists, so
                // a damaged file there would pass unseen: the copy is restored and compared, as the snapshot was.
                guard try Self.digest(restoredManifest(copy.id, from: second, id: id)) == job.manifestSHA else {
                    throw Failure(message: "the copy in the second backup does not match the binder; nothing was removed. Check the second backup before offloading again")
                }
                // The copy carries the snapshot's tags, `offloaded` among them, which keeps it from retention. Tagging
                // it here would give it a new id (restic rewrites a snapshot to change its tags), so one without the
                // pin is refused instead, never recorded as pinned.
                guard copy.tags.contains("offloaded") else {
                    throw Failure(message: "the copy in the second backup is not pinned against retention; nothing was removed")
                }
                job.secondSnapshot = copy.id
                job.secondRepository = s.second
            }
            job.stage = "copied"
            st.offloads[id] = job
            try save(st)
            step("offload.copied")
        }
        guard job.stage == "copied", let snap = job.snapshot else { throw Failure(message: "offload stopped at \(job.stage)") }
        try refuseIfChanged(id, folder: folder, job, &st)
        let teka = Teka.read(folder)
        let record = Offloaded(
            backupID: id, name: teka.name, originalPath: job.path, snapshot: snap, repository: job.repository,
            secondSnapshot: job.secondSnapshot, secondRepository: job.secondRepository, bytes: job.bytes, at: ISOTime.string(now),
            summary: teka.catalog?["meta"]?["description"]?.stringValue ?? "",
            documents: (teka.catalog?["documents"]?.arrayValue ?? []).compactMap { d in
                guard let p = d["path"]?.stringValue else { return nil }
                return .init(title: d["title"]?.stringValue ?? p, path: p)
            },
            openItemsConfirmed: job.openItemsConfirmed, rootMetadata: job.root)
        // The hub stops showing it, as for a binder at disclosure none.
        try removeHubSlice(teka)
        step("offload.unpublished")
        // The record is kept before the folder goes, so a failure from here on can be finished, never lost.
        job.stage = "leaving"
        st.offloads[id] = job
        st.offloaded.removeAll { $0.backupID == id }
        st.offloaded.append(record)
        try save(st)
        step("offload.leaving")
        return try leave(id, folder: folder, &st, now: now)
    }

    /// The last step: the folder goes to the Trash, so nothing is destroyed until the person empties it, and the
    /// Shelf forgets it. Runs again after an interruption, from the record kept before.
    ///
    /// The record is the only way back to the binder in the app, so before the folder goes it is in the mirror too:
    /// a snapshot of Sprava's state is taken, and the folder waits until iCloud has it (a Mac lost before the next
    /// daily state snapshot would otherwise take the record with it).
    func leave(_ id: String, folder: URL, _ st: inout State, now: Date) throws -> OffloadProgress {
        guard var job = st.offloads[id], let record = st.offloaded.first(where: { $0.backupID == id }) else {
            throw Failure(message: "the offload's record is missing; nothing was removed")
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            if !job.stateSaved {
                try backUpState(now: now)
                st = try state()
                job.stateSaved = true
                st.offloads[id] = job
                try save(st)
            }
            if let n = try uploadPending(try engine(settings().primary).repository) {
                // The binder stays live while it waits: one that changed starts over, and is backed up as usual.
                try refuseIfChanged(id, folder: folder, job, &st)
                return .waitingForICloud(n)
            }
            // The replacement record is now durable off this Mac. Remove an earlier restored baseline's pins while
            // the live folder is still here; a disconnected old repository then stops safely before anything moves.
            if !job.oldPinsRemoved {
                if let earlier = st.restored[id] { try unpinEarlierRestore(earlier, replacedBy: record) }
                job.oldPinsRemoved = true
                st.offloads[id] = job
                if st.binders[id]?.snapshot != record.snapshot { st.binders[id]?.snapshot = record.snapshot }
                try save(st)
            }
            // The last comparison, the hub withdrawal and the move to the Trash run under the binder's write lock, so
            // no approval can land between them and leave with the folder while neither backup holds it, and no
            // publish can put the binder's slice back on the hub after it was taken off.
            var removal: Error?
            try TekaStore(folder: folder).withLock {
                try refuseIfChanged(id, folder: folder, job, &st)
                try removeHubSlice(Teka.read(folder))
                do { try removeFolder(folder) } catch { removal = error }
            }
            if let error = removal {
                st.offloaded.removeAll { $0.backupID == id }
                job.stage = "copied"
                job.stateSaved = false
                st.offloads[id] = job
                try? save(st)
                throw error
            }
            step("offload.removed")
        }
        // A Shelf that still lists the folder would later refuse its restore there ("a binder on the Shelf"), so a
        // failure here stops, and the retry finishes from the record (the folder is gone by then).
        try ShelfStore(supportDirectory: support).remove(folder)
        step("offload.unshelved")
        if st.binders[id]?.snapshot != record.snapshot { st.binders[id]?.snapshot = record.snapshot }
        st.offloads[id] = nil
        st.restored[id] = nil
        try save(st)
        return .done(record)
    }

    /// Removes only the old `offloaded` pins. Restic keeps the otherwise identical snapshots under ordinary
    /// retention, and `removeTag` is idempotent when another repository failed after this one succeeded.
    func unpinEarlierRestore(_ earlier: State.Restored, replacedBy current: Offloaded) throws {
        let s = try settings()
        func key(_ repository: String, _ snapshot: String) -> String {
            let real = Self.realPath(URL(fileURLWithPath: repository, isDirectory: true))
            return "\(real)\u{0}\(snapshot)"
        }
        let replacements = Set([
            (current.repository ?? s.primary).map { key($0, current.snapshot) },
            (current.secondRepository ?? s.second).flatMap { repo in current.secondSnapshot.map { key(repo, $0) } },
        ].compactMap { $0 })
        let old: [(String?, String?)] = [
            (earlier.repository ?? s.primary, earlier.snapshot),
            (earlier.secondRepository ?? s.second, earlier.secondSnapshot),
        ]
        for (repository, snapshot) in old {
            guard let repository, let snapshot, !replacements.contains(key(repository, snapshot)) else { continue }
            try engine(repository).removeTag("offloaded", from: snapshot)
        }
    }

    /// Restores a snapshot into a private temporary folder and lists it as `manifest` does; the folder is removed after.
    func restoredManifest(_ snapshot: String, from r: Restic, id: String) throws -> [String: String] {
        let verify = dir.appendingPathComponent("verify/\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: verify)
        try AtomicFile.makePrivateFolder(verify)
        defer { try? FileManager.default.removeItem(at: verify) }
        try r.restore(snapshot, into: verify)
        return try Self.manifest(verify)
    }

    /// A pinned snapshot an unchanged binder leaves on again: its repository passes `restic check`, and the snapshot
    /// restores, verified, to the binder as it is. A failure names the backup at fault and removes nothing.
    func checkPinned(_ snapshot: String, in r: Restic, named name: String, id: String, manifest: [String: String]) throws {
        do {
            try r.check()
            guard try restoredManifest(snapshot, from: r, id: id) == manifest else {
                throw Failure(message: "the pinned snapshot does not match the binder")
            }
        } catch {
            throw Failure(message: "\(name) failed its check (\(error)); nothing was removed. Check \(name) before offloading again")
        }
    }

    /// A copy of a binder carries its backup id. Offloading it would replace the other's offload record, the only
    /// way back to that binder, so an id another binder already uses is refused until the copy has its own. An
    /// offload left waiting at a folder that is gone (the binder moved meanwhile) starts over here instead.
    func refuseSharedID(_ id: String, folder: URL, _ st: inout State) throws {
        let path = folder.standardizedFileURL.path
        let refused = { (other: String) in
            Failure(message: "another binder (\(URL(fileURLWithPath: other).lastPathComponent)) has this binder's backup id; nothing was removed. "
                + "If this one is a copy, give it its own backup id; if that one is being restored, finish the restore first")
        }
        if let job = st.offloads[id], job.path != path {
            guard job.stage != "leaving", !FileManager.default.fileExists(atPath: job.path) else { throw refused(job.path) }
            st.offloads[id] = nil
        }
        let ownLeaving = st.offloads[id]?.stage == "leaving"
        if !ownLeaving, let record = st.offloaded.first(where: { $0.backupID == id }) { throw refused(record.originalPath) }
    }

    /// Stops an offload whose binder changed after its snapshot was verified: the job starts over next time.
    func refuseIfChanged(_ id: String, folder: URL, _ job: InProgress, _ st: inout State) throws {
        let manifest = try Self.manifest(folder), root = try Self.rootMetadata(folder)
        guard job.manifestSHA != Self.digest(manifest) || job.root != root else { return }
        st.offloads[id] = nil
        st.offloaded.removeAll { $0.backupID == id }
        try save(st)
        throw Failure(message: "the binder changed during the offload; nothing was removed. Offload again to back up the change")
    }

    /// Why a binder the hub does not trust with its name is not offloaded, in words the person can act on: the reasons
    /// it needs attention. For a stamped catalog without a valid `meta.disclosure` it says what that means on the hub:
    /// the hub withdraws the slice it recorded writing and publishes nothing from the binder until the level is set.
    static func notOffloadable(_ teka: Teka) -> String {
        let reasons = teka.states.filter { $0.key <= .needsAttention }.sorted { $0.key < $1.key }.flatMap(\.value)
        let disclosure = reasons.filter { $0.contains("meta.disclosure") }
        if !disclosure.isEmpty {
            let others = reasons.filter { !$0.contains("meta.disclosure") }
            return "this binder's catalog has no valid disclosure level (meta.disclosure), so the hub withdraws its slice and "
                + "publishes nothing from it; set its disclosure" + (others.isEmpty ? "" : ". It also needs attention: " + listed(others))
        }
        guard !reasons.isEmpty else { return "this binder's name (\(teka.name)) cannot be used as a hub file name" }
        return "this binder needs attention: " + listed(reasons)
    }

    static func listed(_ reasons: [String]) -> String {
        reasons.prefix(3).joined(separator: "; ") + (reasons.count > 3 ? "; and \(reasons.count - 3) more" : "")
    }

    /// Removes the binder's slice from the hub's spool. The slice is named by the catalog only for a binder that
    /// passes the hub's checks (its name is its folder's, as `HubLane.withdraw` requires); any other is refused, never
    /// guessed at, since the name might be another binder's slice. Only a slice that is already gone counts as
    /// removed: one that cannot be checked or removed (a spool that cannot be searched) stops the offload, which is
    /// retried, rather than leaving it on the hub with nothing to remove it later.
    ///
    /// After a rename, the slice published under the former name stays until the next publish moves it, and the
    /// cursors that name it leave with the binder; so it goes too, by the rule the hub follows
    /// (`HubLane.removeFormerSlice`): a name the binder lists as a former one, or a file still the one Sprava wrote.
    func removeHubSlice(_ teka: Teka) throws {
        guard !teka.federationBlocked else {
            throw Failure(message: Self.notOffloadable(teka)
                + "; it was not taken off the hub, and nothing was removed. The offload continues once it is put right")
        }
        let inbox = hubSpool.appendingPathComponent("inbox")
        var targets = [try HubLane.spoolFile(inbox, teka.name, ".agenda.json")]
        let cursors = HubLane.loadCursors(teka.folder)
        if let former = cursors.sliceName, former != teka.name, let hash = cursors.sliceHash,
           let url = try? HubLane.spoolFile(inbox, former, ".agenda.json") {
            let listed = (teka.catalog?["meta"]?["former_names"]?.arrayValue ?? []).contains { $0["name"]?.stringValue == former }
            // Read as the hub reads a slice (`HubLane.sliceHash(at:)`): a regular file of this user, never through a link.
            let data: Data? = if case .ok(let d) = SafeFile.read(url) { d } else { nil }
            let written = data.flatMap { try? JSONParser.parse($0).value }.flatMap { try? Canonical.hash(HubLane.stripGenerated($0)) } == hash
            if listed || written { targets.append(url) }
        }
        for target in targets {
            guard unlink(target.path) == 0 || errno == ENOENT else {
                let code = errno
                let reason = String(cString: strerror(code))
                throw Failure(message: "could not take the binder off the hub (\(reason)); the offload will retry")
            }
        }
    }

    /// Finishes offloads that were waiting for iCloud.
    public func continueOffloads(now: Date = Date()) -> [String: Result<OffloadProgress, Failure>] {
        var out: [String: Result<OffloadProgress, Failure>] = [:]
        let ids: [String]
        do { ids = try state().offloads.keys.sorted() } catch { return ["state": .failure(Failure(message: "\(error)"))] }
        for id in ids {
            do { out[id] = .success(try continueOffload(id, now: now)) } catch { out[id] = .failure(Failure(message: "\(error)")) }
        }
        return out
    }

    public func offloaded() throws -> [Offloaded] { try state().offloaded }

    public func pendingOffloads() throws -> [(path: String, stage: String)] {
        try state().offloads.values.map { ($0.path, $0.stage) }.sorted { $0.path < $1.path }
    }
}

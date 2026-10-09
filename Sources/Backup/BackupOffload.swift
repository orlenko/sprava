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
        // Nothing may wait in intake/ or outgoing/. In intake/, `_converted/` is regenerable text, and `mail/` is
        // looked into: its messages and their attachment folders wait like any file, while a mail monitor's `.env`
        // and `state.json` are never filed (binder-v0 §3.3).
        func waiting(_ sub: String, except: Set<String>) -> Bool {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(sub).path)) ?? []
            return names.contains { !$0.hasPrefix(".") && !except.contains($0) }
        }
        if waiting("intake", except: ["mail", "_converted"]) || waiting("intake/mail", except: ["state.json"]) {
            throw Failure(message: "files are waiting in intake/; deal with them first")
        }
        if waiting("outgoing", except: []) { throw Failure(message: "files are waiting in outgoing/; deal with them first") }
        let open = teka.items.filter { $0.declaredStatus != .done && !$0.isDismissed }
        if !open.isEmpty, !confirmOpenItems { throw NeedsConfirmation(openItems: open.map(\.title)) }

        var st = try state()
        let id = try claim(folder, &st)
        try refuseSharedID(id, folder: folder, &st)
        // Saved before restic writes anything under the id (`backUp`).
        try save(st)
        step("offload.claimed")
        var job = st.offloads[id] ?? InProgress(path: folder.standardizedFileURL.path, stage: "start")
        // The binder stays writable while an offload waits for iCloud, which can take hours. One that changed since
        // its snapshot was verified (or never got that far) starts over, so what leaves the Mac is what the backups hold.
        // So does one whose snapshot is in a mirror the person has since replaced.
        // The folder's own metadata is part of the binder too (`RootMetadata`).
        let root = try Self.rootMetadata(folder)
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

    func continueOffload(_ id: String, now: Date) throws -> OffloadProgress {
        let s = try settings()
        var st = try state()
        guard var job = st.offloads[id] else { throw Failure(message: "no offload in progress") }
        let folder = URL(fileURLWithPath: job.path, isDirectory: true)
        if job.stage == "leaving" { return try leave(id, folder: folder, &st) }
        // The settings may have changed while the offload waited. A snapshot in a mirror the person has since
        // replaced is not in the backups any more; a copy in a replaced second backup is made again; and two
        // repositories that now share a fate are not two copies.
        try refuseSharedFate(s)
        guard job.repository != nil, job.repository == s.primary else {
            st.offloads[id] = nil
            try save(st)
            throw Failure(message: "the mirror changed during the offload; nothing was removed. Offload again to back up into the new one")
        }
        if job.secondSnapshot != nil, job.secondRepository != s.second {
            job.secondSnapshot = nil
            job.secondRepository = nil
            if job.stage == "copied" { job.stage = "verified" }
        }
        let primary = try engine(s.primary)
        if job.stage == "verified" || job.stage == "waiting_for_upload" {
            if case .waiting(let n) = uploadCheck(primary.repository) {
                job.stage = "waiting_for_upload"
                st.offloads[id] = job
                try save(st)
                return .waitingForICloud(n)
            }
            try refuseIfChanged(id, folder: folder, job, &st)
            let second = try engine(s.second)
            if job.secondSnapshot == nil {
                try second.copy(job.snapshot!, from: primary)
                let copies = try second.snapshots(tag: "binder:\(id)")
                guard let copy = copies.last else { throw Failure(message: "the copy to the second backup did not appear") }
                // restic copies only the data the second backup's index lacks, and never reads back what it lists, so
                // a damaged file there would pass unseen: the copy is restored and compared, as the snapshot was.
                guard try Self.digest(restoredManifest(copy.id, from: second, id: id)) == job.manifestSHA else {
                    throw Failure(message: "the copy in the second backup does not match the binder; nothing was removed. Check the second backup before offloading again")
                }
                try? second.addTag("offloaded", to: copy.id)
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
        return try leave(id, folder: folder, &st)
    }

    /// The last step: the folder goes to the Trash, so nothing is destroyed until the person empties it, and the
    /// Shelf forgets it. Runs again after an interruption, from the record kept before.
    func leave(_ id: String, folder: URL, _ st: inout State) throws -> OffloadProgress {
        guard var job = st.offloads[id], let record = st.offloaded.first(where: { $0.backupID == id }) else {
            throw Failure(message: "the offload's record is missing; nothing was removed")
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            // The last comparison and the move to the Trash run under the binder's write lock, so no approval can
            // land between them and leave with the folder while neither backup holds it.
            var removal: Error?
            try TekaStore(folder: folder).withLock {
                try refuseIfChanged(id, folder: folder, job, &st)
                do { try removeFolder(folder) } catch { removal = error }
            }
            if let error = removal {
                st.offloaded.removeAll { $0.backupID == id }
                job.stage = "copied"
                st.offloads[id] = job
                try? save(st)
                throw error
            }
            step("offload.removed")
        }
        try? ShelfStore(supportDirectory: support).remove(folder)
        step("offload.unshelved")
        st.offloads[id] = nil
        st.restored[id] = nil
        try save(st)
        return .done(record)
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

import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit

/// Offloading a finished binder (docs/backup.md §6.1), first part: a verified snapshot pinned in the mirror and a
/// verified copy in the second backup, each step journaled so an interruption resumes or is abandoned safely. The
/// binder leaves this Mac in the next part (`leave`).
extension Backup {
    // MARK: - Offload (docs/backup.md §6.1)

    /// Open items stand in the way of an offload until the person confirms (decided 2026-10-08).
    public struct NeedsConfirmation: Error, CustomStringConvertible {
        public let openItems: [String]
        public var description: String { "\(openItems.count) open item(s) would stop showing anywhere" }
    }

    public enum OffloadProgress: Equatable, Sendable {
        case waitingForICloud(Int)
        /// Both backups hold a verified copy of the binder as it is.
        case copied
    }

    /// Offloads a finished binder. Runs every step it can now; when iCloud has not uploaded yet, it stops, and the
    /// queued request runs it again later.
    func offload(_ folder: URL, deviceID: String, confirmOpenItems: Bool, now: Date = Date()) throws -> OffloadProgress {
        let s = try settings()
        guard s.primary != nil else { throw Failure(message: "set up backup first") }
        guard s.second != nil else { throw Failure(message: "offloading needs a second backup; choose one in Backup settings") }
        // Abandonment has already proved the candidate snapshot unusable and journaled cleanup. Resume that cleanup
        // before reading or validating the live binder, and before its older offloaded record can look like a shared
        // backup id. This route is what makes every interruption after the journal durable.
        var recovery = try state()
        if let abandoning = recovery.offloads.first(where: {
            $0.value.stage == "abandoning" && Self.sameFolder(URL(fileURLWithPath: $0.value.path, isDirectory: true), folder)
        }) {
            try finishAbandoningOffload(abandoning.key, abandoning.value, &recovery)
            throw Failure(message: "the earlier offload was abandoned safely; offload again to back up the current binder")
        }
        try refuseSharedFate(s)
        let teka = Teka.read(folder)
        guard teka.isAdopted, Owner.device(of: folder) == deviceID else { throw Failure(message: "this binder is not managed by this Mac") }
        // Its hub slice is named by its catalog, so a binder whose name differs from its folder's (an outside edit may
        // have given it another binder's name) or cannot be read is put right first (`HubLane.withdrawBeforeLeaving`).
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
        try recoverInterrupted(id, &job, &st)
        // The public operation has the live binder in hand, so a completed verification/copy that became stale can
        // release its pins and restart immediately. A direct `continueOffload` still stops after cleanup, which lets
        // its caller report that the work it was continuing is no longer current.
        if job.stage != "start", job.stage != "snapshotted" || job.repository != s.primary {
            let changed = try job.manifestSHA != Self.digest(Self.manifest(folder)) || job.root != root || job.repository != s.primary
            if changed {
                try abandonOffload(id, job, &st)
                job = InProgress(path: job.path, stage: "start")
            }
        }
        if job.stage == "snapshotted", job.repository == s.primary { try verifySnapshotted(id, &job, &st) }
        if job.stage == "start" {
            let primary = try engine(s.primary)
            if !open.isEmpty {
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
            job.pinsBeforeWrite = try primary.snapshots(tag: "binder:\(id)").filter {
                $0.tags.contains("offloaded")
            }.map(\.id)
            job.stage = "writing"
            st.offloads[id] = job
            try save(st)
            let result = try primary.backup(folder, tags: ["sprava", "binder:\(id)", "offloaded"], excludes: Self.excludes, skipIfUnchanged: false)
            guard let snap = result.snapshot else { throw Failure(message: "the snapshot was not written") }
            step("offload.written")
            job.snapshot = snap
            job.bytes = result.bytes
            job.stage = "snapshotted"
            job.pinsBeforeWrite = nil
            st.offloads[id] = job
            try save(st)
            step("offload.snapshotted")
            // Verify by restoring into a private temporary folder and comparing every file.
            let restored = try restoredManifest(snap, from: primary, id: id)
            guard restored == manifest else {
                let missing = Set(manifest.keys).subtracting(restored.keys).count
                let differ = manifest.filter { restored[$0.key] != nil && restored[$0.key] != $0.value }.count
                try abandonOffload(id, job, &st)
                throw Failure(message: "the snapshot does not match the binder (\(missing) missing, \(differ) different); nothing was removed")
            }
            job.stage = "verified"
            st.offloads[id] = job
            try save(st)
            step("offload.verified")
        }
        return try continueOffload(id, now: now)
    }

    /// Brings a job an interruption left mid-step to a stage either entry point continues from: an abandonment cut
    /// off is finished (and reported), and a snapshot write cut off is adopted if restic committed it, its strays
    /// unpinned, or else started over. Restic may have committed the pinned snapshot just before Sprava stopped: the
    /// intent saved before the run tells that new pin from every older one.
    func recoverInterrupted(_ id: String, _ job: inout InProgress, _ st: inout State) throws {
        if job.stage == "abandoning" {
            try finishAbandoningOffload(id, job, &st)
            throw Failure(message: "the earlier offload was abandoned safely; offload again to back up the current binder")
        }
        guard job.stage == "writing" else { return }
        guard let repository = job.repository, let expected = job.manifestSHA, let pinsBefore = job.pinsBeforeWrite else {
            throw Failure(message: "the offload's snapshot intent is incomplete; nothing was removed")
        }
        let primary = try engine(repository)
        let known = Set(pinsBefore)
        let candidates = try primary.snapshots(tag: "binder:\(id)").filter { $0.tags.contains("offloaded") && !known.contains($0.id) }
        var recovered: Restic.Snapshot?
        for candidate in candidates {
            let manifest = try restoredManifest(candidate.id, from: primary, id: "writing-\(id)")
            if Self.digest(manifest) == expected, recovered == nil { recovered = candidate }
        }
        for candidate in candidates where candidate.id != recovered?.id {
            try primary.removeTag("offloaded", from: candidate.id)
        }
        if let recovered {
            job.snapshot = recovered.id
            job.bytes = recovered.bytes ?? 0
            job.stage = "snapshotted"
        } else {
            job.stage = "start"
        }
        job.pinsBeforeWrite = nil
        st.offloads[id] = job
        try save(st)
    }

    /// A crash after recording a snapshot resumes verification of that exact pinned snapshot. Replacing it on every
    /// retry would leave each abandoned `offloaded` tag outside retention for ever.
    func verifySnapshotted(_ id: String, _ job: inout InProgress, _ st: inout State) throws {
        guard let snap = job.snapshot, let expected = job.manifestSHA else {
            throw Failure(message: "the offload's recorded snapshot is incomplete; nothing was removed")
        }
        let restored = try restoredManifest(snap, from: engine(job.repository), id: id)
        guard Self.digest(restored) == expected else {
            try abandonOffload(id, job, &st)
            throw Failure(message: "the snapshot does not match the binder as it was snapshotted; nothing was removed")
        }
        job.stage = "verified"
        st.offloads[id] = job
        try save(st)
        step("offload.verified")
    }

    /// Takes the pins off what this job may have in its second backup: its recorded copy, and any copy that landed
    /// before its id was saved (one not pinned before the copy ran).
    func releaseSecond(_ id: String, _ job: InProgress) throws {
        guard let repository = job.secondRepository else { return }
        let second = try engine(repository)
        if let copy = job.secondSnapshot { try second.removeTag("offloaded", from: copy) }
        if let before = job.secondPinsBefore {
            for snap in try second.snapshots(tag: "binder:\(id)") where snap.tags.contains("offloaded") && !before.contains(snap.id) {
                try second.removeTag("offloaded", from: snap.id)
            }
        }
    }

    /// A name restic never backs up (`excludes`): Finder's `.DS_Store`, the binder lock, a temporary file (`.*.tmp`,
    /// as `manifest` reads it).
    static func leftOut(_ name: String) -> Bool {
        name == ".DS_Store" || name == ".teka.lock" || (name.utf8.count >= 5 && name.hasPrefix(".") && name.hasSuffix(".tmp"))
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

    /// Restores a snapshot into a private temporary folder and lists it as `manifest` does; the folder is removed after.
    func restoredManifest(_ snapshot: String, from r: Restic, id: String) throws -> [String: String] {
        let verify = dir.appendingPathComponent("verify/\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: verify)
        try AtomicFile.makePrivateFolder(verify)
        defer { try? FileManager.default.removeItem(at: verify) }
        try r.restore(snapshot, into: verify)
        return try Self.manifest(verify)
    }

    /// A copy of a binder carries its backup id. Offloading it would replace the other's offload record, the only
    /// way back to that binder, so an id another binder already uses is refused until the copy has its own. An
    /// offload left waiting at a folder that is gone (the binder moved meanwhile) starts over here instead.
    func refuseSharedID(_ id: String, folder: URL, _ st: inout State) throws {
        let refused = { (_: String) in
            Failure(message: "another binder has this binder's backup id; nothing was removed. "
                + "If this one is a copy, give it its own backup id; if that one is being restored, finish the restore first")
        }
        // The same folder reached another way (through a link, another case) is this binder, not a copy.
        if let job = st.offloads[id], !Self.sameFolder(URL(fileURLWithPath: job.path, isDirectory: true), folder) {
            guard job.stage != "leaving", Self.folderEntry(URL(fileURLWithPath: job.path, isDirectory: true)) == .missing else {
                throw refused(job.path)
            }
            // Its pins are released before it is forgotten; a repository that is away keeps it for the next try.
            try abandonOffload(id, job, &st)
        }
        let ownLeaving = st.offloads[id]?.stage == "leaving"
        if !ownLeaving, let record = st.offloaded.first(where: { $0.backupID == id }) { throw refused(record.originalPath) }
    }

    /// Stops an offload whose binder changed after its snapshot was verified: the job starts over next time.
    func refuseIfChanged(_ id: String, folder: URL, _ job: InProgress, _ st: inout State) throws {
        let manifest = try Self.manifest(folder), root = try Self.rootMetadata(folder)
        guard job.manifestSHA != Self.digest(manifest) || job.root != root else { return }
        try abandonOffload(id, job, &st)
        throw Failure(message: "the binder changed during the offload; nothing was removed. Offload again to back up the change")
    }

    /// Releases the retention pins of an offload that was proven unusable while its live binder is still present.
    /// The abandoning stage is durable before a tag change can replace a snapshot id. A retry then goes directly to
    /// idempotent cleanup instead of trying to restore the obsolete id as a still-snapshotted job.
    func abandonOffload(_ id: String, _ job: InProgress, _ st: inout State) throws {
        var marked = job
        marked.stage = "abandoning"
        st.offloads[id] = marked
        try save(st)
        step("offload.abandoning")
        try finishAbandoningOffload(id, marked, &st)
    }

    func finishAbandoningOffload(_ id: String, _ job: InProgress, _ st: inout State) throws {
        // The live binder is still here, so these no-longer-current snapshots need no retention pin. Remove the pins
        // before forgetting the job; if a repository is away, the job remains and the cleanup is retried. removeTag is
        // idempotent if a crash lands between repositories or before the state save.
        if let repository = job.repository {
            let primary = try engine(repository)
            if let snapshot = job.snapshot { try primary.removeTag("offloaded", from: snapshot) }
            // A write cut off before its snapshot id was saved leaves a pin only the intent can tell apart.
            if let before = job.pinsBeforeWrite {
                for snap in try primary.snapshots(tag: "binder:\(id)") where snap.tags.contains("offloaded") && !before.contains(snap.id) {
                    try primary.removeTag("offloaded", from: snap.id)
                }
            }
        }
        try releaseSecond(id, job)
        st.offloads[id] = nil
        // Only the record this offload made (once it had one), never an earlier offload's.
        st.offloaded.removeAll { $0.backupID == id && job.snapshot != nil && $0.snapshot == job.snapshot }
        try save(st)
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
        guard !reasons.isEmpty else { return "this binder's name cannot be used as a hub file name" }
        return "this binder needs attention: " + listed(reasons)
    }

    static func listed(_ reasons: [String]) -> String {
        reasons.prefix(3).joined(separator: "; ") + (reasons.count > 3 ? "; and \(reasons.count - 3) more" : "")
    }

    /// Removes the binder's slice from the hub's spool. The slice is named by the catalog only for a binder that

    func continueOffload(_ id: String, now: Date) throws -> OffloadProgress {
        let s = try settings()
        var st = try state()
        guard var job = st.offloads[id] else { throw Failure(message: "no offload in progress") }
        let folder = URL(fileURLWithPath: job.path, isDirectory: true)
        // An interruption is recovered here as well as in `offload`, so a queued continuation never sticks.
        try recoverInterrupted(id, &job, &st)
        guard job.stage != "start" else {
            throw Failure(message: "the offload starts over; offload the binder again")
        }
        // A binder that moved while its offload waited is not where the offload left it: the offload is abandoned,
        // its pins released, and the binder is offloaded again from where it is now.
        switch Self.folderEntry(folder) {
        case .present: break
        case .unavailable: throw Failure(message: "the binder's folder cannot be checked; the offload was left unfinished")
        case .missing:
            try abandonOffload(id, job, &st)
            throw Failure(message: "the binder is no longer where its offload started; nothing was removed. Offload it again")
        }
        // The settings may have changed while the offload waited. A snapshot in a mirror the person has since replaced
        // is not in the backups any more; a copy in a replaced second backup is made again; and two repositories that
        // now share a fate are not two copies. Pins in a repository left behind are released, not forgotten.
        try refuseSharedFate(s)
        guard job.repository != nil, job.repository == s.primary else {
            try abandonOffload(id, job, &st)
            throw Failure(message: "the mirror changed during the offload; nothing was removed. Offload again to back up into the new one")
        }
        if job.secondRepository != nil, job.secondRepository != s.second {
            try releaseSecond(id, job)
            job.secondSnapshot = nil
            job.secondRepository = nil
            job.secondPinsBefore = nil
            if job.stage == "copied" || job.stage == "copying" {
                job.stage = "verified"
                job.stateSaved = false
            }
            st.offloads[id] = job
            try save(st)
        }
        if job.stage == "snapshotted" { try verifySnapshotted(id, &job, &st) }
        let primary = try engine(s.primary)
        if job.stage == "verified" || job.stage == "waiting_for_upload" || job.stage == "copying" {
            if job.stage != "copying", let n = try uploadPending(primary.repository) {
                job.stage = "waiting_for_upload"
                st.offloads[id] = job
                try save(st)
                return .waitingForICloud(n)
            }
            try refuseIfChanged(id, folder: folder, job, &st)
            let second = try engine(s.second)
            if job.secondSnapshot == nil {
                // The copy's intent is saved first: a copy may land even if restic or Sprava stops before its id is
                // recorded, and it is then found again, or unpinned if the offload is abandoned.
                if job.stage != "copying" {
                    st.rememberRepositories([s.second], for: id)
                    job.secondRepository = s.second
                    job.secondPinsBefore = try second.snapshots(tag: "binder:\(id)").filter { $0.tags.contains("offloaded") }.map(\.id)
                    job.stage = "copying"
                    st.offloads[id] = job
                    try save(st)
                    step("offload.copying")
                }
                try second.copy(job.snapshot!, from: primary)
                let copies = try second.snapshots(tag: "binder:\(id)")
                // Another operation may have added a newer snapshot for this binder after `copy` landed but before
                // its id was recorded. Prefer the source id (restic normally preserves it), then search only pinned
                // copies and prove their contents. Never let list order select an unrelated drill snapshot.
                let ordered = copies.sorted { ($0.id == job.snapshot) && ($1.id != job.snapshot) }
                var copy: Restic.Snapshot?
                for candidate in ordered where candidate.tags.contains("offloaded") {
                    if let manifest = try? restoredManifest(candidate.id, from: second, id: id),
                       Self.digest(manifest) == job.manifestSHA {
                        copy = candidate
                        break
                    }
                }
                guard let copy else {
                    throw Failure(message: "the copy in the second backup does not match the binder; nothing was removed. Check the second backup before offloading again")
                }
                job.secondSnapshot = copy.id
                job.secondPinsBefore = nil
            }
            job.stage = "copied"
            st.offloads[id] = job
            try save(st)
            step("offload.copied")
        }
        guard job.stage == "copied" else { throw Failure(message: "offload stopped at \(job.stage)") }
        // Both backups hold a verified copy; the binder leaves this Mac in the next step (`leave`).
        try refuseIfChanged(id, folder: folder, job, &st)
        return .copied
    }

    func continueOffloads(now: Date = Date()) -> [String: Result<OffloadProgress, Failure>] {
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

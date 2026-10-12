import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit

/// Offloading a finished binder (docs/backup.md §6.1): a verified snapshot pinned in the mirror and a verified copy
/// in the second backup, each step journaled so an interruption resumes or is abandoned safely; then the binder
/// leaves this Mac (`leave`, in BackupLeave.swift).
extension Backup {
    // MARK: - Offload (docs/backup.md §6.1)

    /// Open items stand in the way of an offload until the person confirms (decided 2026-10-08).
    public struct NeedsConfirmation: Error, CustomStringConvertible {
        public let openItems: [String]
        public let digest: String
        init(items: [Item]) { openItems = items.map(\.title); digest = Backup.confirmationDigest(items) }
        public var description: String { "\(openItems.count) open item(s) would stop showing anywhere" }
    }

    public enum OffloadProgress: Equatable, Sendable {
        case waitingForICloud(Int)
        /// The binder left this Mac; its record is the way back.
        case done(Offloaded)
    }

    /// Offloads a finished binder. Runs every step it can now; when iCloud has not uploaded yet, it stops, and the
    /// queued request runs it again later. `nameCollides` answers, when the binder leaves, whether another binder
    /// here shares its name (`HubLane.collidingFolders`): its hub slice is then withdrawn only by Sprava's record.
    public func offload(_ folder: URL, deviceID: String, confirmOpenItems: Bool, reviewedDigest: String? = nil, nameCollides: (URL) -> Bool,
                        now: Date = Date()) throws -> OffloadProgress {
        let s = try settings()
        guard s.primary != nil else { throw Failure(message: "set up backup first") }
        guard s.second != nil else { throw Failure(message: "offloading needs a second backup; choose one in Backup settings") }
        for path in [s.primary, s.second].compactMap({ $0 }) {
            try Self.refuseRepositoryOverlap(URL(fileURLWithPath: path), binders: [folder])
        }
        // An offload that stopped after its folder went to the Trash only has its records left to finish.
        if let leaving = try state().offloads.first(where: {
            $0.value.stage == "leaving" && Self.sameFolder(URL(fileURLWithPath: $0.value.path, isDirectory: true), folder)
        }) {
            if leaving.value.leavingTarget != nil || Self.folderEntry(folder) == .missing || !Self.isTheBinder(folder, leaving.key, leaving.value) {
                return try continueOffload(leaving.key, now: now, nameCollides: nameCollides)
            }
            if Self.folderEntry(folder) == .unavailable {
                throw Failure(message: "the binder's folder cannot be checked; the offload was left unfinished")
            }
        }
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
        let open = try Self.refuseNotReady(folder, teka)
        if (!open.isEmpty && !confirmOpenItems) || (reviewedDigest != nil && reviewedDigest != Self.confirmationDigest(open)) {
            throw NeedsConfirmation(items: open)
        }

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
        if job.repository == s.primary { try requireMirrorSnapshot(id, &job, &st) }
        if job.stage == "snapshotted", job.repository == s.primary { try verifySnapshotted(id, &job, &st) }
        if job.stage == "start" {
            let primary = try engine(s.primary)
            if !open.isEmpty {
                // The person's confirmation goes into the binder's history before the snapshot, once for these items:
                // an offload cut off after writing it finds it there when it starts over the same day, while a
                // confirmation of other items (one replaced meanwhile) is a new entry.
                let title = "Offloaded with \(open.count) open item(s), confirmed"
                let date = CalendarDate.today(now: now).description
                let confirmed = Self.digest(Dictionary(open.map { (Self.confirmationKey($0), "") }, uniquingKeysWith: { first, _ in first }))
                let logged = (teka.catalog?["processing_log"]?.arrayValue ?? []).contains {
                    $0["action"]?.stringValue == "offloaded" && $0["date"]?.stringValue == date && $0["confirmed"]?.stringValue == confirmed
                }
                if !logged {
                    let entry = JSONObject([(key: "entry", value: .obj([("action", .str("offloaded")), ("title", .string(title)),
                                                                        ("date", .string(date)), ("confirmed", .string(confirmed))]))])
                    try TekaStore(folder: folder).apply([.init(op: "add_log_entry", args: entry,
                                                               actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
                    step("offload.confirmed")
                }
            }
            job.openItemsConfirmed = open.count
            job.confirmedItems = open.map(Self.confirmationKey)
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
        return try continueOffload(id, now: now, nameCollides: nameCollides)
    }

    func continueOffload(_ id: String, now: Date, nameCollides: (URL) -> Bool) throws -> OffloadProgress {
        let s = try settings()
        var st = try state()
        guard var job = st.offloads[id] else { throw Failure(message: "no offload in progress") }
        let folder = URL(fileURLWithPath: job.path, isDirectory: true)
        if job.stage == "leaving" {
            // A move to the Trash that was cut off: a binder still set aside under its staging name is put back, and
            // one whose rename never happened is where it was; either goes through every check below again before
            // leaving. Only a binder that is gone skips them: its records are all that is left.
            if try Self.undoStagedMove(&job, id) {
                st.offloads[id] = job
                try save(st)
            } else if job.leavingTarget != nil {
                // Gone to the Trash: its record is offloaded already, and only the cleanup is left.
                return try leave(id, folder: folder, &st, nameCollides: nameCollides, now: now)
            } else if !(Self.folderEntry(folder) == .present && Self.isTheBinder(folder, id, job)) {
                // The offload's path no longer leads to the binder, which is still at its own place (a link removed or
                // retargeted): it has not left, and the offload is abandoned, not finished.
                if Self.isAtItsRealPlace(id, job, folder) {
                    try abandonOffload(id, job, &st)
                    throw Failure(message: "the binder is no longer where its offload started; nothing was removed. Offload it again")
                }
                // Gone from its path with no move recorded, which `leave` explains is never abandoned; finished only
                // while the backups still hold the copies its record names.
                try requireRecordedCopies(id, job, s)
                return try leave(id, folder: folder, &st, nameCollides: nameCollides, now: now)
            }
        }
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
            // A checkpoint holding this job as leaving names that copy: it stays pinned (see `finishAbandoningOffload`).
            if !job.checkpointed { try releaseSecond(id, job) }
            job.secondSnapshot = nil
            job.secondRepository = nil
            job.secondPinsBefore = nil
            if job.stage == "copied" || job.stage == "copying" || job.stage == "waiting_for_second_upload" || job.stage == "leaving" {
                // A pending record names the replaced copy: it is made again with the new one.
                job.record = nil
                job.stage = "verified"
                job.stateSaved = false
            }
            st.offloads[id] = job
            try save(st)
        }
        // What was snapshotted and copied earlier counts only while the repositories still hold it: one made again
        // empty at the same path (a replaced disk) does not. A missing mirror snapshot starts the offload over; a
        // missing second copy is made again.
        try requireMirrorSnapshot(id, &job, &st)
        if job.stage == "copied" || job.stage == "waiting_for_second_upload" || job.stage == "leaving" {
            if let copy = job.secondSnapshot, let second = job.secondRepository,
               try !engine(second).snapshots(tag: "binder:\(id)").contains(where: { $0.id == copy && $0.tags.contains("offloaded") }) {
                // A pending record names the copy that is gone (or no longer pinned): it is made again with the new copy.
                job.record = nil
                job.secondSnapshot = nil
                job.secondPinsBefore = nil
                job.stage = "verified"
                job.stateSaved = false
                st.offloads[id] = job
                try save(st)
            }
        }
        if job.stage == "leaving" { return try leave(id, folder: folder, &st, nameCollides: nameCollides, now: now) }
        if job.stage == "snapshotted" { try verifySnapshotted(id, &job, &st) }
        let primary = try engine(s.primary)
        if job.stage == "verified" || job.stage == "waiting_for_upload" || job.stage == "copying" {
            // A binder that changed while it waits starts over now, never after a long wait on an obsolete snapshot.
            try refuseIfChanged(id, folder: folder, job, &st)
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
            job.stage = "waiting_for_second_upload"
            st.offloads[id] = job
            try save(st)
        }
        if job.stage == "waiting_for_second_upload" {
            // A second backup in another cloud service's folder holds the copy off this Mac only once uploaded.
            if let second = job.secondRepository, Self.isCloudProviderLocation(URL(fileURLWithPath: second, isDirectory: true)) {
                switch uploadCheck(URL(fileURLWithPath: second, isDirectory: true)) {
                case .uploaded: break
                case .waiting(let n): return .waitingForICloud(n)
                case .notChecked: return .waitingForICloud(0)
                case .notInICloud:
                    // Only iCloud reports an upload state Sprava can read; another service's folder cannot be
                    // confirmed yet (issue #224), so its copy does not count, and nothing leaves on it.
                    throw Failure(message: "the second backup's upload cannot be confirmed for this cloud service, so it is not yet a copy "
                        + "off this Mac; nothing was removed. Use an external disk as the second backup to offload")
                }
            }
            job.stage = "copied"
            st.offloads[id] = job
            try save(st)
            step("offload.copied")
        }
        guard job.stage == "copied", let snap = job.snapshot else { throw Failure(message: "offload stopped at \(job.stage)") }
        // Work that arrived since the offload started (a card, a file in intake/ or outgoing/, an open item not
        // confirmed) keeps the binder here.
        try refuseIfChanged(id, folder: folder, job, &st)
        let teka = Teka.read(folder)
        let currentOpen = try Self.refuseNotReady(folder, teka)
        let unconfirmed = Self.unconfirmed(currentOpen, job)
        if !unconfirmed.isEmpty {
            try abandonOffload(id, job, &st)
            throw NeedsConfirmation(items: currentOpen)
        }
        let record = Offloaded(
            backupID: id, name: teka.name, originalPath: Self.realPath(folder), snapshot: snap, repository: job.repository,
            secondSnapshot: job.secondSnapshot, secondRepository: job.secondRepository, bytes: job.bytes, at: ISOTime.string(now),
            summary: teka.catalog?["meta"]?["description"]?.stringValue ?? "",
            documents: (teka.catalog?["documents"]?.arrayValue ?? []).compactMap { d in
                guard let p = d["path"]?.stringValue else { return nil }
                return .init(title: d["title"]?.stringValue ?? p, path: p)
            },
            openItemsConfirmed: job.openItemsConfirmed, rootMetadata: job.root)
        // The record is kept with the job before the folder goes, so a failure from here on can be finished, never
        // lost; it joins the offloaded records once the folder went.
        job.stage = "leaving"
        job.record = record
        job.binderIdentity = Self.folderIdentity(folder)
        st.offloads[id] = job
        try save(st)
        step("offload.leaving")
        return try leave(id, folder: folder, &st, nameCollides: nameCollides, now: now)
    }

    /// Finishes offloads that were waiting. `nameCollides` answers, per binder folder, whether another binder here
    /// shares its name (`HubLane.collidingFolders`).
    public func continueOffloads(nameCollides: (URL) -> Bool, now: Date = Date()) -> [String: Result<OffloadProgress, Failure>] {
        var out: [String: Result<OffloadProgress, Failure>] = [:]
        let ids: [String]
        do { ids = try state().offloads.keys.sorted() } catch { return ["state": .failure(Failure(message: "\(error)"))] }
        for id in ids {
            do { out[id] = .success(try continueOffload(id, now: now, nameCollides: nameCollides)) } catch {
                out[id] = .failure(Failure(message: "\(error)"))
            }
        }
        return out
    }

    public func offloaded() throws -> [Offloaded] { try state().offloaded }

    public func pendingOffloads() throws -> [(path: String, stage: String)] {
        try state().offloads.values.map { ($0.path, $0.stage) }.sorted { $0.path < $1.path }
    }
}

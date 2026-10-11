import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit

/// Offloading, the last step: the binder leaves this Mac (docs/backup.md §6.1).
extension Backup {
    /// The folder goes to the Trash, so nothing is destroyed until the person empties it, and the Shelf forgets it.
    /// Runs again after an interruption, from the job's pending record.
    ///
    /// The record is the only way back to the binder in the app, so before the folder goes it is in the mirror too:
    /// a snapshot of Sprava's state holding the pending record is taken, and the folder waits until iCloud has it.
    /// That snapshot restored on another Mac (this one lost) finds the folder gone and finishes the offload: a leaving
    /// job whose folder is missing is never abandoned, as abandoning would unpin the binder's only copies. A binder
    /// the person moved meanwhile is therefore offloaded too, and still here: it keeps its copies, and backing it up
    /// at its new place is refused under the offloaded id until it is restored or given its own id.
    ///
    /// The move itself is staged under the binder's write lock: the folder is renamed to a hidden name beside it, so
    /// no program can write to it by its path any more, compared there once more, and only then moved to the Trash.
    /// Its place, identity and staging name are recorded first: a retry puts a binder still set aside back, and goes
    /// through every check again (`undoStagedMove`), and tells the binder from another folder put at its path since.
    func leave(_ id: String, folder: URL, _ st: inout State, nameCollides: (URL) -> Bool, now: Date) throws -> OffloadProgress {
        guard var job = st.offloads[id], let record = job.record else {
            throw Failure(message: "the offload's record is missing; nothing was removed")
        }
        if let target = job.leavingTarget.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            // The binder went to the Trash (`continueOffload` puts back one still set aside): only the link to it, if
            // the offload's path was one, and the records are left.
            try Self.removeLink(folder, to: target)
        } else {
            let entry = Self.folderEntry(folder)
            guard entry != .unavailable else {
                throw Failure(message: "the binder's folder cannot be checked; the offload was left unfinished")
            }
            // Missing with no move recorded (a state snapshot restored after this Mac was lost, or a binder the person
            // moved), or another folder at its path now: the binder is gone from it, its copies stay pinned and its
            // record is kept (see above); the other folder is left alone. Either way, as for a binder still here, a
            // checkpoint holding the record is taken and is in iCloud first.
            let here = entry == .present && Self.isTheBinder(folder, id, job)
            if !job.stateSaved {
                // Marked before the snapshot, so the snapshot and every state after it know a checkpoint exists.
                job.checkpointed = true
                st.offloads[id] = job
                try save(st)
                try backUpState(now: now)
                st = try state()
                job.stateSaved = true
                st.offloads[id] = job
                try save(st)
                step("offload.stateSaved")
            }
            if let n = try uploadPending(try engine(settings().primary).repository) {
                // The binder stays live while it waits: one that changed starts over, and is backed up as usual.
                if here { try refuseIfChanged(id, folder: folder, job, &st) }
                return .waitingForICloud(n)
            }
            if here { try moveToTrash(id, folder, &job, &st, nameCollides: nameCollides(folder), now: now) }
        }
        // A Shelf that still lists the folder would later refuse its restore there ("a binder on the Shelf"), so a
        // failure here stops, and the retry finishes from the record (the folder is gone by then). Both the path the
        // offload had and the real folder go, as either may be the one on the Shelf.
        // A path where a folder is again (another one, put there since) keeps its row: it is not this binder.
        let shelf = ShelfStore(supportDirectory: support)
        for path in Set([folder.standardizedFileURL.path, job.leavingTarget].compactMap { $0 }) {
            switch Self.folderEntry(URL(fileURLWithPath: path, isDirectory: true)) {
            case .missing: try shelf.remove(URL(fileURLWithPath: path, isDirectory: true))
            case .present: break
            case .unavailable:
                // Its disk may be away: the row is taken off once it can be checked, so the job waits.
                throw Failure(message: "the binder's old place cannot be checked (its disk may be away); the offload finishes when it can")
            }
        }
        step("offload.unshelved")
        let done = job.record ?? record
        if st.binders[id]?.snapshot != done.snapshot { st.binders[id]?.snapshot = done.snapshot }
        st.offloaded.removeAll { $0.backupID == id }
        st.offloaded.append(done)
        st.offloads[id] = nil
        try save(st)
        return .done(done)
    }

    /// Under the binder's write lock: the last comparison and readiness check, the hub withdrawal, the staged rename,
    /// and the move to the Trash. A binder that stays (it changed, its slice cannot be named safely, or the Trash
    /// refused it) goes back to waiting to leave.
    func moveToTrash(_ id: String, _ folder: URL, _ job: inout InProgress, _ st: inout State, nameCollides: Bool, now: Date) throws {
        var stays: Error?
        try TekaStore(folder: folder).withLock {
            try refuseIfChanged(id, folder: folder, job, &st)
            // Under the lock, the last word on work waiting: a card or file that arrived keeps the binder here.
            let unconfirmed = try Self.unconfirmed(Self.refuseNotReady(folder, Teka.read(folder)), job)
            guard unconfirmed.isEmpty else {
                stays = NeedsConfirmation(openItems: unconfirmed.map(\.title))
                return
            }
            // The hub stops showing it, as for a binder at disclosure none, without a write into the binder. A slice
            // that cannot be named safely (another binder shares the name and Sprava recorded none) keeps it here.
            guard try HubLane.withdrawBeforeLeaving(folder, root: hubSpool, nameCollides: nameCollides, now: now) else {
                stays = Failure(message: "the binder's hub slice cannot be identified safely while another binder has its name; "
                    + "nothing was removed. Rename one of them, then offload again")
                return
            }
            step("offload.unpublished")
            // The binder itself goes, also when the path the offload has is a link to it (the Shelf allows that). Its
            // place, identity and staging name are saved before anything moves.
            let real = URL(fileURLWithPath: Self.realPath(folder), isDirectory: true)
            let staging = real.deletingLastPathComponent().appendingPathComponent(".sprava-leaving-\(id)", isDirectory: true)
            job.leavingTarget = real.path
            job.leavingIdentity = Self.folderIdentity(real)
            job.staging = staging.path
            // The time it leaves and the binder's own place (not a link to it), saved with the intent: a retry after
            // the Trash move keeps them, and a restore puts the binder back where it really was.
            job.record?.at = ISOTime.string(now)
            job.record?.originalPath = real.path
            st.offloads[id] = job
            try save(st)
            guard renamex_np(real.path, staging.path, UInt32(RENAME_EXCL)) == 0 else {
                job.leavingTarget = nil
                job.leavingIdentity = nil
                job.staging = nil
                stays = Failure(message: "the binder could not be moved aside to leave; nothing was removed")
                return
            }
            step("offload.staged")
            // The last comparison, now that no program reaches it by its path, then the Trash. Either failing puts it
            // back where it was, and it stays.
            do {
                guard try job.manifestSHA == Self.digest(Self.manifest(staging)), try job.root == Self.rootMetadata(staging) else {
                    throw Failure(message: "the binder changed during the offload; nothing was removed. Offload again to back up the change")
                }
                try removeFolder(staging)
            } catch {
                if renamex_np(staging.path, real.path, UInt32(RENAME_EXCL)) == 0 {
                    job.leavingTarget = nil
                    job.leavingIdentity = nil
                    job.staging = nil
                }
                stays = error
                return
            }
            step("offload.trashed")
            // In the Trash now: from here on the job stays leaving whatever fails, as the binder is gone; a failed
            // save leaves the move recorded, and the retry finishes.
            st.offloads[id] = job
            // Offloaded from this moment: the record joins the offloaded ones (so no repository it needs can be
            // replaced), while the job stays for the cleanup left.
            if let record = job.record {
                st.offloaded.removeAll { $0.backupID == id }
                st.offloaded.append(record)
            }
            try save(st)
        }
        if let error = stays {
            // Back where it was (or never moved): it stays, and waits to leave again. One that could not be put back
            // (its volume went away, its place was taken) is still set aside: the job stays leaving, with its record,
            // so the retry puts it back first and nothing unpins its copies meanwhile.
            if job.staging == nil {
                job.stage = "copied"
                job.stateSaved = false
                job.record = nil
            }
            st.offloads[id] = job
            try? save(st)
            throw error
        }
        try Self.removeLink(folder, to: URL(fileURLWithPath: job.leavingTarget ?? folder.path, isDirectory: true))
        step("offload.removed")
    }

    /// Whether a binder reached through a link is still at its own place though the link is gone or leads elsewhere
    /// now: it has not left, and its offload must not finish as if it had.
    static func isAtItsRealPlace(_ id: String, _ job: InProgress, _ folder: URL) -> Bool {
        guard let real = job.record?.originalPath, !sameFolder(URL(fileURLWithPath: real, isDirectory: true), folder) else { return false }
        let place = URL(fileURLWithPath: real, isDirectory: true)
        return folderEntry(place) == .present && isTheBinder(place, id, job)
    }

    /// Whether the folder under the staging name is the binder set aside: the same folder, or one holding its backup
    /// id and exactly what its backups hold.
    static func isStagedBinder(_ staging: URL, _ id: String, _ job: InProgress) -> Bool {
        if let recorded = job.leavingIdentity, folderIdentity(staging) == recorded { return true }
        guard (try? storedBackupID(staging)) == id, let manifest = try? manifest(staging) else { return false }
        return digest(manifest) == job.manifestSHA
    }

    /// Whether the folder at the binder's path is the binder that began to leave: the same folder (device and
    /// inode), or one holding its backup id and exactly what its backups hold (a copy put back, which loses nothing
    /// in leaving). Another folder put there since is not.
    static func isTheBinder(_ folder: URL, _ id: String, _ job: InProgress) -> Bool {
        guard let recorded = job.binderIdentity else { return true }
        if folderIdentity(folder) == recorded { return true }
        guard (try? storedBackupID(folder)) == id, let manifest = try? manifest(folder) else { return false }
        return digest(manifest) == job.manifestSHA
    }

    /// Puts back a binder an interrupted move to the Trash left under its staging name (only when the folder there is
    /// this binder, `isStagedBinder`), or forgets a recorded move whose rename never happened. True when the binder
    /// is back where it was; false when the move went through (or none was recorded). A staged binder that cannot be
    /// put back (its place is taken) stops, and stays set aside.
    static func undoStagedMove(_ job: inout InProgress, _ id: String) throws -> Bool {
        guard let targetPath = job.leavingTarget else { return false }
        let target = URL(fileURLWithPath: targetPath, isDirectory: true)
        let unavailable = Failure(message: "the binder's place cannot be checked (its disk may be away); the offload was left unfinished")
        // A place that cannot be checked (a disk that is away) is not a move that went through: the job waits.
        switch job.staging.map({ folderEntry(URL(fileURLWithPath: $0, isDirectory: true)) }) ?? .missing {
        case .unavailable:
            throw unavailable
        case .present where !isStagedBinder(URL(fileURLWithPath: job.staging ?? "", isDirectory: true), id, job):
            // Something else under the staging name (the rename to it never happened): not touched; the binder is
            // where it was (the same folder, or an identical copy put back), or gone.
            switch folderEntry(target) {
            case .unavailable: throw unavailable
            case .missing: return false
            case .present: if folderIdentity(target) != job.leavingIdentity && !isTheBinder(target, id, job) { return false }
            }
        case .present:
            // Put back without replacing anything at its place, an empty folder included.
            guard let stagingPath = job.staging, renamex_np(stagingPath, target.path, UInt32(RENAME_EXCL)) == 0 else {
                throw Failure(message: "the binder is set aside beside its place, which is taken; nothing was removed. "
                    + "Make room for it, then continue the offload")
            }
        case .missing:
            switch folderEntry(target) {
            case .unavailable: throw unavailable
            case .missing: return false
            case .present: if folderIdentity(target) != job.leavingIdentity && !isTheBinder(target, id, job) { return false }
            }
        }
        job.leavingTarget = nil
        job.leavingIdentity = nil
        job.staging = nil
        return true
    }

    /// Removes the link the offload's path was, once the real folder is gone; a failure stops, and the retry
    /// removes it.
    static func removeLink(_ folder: URL, to target: URL) throws {
        guard target.standardizedFileURL.path != folder.standardizedFileURL.path else { return }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return }
        // A link that reaches a folder again (another one, put at the binder's place since) is kept, and so is one
        // that leads elsewhere (a replacement whose disk is away): only the link to the binder's own place goes.
        // The link may reach the place through other links (a chain), each followed in turn, as far as the system
        // follows them.
        guard stat(folder.path, &info) != 0 else { return }
        var hop = folder, reaches = false
        for _ in 0..<Int(MAXSYMLINKS) where !reaches {
            guard let to = try? FileManager.default.destinationOfSymbolicLink(atPath: hop.path) else { break }
            hop = URL(fileURLWithPath: to, relativeTo: hop.deletingLastPathComponent()).standardizedFileURL
            reaches = realPath(hop) == realPath(target)
        }
        guard reaches else { return }
        guard unlink(folder.path) == 0 || errno == ENOENT else {
            throw Failure(message: "the link to the offloaded binder could not be removed; the offload finishes when tried again")
        }
    }
}

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
    /// Its identity is recorded first, so a retry tells the binder from another folder put at its path since.
    func leave(_ id: String, folder: URL, _ st: inout State, nameCollides: (URL) -> Bool, now: Date) throws -> OffloadProgress {
        guard var job = st.offloads[id], let record = job.record else {
            throw Failure(message: "the offload's record is missing; nothing was removed")
        }
        if let target = job.leavingTarget.map({ URL(fileURLWithPath: $0, isDirectory: true) }) {
            // A staged move under way: finish it, or start over if the rename never happened.
            if let staging = job.staging.map({ URL(fileURLWithPath: $0, isDirectory: true) }),
               Self.folderIdentity(staging) == job.leavingIdentity {
                do { try trashStaged(id, staging, &job, &st, now: now) } catch {
                    // It changed while staged: back where it was, and it stays.
                    if rename(staging.path, target.path) == 0 {
                        job.leavingTarget = nil
                        job.leavingIdentity = nil
                        job.staging = nil
                    }
                    job.stage = "copied"
                    job.stateSaved = false
                    job.record = nil
                    st.offloads[id] = job
                    try? save(st)
                    throw error
                }
            } else if Self.folderIdentity(target) == job.leavingIdentity {
                job.leavingTarget = nil
                job.leavingIdentity = nil
                job.staging = nil
                st.offloads[id] = job
                try save(st)
                return try leave(id, folder: folder, &st, nameCollides: nameCollides, now: now)
            }
            // Otherwise the binder already went (whatever is at its path now is another folder).
            try Self.removeLink(folder, to: target)
        } else {
            switch Self.folderEntry(folder) {
            case .unavailable:
                throw Failure(message: "the binder's folder cannot be checked; the offload was left unfinished")
            case .missing:
                // No move recorded: a state snapshot restored after this Mac was lost, or a binder the person moved.
                // Either way its copies stay pinned and its record is kept (see above).
                break
            case .present:
                if !job.stateSaved {
                    try backUpState(now: now)
                    st = try state()
                    job.stateSaved = true
                    st.offloads[id] = job
                    try save(st)
                    step("offload.stateSaved")
                }
                if let n = try uploadPending(try engine(settings().primary).repository) {
                    // The binder stays live while it waits: one that changed starts over, and is backed up as usual.
                    try refuseIfChanged(id, folder: folder, job, &st)
                    return .waitingForICloud(n)
                }
                try moveToTrash(id, folder, &job, &st, nameCollides: nameCollides(folder), now: now)
            }
        }
        // A Shelf that still lists the folder would later refuse its restore there ("a binder on the Shelf"), so a
        // failure here stops, and the retry finishes from the record (the folder is gone by then). Both the path the
        // offload had and the real folder go, as either may be the one on the Shelf.
        let shelf = ShelfStore(supportDirectory: support)
        try shelf.remove(folder)
        if let target = job.leavingTarget, target != folder.standardizedFileURL.path {
            try shelf.remove(URL(fileURLWithPath: target, isDirectory: true))
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
            st.offloads[id] = job
            try save(st)
            guard rename(real.path, staging.path) == 0 else {
                job.leavingTarget = nil
                job.leavingIdentity = nil
                job.staging = nil
                stays = Failure(message: "the binder could not be moved aside to leave; nothing was removed")
                return
            }
            step("offload.staged")
            do { try trashStaged(id, staging, &job, &st, now: now) } catch {
                // Put back where it was: it stays, as it was.
                if rename(staging.path, real.path) == 0 {
                    job.leavingTarget = nil
                    job.leavingIdentity = nil
                    job.staging = nil
                }
                stays = error
            }
        }
        if let error = stays {
            job.stage = "copied"
            job.stateSaved = false
            job.record = nil
            st.offloads[id] = job
            try? save(st)
            throw error
        }
        try Self.removeLink(folder, to: URL(fileURLWithPath: job.leavingTarget ?? folder.path, isDirectory: true))
        step("offload.removed")
    }

    /// The staged folder, compared once more (no program writes to it by its path any more), then to the Trash; the
    /// time it left is saved at once.
    func trashStaged(_ id: String, _ staging: URL, _ job: inout InProgress, _ st: inout State, now: Date) throws {
        guard try job.manifestSHA == Self.digest(Self.manifest(staging)), try job.root == Self.rootMetadata(staging) else {
            throw Failure(message: "the binder changed during the offload; nothing was removed. Offload again to back up the change")
        }
        try removeFolder(staging)
        step("offload.trashed")
        job.record?.at = ISOTime.string(now)
        st.offloads[id] = job
        try save(st)
    }

    /// Removes the link the offload's path was, once the real folder is gone; a failure stops, and the retry
    /// removes it.
    static func removeLink(_ folder: URL, to target: URL) throws {
        guard target.standardizedFileURL.path != folder.standardizedFileURL.path else { return }
        var info = stat()
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK else { return }
        guard unlink(folder.path) == 0 || errno == ENOENT else {
            throw Failure(message: "the link to the offloaded binder could not be removed; the offload finishes when tried again")
        }
    }
}

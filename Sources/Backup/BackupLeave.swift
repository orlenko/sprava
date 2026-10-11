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
    /// Runs again after an interruption, from the record kept before.
    ///
    /// The record is the only way back to the binder in the app, so before the folder goes it is in the mirror too:
    /// a snapshot of Sprava's state is taken, and the folder waits until iCloud has it (a Mac lost before the next
    /// daily state snapshot would otherwise take the record with it).
    func leave(_ id: String, folder: URL, _ st: inout State, nameCollides: Bool, now: Date) throws -> OffloadProgress {
        guard var job = st.offloads[id], let snap = job.snapshot,
              let record = st.offloaded.first(where: { $0.backupID == id && $0.snapshot == snap }) else {
            throw Failure(message: "the offload's record is missing; nothing was removed")
        }
        switch Self.folderEntry(folder) {
        case .unavailable:
            throw Failure(message: "the binder's folder cannot be checked; the offload was left unfinished")
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
            // The last comparison, the hub withdrawal and the move to the Trash run under the binder's write lock, so
            // no approval can land between them and leave with the folder while neither backup holds it, and no
            // publish can put the binder's slice back on the hub after it was taken off.
            var removal: Error?
            try TekaStore(folder: folder).withLock {
                try refuseIfChanged(id, folder: folder, job, &st)
                // Under the lock, the last word on work waiting: a card or file that arrived keeps the binder here.
                let unconfirmed = try Self.unconfirmed(Self.refuseNotReady(folder, Teka.read(folder)), job)
                guard unconfirmed.isEmpty else {
                    removal = NeedsConfirmation(openItems: unconfirmed.map(\.title))
                    return
                }
                // The hub stops showing it, as for a binder at disclosure none. A slice that cannot be named safely
                // (another binder shares the name and Sprava recorded none) keeps the binder here.
                guard try HubLane.withdrawBeforeLeaving(folder, root: hubSpool, nameCollides: nameCollides, now: now) else {
                    removal = Failure(message: "the binder's hub slice cannot be identified safely while another binder has its name; "
                        + "nothing was removed. Rename one of them, then offload again")
                    return
                }
                step("offload.unpublished")
                // The binder itself goes, also when the path the offload has is a link to it (the Shelf allows that):
                // the real folder to the Trash, then the link, which would only lead nowhere.
                let real = URL(fileURLWithPath: Self.realPath(folder), isDirectory: true)
                do {
                    try removeFolder(real)
                    var info = stat()
                    if real.path != folder.standardizedFileURL.path, lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFLNK {
                        unlink(folder.path)
                    }
                } catch { removal = error }
            }
            // A binder that stays (its slice cannot be named safely, or the Trash refused it) is not offloaded: its
            // record goes, and the job goes back to waiting to leave.
            if let error = removal {
                st.offloaded.removeAll { $0.backupID == id && $0.snapshot == snap }
                job.stage = "copied"
                job.stateSaved = false
                st.offloads[id] = job
                try? save(st)
                throw error
            }
            step("offload.removed")
        case .missing:
            break
        }
        // A Shelf that still lists the folder would later refuse its restore there ("a binder on the Shelf"), so a
        // failure here stops, and the retry finishes from the record (the folder is gone by then).
        try ShelfStore(supportDirectory: support).remove(folder)
        step("offload.unshelved")
        if st.binders[id]?.snapshot != record.snapshot { st.binders[id]?.snapshot = record.snapshot }
        st.offloads[id] = nil
        try save(st)
        return .done(record)
    }
}

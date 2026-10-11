@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Offloading, the last step, cut off or contradicted: a staged binder, a folder or link changed at its place, a
/// checkpoint taken, copies the record names that are gone. Temporary folders and invented data only.
extension BackupOffloadLeaveTests {
    @Test(.enabled(if: hasRestic)) func aWriteToTheStagedFolderKeepsTheBinderHere() throws {
        let e = try env()
        var b = try configured(e)
        let id = try Backup.backupID(e.folder)
        let staging = e.folder.deletingLastPathComponent().appendingPathComponent(".sprava-leaving-\(id)", isDirectory: true)
        // A program with the binder open writes once it is moved aside, before the last comparison.
        b.atStep = { step in
            if step == "offload.staged" {
                try? Data("invented late write".utf8).write(to: staging.appendingPathComponent("correspondence/notary/late.pdf"))
            }
        }
        #expect(throws: Backup.Failure.self) {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now)
        }
        // Back in its place, with the write, and not offloaded.
        #expect(FileManager.default.fileExists(atPath: e.folder.appendingPathComponent("correspondence/notary/late.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try b.offloaded().isEmpty)
    }

    @Test func onlyALinkThatLeadsNowhereIsRemoved() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-leave-link-\(UUID().uuidString)")
        let other = base.appendingPathComponent("Other", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let link = base.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        // It reaches a folder (another binder, put at the old place since): kept.
        try Backup.removeLink(link, to: base.appendingPathComponent("Gone"))
        #expect(FileManager.default.fileExists(atPath: link.path))
        try FileManager.default.removeItem(at: other)
        try Backup.removeLink(link, to: base.appendingPathComponent("Gone"))
        var info = stat()
        #expect(lstat(link.path, &info) != 0)
    }

    @Test(.enabled(if: hasRestic)) func aStagedBinderThatCannotBePutBackKeepsTheJobLeaving() throws {
        let e = try env()
        var b = try configured(e)
        let id = try Backup.backupID(e.folder)
        let staging = e.folder.deletingLastPathComponent().appendingPathComponent(".sprava-leaving-\(id)", isDirectory: true)
        let folder = e.folder
        // Once it is set aside: a write makes the last comparison fail, and a folder now at its place blocks putting
        // it back.
        b.atStep = { step in
            guard step == "offload.staged" else { return }
            try? Data("invented late write".utf8).write(to: staging.appendingPathComponent("correspondence/notary/late.pdf"))
            // (A folder with something in it: an empty one would simply be replaced.)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? Data("invented".utf8).write(to: folder.appendingPathComponent("blocker.txt"))
        }
        #expect(throws: Backup.Failure.self) {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now)
        }
        let job = try #require(try b.state().offloads[id])
        #expect(job.stage == "leaving" && job.record != nil && job.staging != nil)
        #expect(FileManager.default.fileExists(atPath: staging.path))
        // Once the place is free again, the retry puts it back first; the change then starts the offload over.
        try FileManager.default.removeItem(at: folder)
        b.atStep = nil
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now, nameCollides: { _ in false }) }
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("correspondence/notary/late.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test(.enabled(if: hasRestic)) func anotherFolderAtTheBinderPathIsLeftAlone() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        // The binder is moved away during the wait, and another folder takes its place.
        let away = e.base.appendingPathComponent("Away", isDirectory: true)
        try FileManager.default.moveItem(at: e.folder, to: away)
        try FileManager.default.createDirectory(at: e.folder, withIntermediateDirectories: true)
        try Data("invented other folder".utf8).write(to: e.folder.appendingPathComponent("note.txt"))
        waiting.on = false
        b.atStep = nil
        guard case .done = try b.continueOffload(id, now: now, nameCollides: { _ in false }) else { Issue.record("not done"); return }
        #expect(FileManager.default.fileExists(atPath: e.folder.appendingPathComponent("note.txt").path))
        #expect(try b.offloaded().map(\.backupID) == [id])
    }

    @Test func aCutOffMoveIsNeverTakenForDoneWhileItsDiskIsAwayOrItsPlaceTaken() throws {
        // The binder's disk is away: neither its place nor its staging name can be checked, so the job waits.
        var away = Backup.InProgress(path: "/Volumes/Invented-Away-\(UUID().uuidString)/Binders/Estate", stage: "leaving")
        away.leavingTarget = away.path
        away.staging = "/Volumes/Invented-Away-\(UUID().uuidString)/Binders/.sprava-leaving-0123"
        away.leavingIdentity = "1:2"
        #expect(throws: Backup.Failure.self) { _ = try Backup.undoStagedMove(&away, "0123") }
        #expect(away.leavingTarget != nil)
        // Set aside, with an empty folder now at its place: it is not put back over it.
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-leave-undo-\(UUID().uuidString)")
        let place = base.appendingPathComponent("Estate", isDirectory: true)
        let staging = base.appendingPathComponent(".sprava-leaving-0123", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        var taken = Backup.InProgress(path: place.path, stage: "leaving")
        taken.leavingTarget = place.path
        taken.staging = staging.path
        taken.leavingIdentity = Backup.folderIdentity(staging)
        #expect(throws: Backup.Failure.self) { _ = try Backup.undoStagedMove(&taken, "0123") }
        #expect(FileManager.default.fileExists(atPath: staging.path) && FileManager.default.fileExists(atPath: place.path))
    }

    @Test(.enabled(if: hasRestic)) func anOffloadAbandonedAfterItsCheckpointKeepsItsPins() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        // The binder changes after the state snapshot holding it as leaving was taken: the offload starts over, but
        // that snapshot, restored after this Mac is lost, would finish the offload, so its copies stay pinned.
        try Data("invented later page".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/second.pdf"))
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now, nameCollides: { _ in false }) }
        #expect(try b.state().offloads[id] == nil)
        #expect(try b.engine(e.primary.path).snapshots(tag: "binder:\(id)").contains { $0.tags.contains("offloaded") })
    }

    @Test(.enabled(if: hasRestic)) func aSecondBackupReplacedAfterTheCheckpointKeepsTheCheckpointsCopyPinned() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        let checkpointed = try #require(try b.state().offloads[id]?.secondSnapshot)
        // The second backup is replaced while the binder waits to leave; the copy the checkpoint names stays pinned.
        try b.setSecond(e.base.appendingPathComponent("external/Another Second"))
        waiting.on = false
        b.atStep = nil
        _ = try b.continueOffload(id, now: now, nameCollides: { _ in false })
        #expect(try b.engine(e.second.path).snapshots(tag: "binder:\(id)").contains { $0.id == checkpointed && $0.tags.contains("offloaded") })
    }

    @Test func aRecordedMoveProtectsTheRepositoriesAndReservesTheID() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-leave-guard-\(UUID().uuidString)")
        let place = base.appendingPathComponent("Estate", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let id = try Backup.backupID(place)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded },
                       secondLocationCheck: { _ in true })
        // The binder went to the Trash (its move recorded); a copy with its id now sits at its place.
        var job = Backup.InProgress(path: place.path, stage: "leaving")
        job.leavingTarget = place.path
        var st = Backup.State()
        st.offloads[id] = job
        st.offloaded = [Backup.Offloaded(backupID: id, name: "Invented", originalPath: place.path, snapshot: "0123abcd",
                                         bytes: 1, at: "2026-10-07T00:00:00Z", summary: "invented", documents: [], openItemsConfirmed: 0)]
        try b.save(st)
        #expect(throws: Backup.Failure.self) { try b.refuseMovingOffloadedBinders() }
        st.offloaded = []
        try b.save(st)
        #expect(throws: Backup.Failure.self) { try b.refuseMovingOffloadedBinders() }
        st.offloaded = [Backup.Offloaded(backupID: id, name: "Invented", originalPath: place.path, snapshot: "0123abcd",
                                         bytes: 1, at: "2026-10-07T00:00:00Z", summary: "invented", documents: [], openItemsConfirmed: 0)]
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.claim(place, &st) }
    }

    @Test func aLinkWhoseBinderMovedAwayLeadsNowhereButOneToADiskAwayWaits() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-leave-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // The binder the link led to was moved elsewhere on this Mac: its old place can be checked, and it is empty.
        let moved = base.appendingPathComponent("Moved Link")
        try FileManager.default.createSymbolicLink(atPath: moved.path, withDestinationPath: base.appendingPathComponent("Estate").path)
        #expect(Backup.folderEntry(moved) == .missing)
        // The link leads to a disk that is away: the binder may still be there.
        let away = base.appendingPathComponent("Away Link")
        try FileManager.default.createSymbolicLink(atPath: away.path, withDestinationPath: "/Volumes/Invented-Away-\(UUID().uuidString)/Estate")
        #expect(Backup.folderEntry(away) == .unavailable)
    }

    @Test(.enabled(if: hasRestic)) func aMissingBinderWithNoCheckpointTakesOneAndWaitsForIt() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        let id = try Backup.backupID(e.folder)
        // The state as it was when the binder began to leave, before any checkpoint was taken (the first attempt
        // failed); the binder is then moved away.
        let image = e.base.appendingPathComponent("state-before-checkpoint")
        b.atStep = { step in if step == "offload.leaving" { try? FileManager.default.copyItem(at: e.support, to: image) } }
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) else {
            Issue.record("the binder did not leave")
            return
        }
        b.atStep = nil
        try FileManager.default.removeItem(at: e.support)
        try FileManager.default.copyItem(at: image, to: e.support)
        // A checkpoint holding the record is taken, and the offload finishes only once iCloud has it.
        waiting.on = true
        #expect(try b.continueOffload(id, now: now, nameCollides: { _ in false }) == .waitingForICloud(3))
        #expect(try b.state().offloads[id]?.stateSaved == true)
        waiting.on = false
        guard case .done = try b.continueOffload(id, now: now, nameCollides: { _ in false }) else { Issue.record("not done"); return }
    }

    @Test(.enabled(if: hasRestic)) func aMissingBinderWhoseRecordedCopyIsGoneIsNotFinished() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        b.atStep = nil
        // The second backup is replaced while it waits (allowed while the binder is here), then the binder is moved
        // away: the copy its record names is not in the second backup now.
        try b.setSecond(e.base.appendingPathComponent("external/Another Second"))
        try FileManager.default.moveItem(at: e.folder, to: e.base.appendingPathComponent("Elsewhere", isDirectory: true))
        waiting.on = false
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now, nameCollides: { _ in false }) }
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().offloads[id]?.stage == "leaving")
    }

    @Test(.enabled(if: hasRestic)) func aLeavingBinderNotHereProtectsItsRepositories() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        b.atStep = nil
        // While the binder is here, its offload starts over with new repositories; once it is not (moved away, or a
        // checkpoint restored on a Mac without it), its copies are all there is, and the repositories stay.
        try b.refuseMovingOffloadedBinders()
        try FileManager.default.moveItem(at: e.folder, to: e.base.appendingPathComponent("Elsewhere", isDirectory: true))
        #expect(throws: Backup.Failure.self) { try b.refuseMovingOffloadedBinders() }
        // A second path that leads into the mirror now is not a second copy: the offload does not finish.
        waiting.on = false
        try FileManager.default.removeItem(at: e.second)
        try FileManager.default.createSymbolicLink(at: e.second, withDestinationURL: e.primary)
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now, nameCollides: { _ in false }) }
        #expect(try b.state().offloads[id]?.stage == "leaving")
    }
}

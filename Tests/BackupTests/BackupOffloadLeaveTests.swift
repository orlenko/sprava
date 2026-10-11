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

/// Offloading, the last step: the binder's hub slice is withdrawn, the folder goes to the Trash and the Shelf
/// forgets it, only once its record is in the uploaded mirror. Binders, repositories, the Trash and the hub's spool
/// live in temporary folders only. Invented data only.
@Suite(.serialized) struct BackupOffloadLeaveTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let hasRestic = Restic.locate() != nil

    final class Switch: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Bool
        init(_ value: Bool) { self.value = value }
        var on: Bool {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    struct Env {
        let base: URL
        let support: URL
        let folder: URL
        var primary: URL { base.appendingPathComponent("icloud/Sprava Backup") }
        var second: URL { base.appendingPathComponent("external/Sprava Second") }
        var trash: URL { base.appendingPathComponent("trash", isDirectory: true) }
        var spool: URL { base.appendingPathComponent("spool", isDirectory: true) }
    }

    /// An adopted binder, managed by "dev", on the Shelf, with a spool ready for its slice.
    func env() throws -> Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-offload-leave-\(UUID().uuidString)")
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: folder.appendingPathComponent("correspondence/notary/letter.pdf"))
        let e = Env(base: base, support: base.appendingPathComponent("support"), folder: folder)
        try FileManager.default.createDirectory(at: e.trash, withIntermediateDirectories: true)
        for sub in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: e.spool.appendingPathComponent(sub), withIntermediateDirectories: true)
            chmod(e.spool.appendingPathComponent(sub).path, 0o700)
        }
        chmod(e.spool.path, 0o700)
        try ShelfStore(supportDirectory: e.support).add(folder)
        return e
    }

    func configured(_ e: Env, waiting: Switch? = nil, failRemove: Switch? = nil) throws -> Backup {
        let trash = e.trash
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB",
                       uploadCheck: { _ in waiting?.on == true ? .waiting(3) : .uploaded }, secondLocationCheck: { _ in true },
                       removeFolder: { url in
                           if failRemove?.on == true { throw CocoaError(.fileWriteNoPermission) }
                           try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
                       },
                       hubSpool: e.spool)
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        try b.setSecond(e.second)
        return b
    }

    func slice(_ e: Env) throws -> URL {
        try HubLane.spoolFile(e.spool.appendingPathComponent("inbox"), Teka.read(e.folder).name, ".agenda.json")
    }

    @Test(.enabled(if: hasRestic)) func theBinderLeavesTheHubTheShelfAndThisMac() throws {
        let e = try env()
        let b = try configured(e)
        // The binder's slice on the hub, as a publish leaves it under the binder's own name.
        let published = try slice(e)
        try Data(#"{"teka":"invented","items":[]}"#.utf8).write(to: published)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) else {
            Issue.record("the binder did not leave")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.trash.path).count == 1)
        #expect(!ShelfStore(supportDirectory: e.support).pickedFolders().contains { $0.standardizedFileURL.path == e.folder.standardizedFileURL.path })
        #expect(!FileManager.default.fileExists(atPath: published.path))
        // The record is in the state snapshot in the mirror, so a lost Mac does not take the way back with it.
        let state = try #require(try b.engine(e.primary.path).snapshots(tag: "sprava-state").last)
        #expect(try b.engine(e.primary.path).files(state.id).contains("backup/state.json"))
        #expect(try b.offloaded() == [record])
    }

    @Test(.enabled(if: hasRestic)) func theBinderWaitsUntilICloudHasTheRecord() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        // iCloud has the binder's copies, then stops uploading as the record's state snapshot is written.
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.state().offloads[id]?.stage == "leaving" && b.state().offloads[id]?.stateSaved == true)
        waiting.on = false
        b.atStep = nil
        let result = try b.continueOffloads(nameCollides: { _ in false }, now: now)[id].map { try $0.get() }
        guard case .done = result else { Issue.record("the binder did not leave: \(String(describing: result))"); return }
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
    }

    @Test(.enabled(if: hasRestic)) func aFolderThatCannotGoToTheTrashKeepsTheBinderAndDropsTheRecord() throws {
        let e = try env()
        let fail = Switch(true)
        let b = try configured(e, failRemove: fail)
        let id = try Backup.backupID(e.folder)
        #expect(throws: (any Error).self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.offloaded().isEmpty && b.state().offloads[id]?.stage == "copied")
        fail.on = false
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) else {
            Issue.record("the binder did not leave on retry")
            return
        }
        #expect(try b.offloaded().map(\.backupID) == [id])
    }

    @Test(.enabled(if: hasRestic)) func aSliceThatCannotBeNamedSafelyKeepsTheBinderHere() throws {
        let e = try env()
        let b = try configured(e)
        // Another binder here has the same name, and Sprava recorded no slice for this one.
        #expect(throws: Backup.Failure.self) {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in true }, now: now)
        }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.offloaded().isEmpty)
    }

    @Test(.enabled(if: hasRestic)) func aBinderReachedThroughALinkLeavesItself() throws {
        let e = try env()
        let b = try configured(e)
        let shortcuts = e.base.appendingPathComponent("Shortcuts", isDirectory: true)
        try FileManager.default.createDirectory(at: shortcuts, withIntermediateDirectories: true)
        let link = shortcuts.appendingPathComponent(e.folder.lastPathComponent)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.folder)
        guard case .done = try b.offload(link, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) else {
            Issue.record("the binder did not leave")
            return
        }
        // The real folder is in the Trash, not only the link to it, and the link is gone too.
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
        var info = stat()
        #expect(lstat(link.path, &info) != 0)
    }

    @Test(.enabled(if: hasRestic)) func aSecondBackupEmptiedWhileTheBinderWaitsToLeaveGetsTheCopyAgain() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        // The second backup's disk is swapped for an empty repository at the same path.
        try FileManager.default.removeItem(at: e.second)
        try b.engine(e.second.path).initRepository()
        waiting.on = false
        b.atStep = nil
        let result = try b.continueOffloads(nameCollides: { _ in false }, now: now)[id].map { try $0.get() }
        guard case .done(let record) = result else { Issue.record("the binder did not leave: \(String(describing: result))"); return }
        let copy = try #require(record.secondSnapshot)
        #expect(try b.engine(e.second.path).snapshots(tag: "binder:\(id)").contains { $0.id == copy })
    }

    @Test(.enabled(if: hasRestic)) func aBinderReachedThroughALinkLeavesTheShelfAndFinishesAfterAnInterruption() throws {
        let e = try env()
        var b = try configured(e)
        let link = e.base.appendingPathComponent("Shortcuts/\(e.folder.lastPathComponent)")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.folder)
        let id = try Backup.backupID(e.folder)
        // Stopped right after the real folder went to the Trash, before the link was removed.
        let state = e.base.appendingPathComponent("state-image")
        b.atStep = { step in
            if step == "offload.trashed" { try? FileManager.default.copyItem(at: e.support, to: state) }
        }
        _ = try b.offload(link, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now)
        try FileManager.default.removeItem(at: e.support)
        try FileManager.default.copyItem(at: state, to: e.support)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: e.folder)
        b.atStep = nil
        let result = try b.continueOffloads(nameCollides: { _ in false }, now: now)[id].map { try $0.get() }
        guard case .done = result else { Issue.record("the offload did not finish: \(String(describing: result))"); return }
        var info = stat()
        #expect(lstat(link.path, &info) != 0)
        // The real folder was on the Shelf; it is off it now.
        #expect(ShelfStore(supportDirectory: e.support).pickedFolders().isEmpty)
    }

    @Test(.enabled(if: hasRestic)) func aBinderMovedWhileWaitingToLeaveKeepsItsCopiesPinned() throws {
        let e = try env()
        let waiting = Switch(false)
        var b = try configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        let id = try Backup.backupID(e.folder)
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) == .waitingForICloud(3))
        #expect(try b.offloaded().isEmpty)
        // Moved in the Finder to another folder while the record's upload waits.
        let archive = e.base.appendingPathComponent("Archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        let moved = archive.appendingPathComponent(e.folder.lastPathComponent, isDirectory: true)
        try FileManager.default.moveItem(at: e.folder, to: moved)
        waiting.on = false
        b.atStep = nil
        // Missing without a recorded move is never abandoned: its copies stay pinned and its record is kept, and the
        // binder where it is now is refused under the offloaded id (it can be given its own) rather than lost.
        guard case .done = try b.continueOffload(id, now: now, nameCollides: { _ in false }) else { Issue.record("not done"); return }
        #expect(try b.offloaded().map(\.backupID) == [id])
        #expect(try b.engine(e.primary.path).snapshots(tag: "binder:\(id)").contains { $0.tags.contains("offloaded") })
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.backUp(moved, now: now) }
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }

    @Test(.enabled(if: hasRestic)) func theStateSnapshotRestoredAfterTheBinderLeftFinishesTheOffload() throws {
        let e = try env()
        var b = try configured(e)
        let id = try Backup.backupID(e.folder)
        // Sprava's state as the state snapshot holds it: taken with the binder waiting to leave.
        let image = e.base.appendingPathComponent("state-as-snapshotted")
        b.atStep = { step in if step == "offload.leaving" { try? FileManager.default.copyItem(at: e.support, to: image) } }
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: { _ in false }, now: now) else {
            Issue.record("the binder did not leave")
            return
        }
        b.atStep = nil
        // This Mac is lost; its state is restored from that snapshot on another, where the binder is not.
        try FileManager.default.removeItem(at: e.support)
        try FileManager.default.copyItem(at: image, to: e.support)
        #expect(try b.offloaded().isEmpty)
        let result = try b.continueOffloads(nameCollides: { _ in false }, now: now)[id].map { try $0.get() }
        guard case .done(let record) = result else { Issue.record("not finished: \(String(describing: result))"); return }
        #expect(try b.offloaded().map(\.backupID) == [id])
        #expect(try b.engine(e.primary.path).snapshots(tag: "binder:\(id)").contains { $0.id == record.snapshot && $0.tags.contains("offloaded") })
        #expect(try b.engine(e.second.path).snapshots(tag: "binder:\(id)").contains { $0.id == record.secondSnapshot && $0.tags.contains("offloaded") })
    }

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
        #expect(throws: Backup.Failure.self) { _ = try Backup.undoStagedMove(&away) }
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
        #expect(throws: Backup.Failure.self) { _ = try Backup.undoStagedMove(&taken) }
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
}

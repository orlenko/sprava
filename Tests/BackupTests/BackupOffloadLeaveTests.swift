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
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: false, now: now) else {
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
        #expect(try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: false, now: now) == .waitingForICloud(3))
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
        #expect(throws: (any Error).self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: false, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.offloaded().isEmpty && b.state().offloads[id]?.stage == "copied")
        fail.on = false
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: false, now: now) else {
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
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, nameCollides: true, now: now)
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
        guard case .done = try b.offload(link, deviceID: "dev", confirmOpenItems: true, nameCollides: false, now: now) else {
            Issue.record("the binder did not leave")
            return
        }
        // The real folder is in the Trash, not only the link to it, and the link is gone too.
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
        var info = stat()
        #expect(lstat(link.path, &info) != 0)
    }
}

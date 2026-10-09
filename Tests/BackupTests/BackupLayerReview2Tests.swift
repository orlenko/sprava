@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit
import Testing

/// Regressions from the second review of the Backup layer: a damaged second backup, a copied binder's backup id, a
/// renamed binder's former slice, a restore the Shelf cannot list, backups of a binder whose offload failed, an
/// unreadable backup id, and the queue's file lock. Repositories, binders and spools live in temporary folders only.
/// Invented data only.
@Suite(.serialized) struct BackupLayerReview2Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()

    // MARK: - 1. A copy in the second backup counts only once it reads back

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aDamagedSecondBackupStopsTheOffload() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        let restored = try b.restore(record.backupID, now: now)
        // The second backup's data files are damaged; its index still lists what they held.
        let data = e.second.appendingPathComponent("data")
        let walker = try #require(FileManager.default.enumerator(at: data, includingPropertiesForKeys: [.isRegularFileKey]))
        var damaged = 0
        for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            _ = Darwin.chmod(url.path, 0o600)
            let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int ?? 0
            try Data(repeating: 0, count: size).write(to: url)
            damaged += 1
        }
        #expect(damaged > 0)

        try Data("invented reply".utf8).write(to: restored.appendingPathComponent("correspondence/notary/reply.pdf"))
        #expect(throws: (any Error).self) { _ = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("correspondence/notary/reply.pdf").path))
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().offloads[record.backupID]?.secondSnapshot == nil)
    }

    // MARK: - 2. A copied binder never replaces the original's record

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aCopiedBinderIsNotOffloadedOverTheOriginal() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let id = try Backup.backupID(e.folder)
        let elsewhere = e.base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = elsewhere.appendingPathComponent(e.folder.lastPathComponent, isDirectory: true)
        try FileManager.default.copyItem(at: e.folder, to: copy)
        try Data("invented draft".utf8).write(to: copy.appendingPathComponent("correspondence/notary/draft.pdf"))

        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(record.backupID == id)
        // The offloaded binder's id is reserved (`claim`).
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.offload(copy, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(try b.offloaded() == [record])
        #expect(FileManager.default.fileExists(atPath: copy.appendingPathComponent("correspondence/notary/draft.pdf").path))

        // With an id of its own, the copy is offloaded beside the original.
        try FileManager.default.removeItem(at: copy.appendingPathComponent(".sprava/backup-id"))
        guard case .done(let other) = try b.offload(copy, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(other.backupID != id)
        #expect(Set(try b.offloaded().map(\.backupID)) == [id, other.backupID])
    }

    // MARK: - 3. An offload takes a renamed binder's former slice off the hub

    @Test func theFormerNamesSliceLeavesTheHubWithTheBinder() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        let inbox = e.spool.appendingPathComponent("inbox")
        // A binder at disclosure full, so it publishes.
        let former = "invented-estate"
        let folder = e.base.appendingPathComponent("binders/\(former)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"meta":{"schema_version":2,"name":"invented-estate"},"documents":[],"open_items":[],"processing_log":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("catalog.json"))
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        guard case .published = try HubLane.publish(folder, root: e.spool, now: now) else {
            Issue.record("not published"); return
        }
        #expect(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(former).agenda.json").path))

        let renamed = folder.deletingLastPathComponent().appendingPathComponent("invented-renamed", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        let args = JSONObject([(key: "name", value: .str("invented-renamed")), (key: "former", value: .string(former)),
                               (key: "until", value: .str("2027-01-01"))])
        try TekaStore(folder: renamed).apply([.init(op: "rename_teka", args: args, actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        // An unrelated file under some other name stays.
        let unrelated = inbox.appendingPathComponent("invented-other.agenda.json")
        try Data("{\"invented\": \"other slice\"}".utf8).write(to: unrelated)

        try b.removeHubSlice(Teka.read(renamed))
        #expect(!FileManager.default.fileExists(atPath: inbox.appendingPathComponent("\(former).agenda.json").path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    // MARK: - 4. A restore is finished only once the Shelf lists the binder

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aRestoreTheShelfCannotListKeepsItsRecord() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        let shelf = ShelfStore(supportDirectory: e.support)
        let shelfFile = e.support.appendingPathComponent("shelf.json")
        try Data("{ invented broken".utf8).write(to: shelfFile)
        #expect(throws: Backup.Failure.self) { _ = try b.restore(record.backupID, now: now) }
        #expect(try b.offloaded() == [record])
        #expect(try b.state().restoring[record.backupID] == e.folder.standardizedFileURL.path)

        try FileManager.default.removeItem(at: shelfFile)
        let restored = try b.restore(record.backupID, now: now)
        #expect(try shelf.readFolders().map(\.path) == [restored.path])
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().restoring.isEmpty)
    }

    // MARK: - 5. A binder whose offload failed is still backed up

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aFailedOffloadLeavesTheBinderInScheduledBackups() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        // The second backup's disk is disconnected after the snapshot is verified.
        let away = e.base.appendingPathComponent("away-second")
        try FileManager.default.moveItem(at: e.second, to: away)
        #expect(throws: (any Error).self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        let id = try Backup.backupID(e.folder)
        #expect(try b.state().offloads[id] != nil)

        try Data("invented later letter".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/later.pdf"))
        let m = b.maintain(rows: Shelf.rows(registry: nil, picked: [e.folder]), deviceID: "dev", now: now)
        #expect(m.snapshots == 1)
        let snap = try #require(try b.state().binders[id]?.snapshot)
        #expect(try b.engine(b.settings().primary).files(snap).contains("correspondence/notary/later.pdf"))
    }

    // MARK: - 6. A backup id is made only when there is none

    @Test func aBackupIDThatCannotBeReadIsNeverReplaced() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-backup-id2-\(UUID().uuidString)")
        let sprava = folder.appendingPathComponent(".sprava")
        let url = sprava.appendingPathComponent("backup-id")
        try FileManager.default.createDirectory(at: sprava, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        // A FIFO is refused without waiting on it.
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        #expect(Backup.existingBackupID(folder) == nil)
        var info = stat()
        #expect(lstat(url.path, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO)
        try FileManager.default.removeItem(at: url)

        // One that cannot be read, or holds something else, is left as it is.
        let id = "0123456789abcdef0123456789abcdef\n"
        try Data(id.utf8).write(to: url)
        _ = Darwin.chmod(url.path, 0o000)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        _ = Darwin.chmod(url.path, 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == id)
        try Data("invented, not an id".utf8).write(to: url)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "invented, not an id")

        // None at all: one is made, and kept.
        try FileManager.default.removeItem(at: url)
        let made = try Backup.backupID(folder)
        #expect(try Backup.backupID(folder) == made)
        #expect(Backup.existingBackupID(folder) == made)
    }

    // MARK: - 7. A queue whose file lock cannot be taken is not changed

    @Test func aQueueLockThatCannotBeOpenedChangesNothing() throws {
        let e = try bb.env()
        let requests = BackupRequests(support: e.support)
        try requests.enqueue(.init(id: "invented-1", kind: "drill", binder: "/Invented/binder", at: ISOTime.string(now)))
        let before = try Data(contentsOf: requests.url)
        _ = Darwin.chmod(requests.lockURL.path, 0o000)
        defer { _ = Darwin.chmod(requests.lockURL.path, 0o600) }
        #expect(throws: Backup.Failure.self) {
            try requests.enqueue(.init(id: "invented-2", kind: "drill", binder: "/Invented/other", at: ISOTime.string(now)))
        }
        #expect(throws: Backup.Failure.self) { try requests.update("invented-1") { $0.state = "done" } }
        #expect(try Data(contentsOf: requests.url) == before)
    }
}

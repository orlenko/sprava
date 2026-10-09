@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the review of increment 1's backup: offloads, the backup's own state, restore and requests.
/// The tests that run restic use repositories in temporary folders only, as BackupTests do.
@Suite(.serialized) struct BugbotBackupTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    static let hasRestic = Restic.locate() != nil

    /// A flag a test flips while a Backup's closures read it.
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
        let trash: URL
        let spool: URL
        var primary: URL { base.appendingPathComponent("icloud/Sprava Backup") }
        var second: URL { base.appendingPathComponent("external/Sprava Second") }
    }

    func env() throws -> Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-backup-\(UUID().uuidString)")
        let trash = base.appendingPathComponent("trash")
        let spool = base.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: spool.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: folder.appendingPathComponent("correspondence/notary/letter.pdf"))
        return Env(base: base, support: base.appendingPathComponent("support"), folder: folder, trash: trash, spool: spool)
    }

    /// A Backup whose mirror counts as uploaded to iCloud (`upload`), unless `waiting` is on.
    func backup(_ e: Env, key: String = "TEST-KEY-AAAAA-BBBBB", failRemove: Switch? = nil, waiting: Switch? = nil,
                upload: Backup.Upload = .uploaded) -> Backup {
        let trash = e.trash
        return Backup(support: e.support, key: key, removeFolder: { url in
            if failRemove?.on == true { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }, hubSpool: e.spool, uploadCheck: { _ in waiting?.on == true ? .waiting(2) : upload })
    }

    /// Settings naming both repositories, written directly, for the checks that run before restic does.
    func settingsOnly(_ e: Env) throws -> Backup {
        let b = backup(e)
        var s = Backup.Settings()
        s.primary = e.primary.path
        s.second = e.second.path
        try b.save(s)
        return b
    }

    func configured(_ e: Env, failRemove: Switch? = nil, waiting: Switch? = nil, upload: Backup.Upload = .uploaded) throws -> Backup {
        let b = backup(e, failRemove: failRemove, waiting: waiting, upload: upload)
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        try b.setSecond(e.second)
        return b
    }

    func addLogEntry(_ folder: URL, _ title: String) throws {
        let entry = JSONObject([(key: "entry", value: .obj([("action", .str("note")), ("title", .string(title)), ("date", .str("2026-10-07"))]))])
        try TekaStore(folder: folder).apply([.init(op: "add_log_entry", args: entry, actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
    }

    // MARK: - qewBv: an unreadable state is never replaced

    @Test func anUnreadableStateIsLeftAsItIs() throws {
        let e = try env()
        let b = try settingsOnly(e)
        let good = Data(#"{"offloaded":[{"backupID":"0123456789abcdef0123456789abcdef","name":"estate-example","originalPath":"/Invented/estate-example","snapshot":"abc","bytes":1,"at":"2026-10-01T10:00:00Z","summary":"","documents":[],"openItemsConfirmed":0}]}"#.utf8)
        try AtomicFile.makePrivateFolder(b.dir)
        try good.write(to: b.stateURL)
        // An older state without newer keys still decodes, with its records.
        #expect(try b.offloaded().count == 1)

        var bad = good
        bad[0] = UInt8(ascii: "X")
        try bad.write(to: b.stateURL)
        #expect(throws: Backup.Failure.self) { try b.backUpState(now: now) }
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(throws: Backup.Failure.self) { _ = try b.restore("0123456789abcdef0123456789abcdef", now: now) }
        #expect(throws: Backup.Failure.self) { _ = try b.offloaded() }
        #expect(b.maintain(rows: Shelf.rows(registry: nil, picked: [e.folder]), deviceID: "dev", now: now).failed == 1)
        #expect(b.status(checkUpload: false).stateError != nil)
        #expect(try Data(contentsOf: b.stateURL) == bad)
        // A missing file is a fresh state.
        try FileManager.default.removeItem(at: b.stateURL)
        #expect(try b.offloaded().isEmpty)
    }

    // MARK: - qgAN0: a binder that changed while the offload waited is backed up again

    @Test(.enabled(if: hasRestic)) func aBinderChangedWhileWaitingForICloudIsSnapshottedAgain() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        guard case .waitingForICloud = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("expected to wait for iCloud"); return
        }
        let id = try Backup.backupID(e.folder)
        let first = try #require(try b.state().offloads[id]?.snapshot)
        // The binder stays writable meanwhile.
        try Data("a later letter".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/later.pdf"))

        // Finishing straight away refuses: the copy would miss the change, and the folder stays.
        waiting.on = false
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.state().offloads[id] == nil)

        // The next offload takes a new snapshot, which holds the change.
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(record.snapshot != first)
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
        let restored = try b.restore(record.backupID, now: now)
        #expect(try String(contentsOf: restored.appendingPathComponent("correspondence/notary/later.pdf"), encoding: .utf8) == "a later letter")
    }

    @Test(.enabled(if: hasRestic)) func aChangeWhileWaitingRestartsTheOffloadInOneCall() throws {
        let e = try env()
        let waiting = Switch(true)
        let b = try configured(e, waiting: waiting)
        _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        let id = try Backup.backupID(e.folder)
        let first = try #require(try b.state().offloads[id]?.snapshot)
        try addLogEntry(e.folder, "Invented late change")
        waiting.on = false
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(record.snapshot != first)
    }

    // MARK: - qewB0: the last step of an offload can be finished after an interruption

    @Test(.enabled(if: hasRestic)) func aFailedTrashKeepsTheJobAndAnInterruptedLeaveFinishes() throws {
        let e = try env()
        let failRemove = Switch(true)
        let b = try configured(e, failRemove: failRemove)
        #expect(throws: (any Error).self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        let id = try Backup.backupID(e.folder)
        #expect(try b.state().offloads[id]?.stage == "copied")
        #expect(try b.offloaded().isEmpty)
        #expect(FileManager.default.fileExists(atPath: e.folder.path))

        failRemove.on = false
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        // A stop after the folder went to the Trash, before the records were cleared: the record is there, and
        // the next run finishes without the folder.
        var st = try b.state()
        st.offloads[id] = Backup.InProgress(path: e.folder.standardizedFileURL.path, stage: "leaving", snapshot: record.snapshot)
        try b.save(st)
        #expect(try b.offloaded().map(\.backupID) == [id])
        _ = b.maintain(rows: [], deviceID: "dev", now: now)
        #expect(try b.state().offloads.isEmpty)
        #expect(try b.offloaded().map(\.backupID) == [id])
    }

    // MARK: - qewCL: the second backup must be independent of the mirror

    @Test func theSecondBackupCannotShareTheMirrorsFate() throws {
        let e = try env()
        let b = backup(e)
        var s = Backup.Settings()
        s.primary = e.primary.path
        try b.save(s)
        try FileManager.default.createDirectory(at: e.primary, withIntermediateDirectories: true)
        let iCloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Invented Second")
        for folder in [e.primary, e.primary.appendingPathComponent("sub"), e.primary.deletingLastPathComponent(), iCloud] {
            #expect(throws: Backup.Failure.self) { try b.setSecond(folder) }
        }
        #expect(try b.settings().second == nil)
        #expect(!FileManager.default.fileExists(atPath: iCloud.path))
    }

    // MARK: - qewCR: an interrupted restore resumes into the same folder

    @Test(.enabled(if: hasRestic)) func aPartlyRestoredBinderCanBeRestoredAgain() throws {
        let e = try env()
        let b = try configured(e)
        let before = try Backup.manifest(e.folder)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        // Both repositories unreachable: the restore fails partway.
        let away = e.base.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: e.primary, to: away.appendingPathComponent("primary"))
        try FileManager.default.moveItem(at: e.second, to: away.appendingPathComponent("second"))
        #expect(throws: Backup.Failure.self) { _ = try b.restore(record.backupID, now: now) }
        // A partly restored file in the restore's private staging folder; the destination itself is untouched.
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
        let staging = Backup.staging(for: e.folder, id: record.backupID)
        try Data("{".utf8).write(to: staging.appendingPathComponent("catalog.json"))
        try FileManager.default.moveItem(at: away.appendingPathComponent("primary"), to: e.primary)
        try FileManager.default.moveItem(at: away.appendingPathComponent("second"), to: e.second)

        let restored = try b.restore(record.backupID, now: now)
        #expect(try Backup.manifest(restored)["catalog.json"] != nil)
        #expect(Teka.read(restored).catalog != nil)
        #expect(try Backup.manifest(restored)["correspondence/notary/letter.pdf"] == before["correspondence/notary/letter.pdf"])
        #expect(try b.state().restoring.isEmpty)
    }

    // MARK: - qfZ38: a write during a snapshot leaves the binder due

    @Test(.enabled(if: hasRestic)) func aWriteDuringASnapshotLeavesTheBinderDue() throws {
        let e = try env()
        var b = try configured(e)
        let once = Switch(true)
        let folder = e.folder
        let now = self.now
        b.afterSnapshot = {
            guard once.on else { return }
            once.on = false
            let entry = JSONObject([(key: "entry", value: .obj([("action", .str("note")), ("title", .str("Invented write during a snapshot")), ("date", .str("2026-10-07"))]))])
            _ = try? TekaStore(folder: folder).apply([.init(op: "add_log_entry", args: entry, actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        }
        let first = try b.backUp(e.folder, now: now)
        #expect(first.snapshot != nil)
        let id = try Backup.backupID(e.folder)
        #expect(try b.state().binders[id]?.at == nil)
        let m = b.maintain(rows: Shelf.rows(registry: nil, picked: [e.folder]), deviceID: "dev", now: now)
        #expect(m.snapshots == 1)
        #expect(try b.state().binders[id]?.at != nil)
    }

    // MARK: - qfZ4N: a failed setup leaves the settings as they were

    @Test(.enabled(if: hasRestic)) func aFailedSetupKeepsTheWorkingMirror() throws {
        let e = try env()
        let b = backup(e)
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        let other = e.base.appendingPathComponent("other/Sprava Backup")
        try Backup(support: e.base.appendingPathComponent("support2"), key: "OTHER-KEY-CCCCC").setUp(primary: other, iCloudKeychain: false)
        let wrong = backup(e, key: "WRONG-KEY-DDDDD")
        #expect(throws: (any Error).self) { try wrong.setUp(primary: other, iCloudKeychain: false) }
        #expect(try b.settings().primary == e.primary.standardizedFileURL.path)
    }

    // MARK: - qfZ4b: a hub slice that cannot be removed stops the offload

    @Test(.enabled(if: hasRestic)) func aStuckHubSliceStopsTheOffload() throws {
        let e = try env()
        let b = try configured(e)
        let inbox = e.spool.appendingPathComponent("inbox")
        let slice = inbox.appendingPathComponent(Teka.read(e.folder).name + ".agenda.json")
        try Data("{}".utf8).write(to: slice)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: inbox.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path) }
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.state().offloads[try Backup.backupID(e.folder)]?.stage == "copied")

        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: inbox.path)
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else { Issue.record("not done"); return }
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    // MARK: - qgAOX: messages in intake/mail/ stop an offload

    @Test func aMessageInIntakeMailStopsAnOffload() throws {
        let e = try env()
        let b = try settingsOnly(e)
        let mail = e.folder.appendingPathComponent("intake/mail")
        try FileManager.default.createDirectory(at: mail, withIntermediateDirectories: true)
        try Data("SECRET=invented".utf8).write(to: mail.appendingPathComponent(".env"))
        try Data("{}".utf8).write(to: mail.appendingPathComponent("state.json"))
        // A mail monitor's own files are not waiting: the next check (open items) is reached.
        #expect(throws: Backup.NeedsConfirmation.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: false, now: now) }
        try Data("invented message".utf8).write(to: mail.appendingPathComponent("msg.md"))
        do {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: false, now: now)
            Issue.record("offload went ahead")
        } catch let f as Backup.Failure {
            #expect(f.message.contains("intake/"))
        }
    }

    // MARK: - qgAOg: an older offload's copy is found after the second backup changed

    @Test(.enabled(if: hasRestic)) func anOlderOffloadRestoresFromItsOwnSecondBackup() throws {
        let e = try env()
        let b = try configured(e)
        let sha = try #require(DocumentPaths.sha256(of: e.folder.appendingPathComponent("correspondence/notary/letter.pdf")))
        try TekaStore(folder: e.folder).apply([.init(op: "file_document", args: JSONObject([(key: "document", value: .obj([
            ("id", .str("estate-example-doc-2026-901")), ("title", .str("Letter")), ("path", .str("correspondence/notary/letter.pdf")),
            ("sha256", .string(sha))]))]), actor: JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))]))], now: now)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(record.secondRepository == e.second.standardizedFileURL.path)
        try b.setSecond(e.base.appendingPathComponent("disk2/Sprava Second"))
        try FileManager.default.moveItem(at: e.primary, to: e.base.appendingPathComponent("primary-away"))
        let file = try b.peek(record.backupID, path: "correspondence/notary/letter.pdf")
        #expect(try String(contentsOf: file, encoding: .utf8) == "invented letter")
        let restored = try b.restore(record.backupID, now: now)
        #expect(Teka.read(restored).catalog != nil)
    }

    // MARK: - qgAOq: peeked documents do not pile up

    @Test func peekedDocumentsAreRemovedAfterADay() throws {
        let e = try env()
        let b = backup(e)
        let old = b.dir.appendingPathComponent("peek/old"), fresh = b.dir.appendingPathComponent("peek/new")
        for folder in [old, fresh] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("invented".utf8).write(to: folder.appendingPathComponent("doc.pdf"))
        }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: old.path)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: fresh.path)
        b.cleanPeeks(now: now)
        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    // MARK: - qgAOG: requests are changed one writer at a time

    @Test func concurrentRequestUpdatesAreNeverLost() throws {
        let e = try env()
        let requests = BackupRequests(support: e.support)
        let at = ISOTime.string(Date())
        DispatchQueue.concurrentPerform(iterations: 200) { i in
            _ = try? requests.enqueue(.init(id: "r\(i)", kind: "drill", binder: "/Invented/binder-\(i)", at: at))
            try? requests.update("r\(i)") { $0.state = "running" }
        }
        let all = try requests.all()
        #expect(all.count == 200)
        #expect(all.allSatisfy { $0.state == "running" })

        // After a restart nothing is running: those requests are marked interrupted, not run again.
        try requests.recoverInterrupted()
        #expect(try requests.all().allSatisfy { $0.state == "failed" && ($0.message ?? "").contains("interrupted") })
    }
}

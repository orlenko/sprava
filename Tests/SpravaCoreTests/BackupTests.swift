import Foundation
import Testing
@testable import SpravaCore

/// Runs the real restic against repositories in temporary folders. Skipped when restic is not installed.
@Suite(.serialized) struct BackupTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let hasRestic = Restic.locate() != nil

    struct Setup {
        let backup: Backup
        let folder: URL
        let base: URL
    }

    func setup(key: String = "TEST-KEY-AAAAA-BBBBB") throws -> Setup {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-backup-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        let trash = base.appendingPathComponent("trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let backup = Backup(support: support, key: key, removeFolder: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        })
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: folder.appendingPathComponent("correspondence/notary/letter.pdf"))
        try backup.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
        return Setup(backup: backup, folder: folder, base: base)
    }

    @Test(.enabled(if: hasRestic)) func snapshotsSkipWhenNothingChanged() throws {
        let s = try setup()
        let first = try s.backup.backUp(s.folder, now: now)
        #expect(first.snapshot != nil)
        let again = try s.backup.backUp(s.folder, now: now)
        #expect(again.snapshot == nil)
        try Data("more".utf8).write(to: s.folder.appendingPathComponent("correspondence/notary/second.pdf"))
        #expect(try s.backup.backUp(s.folder, now: now).snapshot != nil)
        try s.backup.backUpState(now: now)
        try s.backup.applyRetention(now: now)
        try s.backup.check(readData: true, now: now)
        try s.backup.drill(s.folder, now: now)
        #expect(s.backup.status(checkUpload: true).upload == .notInICloud)
    }

    @Test(.enabled(if: hasRestic)) func aWrongKeyCannotOpenTheMirror() throws {
        let s = try setup()
        let other = Backup(support: s.base.appendingPathComponent("support2"), key: "WRONG-KEY")
        #expect(throws: (any Error).self) { try other.setUp(primary: s.base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false) }
    }

    @Test(.enabled(if: hasRestic)) func offloadPeekRestoreAndOffloadAgain() throws {
        let s = try setup()
        #expect(throws: Backup.Failure.self) { _ = try s.backup.offload(s.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        try s.backup.setSecond(s.base.appendingPathComponent("external/Sprava Second"))
        // Open items need the person's confirmation.
        #expect(throws: Backup.NeedsConfirmation.self) { _ = try s.backup.offload(s.folder, deviceID: "dev", confirmOpenItems: false, now: now) }
        let sha = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("correspondence/notary/letter.pdf")))
        try TekaStore(folder: s.folder).apply([.init(op: "file_document", args: JSONObject([(key: "document", value: .obj([
            ("id", .str("estate-example-doc-2026-900")), ("title", .str("Letter")), ("path", .str("correspondence/notary/letter.pdf")),
            ("sha256", .string(sha))]))]), actor: JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))]))], now: now)
        let before = Backup.manifest(s.folder)
        let progress = try s.backup.offload(s.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        guard case .done(let record) = progress else { Issue.record("not done: \(progress)"); return }
        #expect(!FileManager.default.fileExists(atPath: s.folder.path))
        #expect(record.secondSnapshot != nil)
        #expect(record.documents.contains { $0.path == "correspondence/notary/letter.pdf" })
        #expect(try s.backup.offloaded().count == 1)

        // Peek at one document without restoring the binder.
        let file = try s.backup.peek(record.backupID, path: "correspondence/notary/letter.pdf")
        #expect(try String(contentsOf: file, encoding: .utf8) == "invented letter")
        #expect(throws: Backup.Failure.self) { _ = try s.backup.peek(record.backupID, path: "../../etc/passwd") }

        // Restore: the binder comes back as it left, with the offload recorded in its history.
        let restored = try s.backup.restore(record.backupID, now: now)
        #expect(restored.path == s.folder.standardizedFileURL.path)
        let after = Backup.manifest(restored)
        #expect(after["correspondence/notary/letter.pdf"] == before["correspondence/notary/letter.pdf"])
        #expect(Teka.read(restored).catalog?["processing_log"]?.arrayValue?.contains { ($0["title"]?.stringValue ?? "").hasPrefix("Offloaded with") } == true)
        #expect(try s.backup.offloaded().isEmpty)

        // Offload again with nothing changed: the pinned snapshots are reused.
        let again = try s.backup.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now)
        guard case .done(let second) = again else { Issue.record("not done"); return }
        #expect(second.snapshot == record.snapshot)
    }

    @Test(.enabled(if: hasRestic)) func offloadRefusesWithCardsOrFilesWaiting() throws {
        let s = try setup()
        try s.backup.setSecond(s.base.appendingPathComponent("external/Sprava Second"))
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: s.folder.appendingPathComponent("intake/scan.pdf"))
        #expect(throws: Backup.Failure.self) { _ = try s.backup.offload(s.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(FileManager.default.fileExists(atPath: s.folder.path))
    }

    @Test func keysAreTypableAndCompareLoosely() {
        let k = BackupKey.generate()
        #expect(k.count == 35 && k.split(separator: "-").count == 6)
        #expect(BackupKey.normalize(k.lowercased().replacingOccurrences(of: "-", with: " ")) == BackupKey.normalize(k))
    }
}

/// The whole path the app and the runtime take: commands, then the queued requests the backup job runs.
@Suite(.serialized) struct BackupCommandTests {
    // Real time: finished requests are kept for a day by the real clock.
    let now = Date()

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    @Test(.enabled(if: BackupTests.hasRestic && ProcessInfo.processInfo.environment["SPRAVA_BACKUP_KEY_FILE"] != nil))
    func setUpOffloadAndRestoreThroughCommands() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-backup-cmd-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        let c = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        #expect(try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])["ok"] == .bool(true))
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }

        let key = try #require(try call(c, [("command", .str("backup_new_key"))])["key"]?.stringValue)
        let wrong = try call(c, [("command", .str("backup_setup")), ("key", .str("NOT-IT")), ("primary", .string(base.appendingPathComponent("icloud").path))])
        #expect(wrong["ok"] == .bool(false))
        let ok = try call(c, [("command", .str("backup_setup")), ("key", .string(key.lowercased())), ("primary", .string(base.appendingPathComponent("icloud").path))])
        #expect(ok["ok"] == .bool(true), "\(ok)")
        #expect(try call(c, [("command", .str("backup_second")), ("folder", .string(base.appendingPathComponent("disk").path))])["ok"] == .bool(true))

        let backup = Backup(support: support, removeFolder: { try FileManager.default.removeItem(at: $0) })
        let requests = BackupRequests(support: support)
        func drain() throws { while let r = try requests.next(), r.state == "queued" { requests.run(r, backup: backup, deviceID: "dev", now: now) } }

        // Without the confirmation, the request stops and lists the open items.
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .string(folder.path))])
        try drain()
        #expect(try requests.all().last?.state == "needs_confirmation")
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .string(folder.path)), ("confirm_open_items", .bool(true))])
        try drain()
        #expect(try requests.all().last?.state == "done", "\((try? requests.all()) ?? [])")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
        let status = try call(c, [("command", .str("backup_status"))])
        let offloaded = try #require(status["offloaded"]?.arrayValue?.first)

        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("restore")), ("backup_id", offloaded["id"]!)])
        try drain()
        #expect(try requests.all().last?.state == "done", "\((try? requests.all()) ?? [])")
        #expect(Teka.read(folder).state == .ready)
    }
}

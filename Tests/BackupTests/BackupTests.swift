@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

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
        // The hub's spool is a temporary folder too, never the person's.
        let backup = Backup(support: support, key: key, removeFolder: { url in
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }, hubSpool: base.appendingPathComponent("spool"), uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true })
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
        #expect(s.backup.status(checkUpload: true).upload == .uploaded)
        #expect(Backup.uploadStatus(of: s.base.appendingPathComponent("icloud/Sprava Backup")) == .notInICloud)
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
        let before = try Backup.manifest(s.folder)
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
        let after = try Backup.manifest(restored)
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

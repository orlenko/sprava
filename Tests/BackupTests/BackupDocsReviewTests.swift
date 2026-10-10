@testable import Backup
import Darwin
import Foundation
import SpravaKit
import Testing

/// Regressions from the review of docs/backup.md: "Offload again" checks both backups before an unchanged binder
/// leaves on them (§6.4), and a document deleted for good leaves every snapshot in both backups (§3.5). Repositories
/// and binders live in temporary folders only. Invented data only.
@Suite(.serialized) struct BackupDocsReviewTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()
    let secret = "correspondence/notary/invented-statement.pdf"

    /// Overwrites every data file of a repository; its index still lists what they held.
    func damage(_ repository: URL) throws {
        let walker = try #require(FileManager.default.enumerator(at: repository.appendingPathComponent("data"), includingPropertiesForKeys: nil))
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            _ = Darwin.chmod(url.path, 0o600)
            try Data(repeating: 0, count: Int(info.st_size)).write(to: url)
        }
    }

    // MARK: - §6.4 An unchanged binder leaves only on backups that pass their check

    func offloadedAndRestored() throws -> (Backup, BugbotBackupTests.Env, URL) {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            throw Backup.Failure(message: "not done")
        }
        return (b, e, try b.restore(record.backupID, now: now))
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aDamagedSecondBackupKeepsAnUnchangedBinder() throws {
        let (b, e, restored) = try offloadedAndRestored()
        try damage(e.second)
        do {
            _ = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now)
            Issue.record("offloaded onto a damaged second backup")
        } catch {
            #expect("\(error)".contains("the second backup"))
        }
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("catalog.json").path))
        #expect(try b.offloaded().isEmpty)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aDamagedMirrorKeepsAnUnchangedBinder() throws {
        let (b, e, restored) = try offloadedAndRestored()
        try damage(e.primary)
        do {
            _ = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now)
            Issue.record("offloaded onto a damaged mirror")
        } catch {
            #expect("\(error)".contains("the iCloud mirror"))
        }
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("catalog.json").path))
        #expect(try b.offloaded().isEmpty)
    }

    // MARK: - §3.5 A document deleted for good leaves both backups

    func holders(_ b: Backup, _ repository: URL, id: String) throws -> [Set<String>] {
        let r = try b.engine(repository.path)
        return try r.snapshots(tag: "binder:\(id)").map { try r.files($0.id) }
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aForgottenDocumentLeavesBothBackupsAndIsRetried() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        try Data("invented statement".utf8).write(to: e.folder.appendingPathComponent(secret))
        let snap = try #require(try b.backUp(e.folder, now: now).snapshot)
        let s = try b.settings()
        try b.engine(s.second).copy(snap, from: b.engine(s.primary))
        let id = try Backup.backupID(e.folder)
        #expect(try holders(b, e.second, id: id).allSatisfy { $0.contains(secret) })

        // The person deletes it for good while the second backup's disk is away.
        try FileManager.default.removeItem(at: e.folder.appendingPathComponent(secret))
        let away = e.base.appendingPathComponent("away-second")
        try FileManager.default.moveItem(at: e.second, to: away)
        #expect(try !b.forgetDocument(in: e.folder, path: secret, request: "invented-deletion-1", now: now))
        #expect(b.status(checkUpload: false).forgetting.first?.error != nil)
        #expect(try holders(b, e.primary, id: id).allSatisfy { !$0.contains(secret) && $0.contains("correspondence/notary/letter.pdf") })

        // The next scheduled run finishes it once the disk is back.
        try FileManager.default.moveItem(at: away, to: e.second)
        let m = b.maintain(rows: [], deviceID: "dev", now: now)
        #expect(!m.failedParts.contains("forget"))
        let done = try #require(b.status(checkUpload: false).forgetting.first)
        #expect(done.done != nil && done.error == nil && done.path == secret)
        #expect(try holders(b, e.second, id: id).allSatisfy { !$0.contains(secret) })
        #expect(try !holders(b, e.second, id: id).isEmpty)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func anOffloadedBinderStillRestoresAfterAForgetting() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        try Data("invented statement".utf8).write(to: e.folder.appendingPathComponent(secret))
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(try b.forget(record.backupID, path: secret, request: "invented-deletion-1", now: now))
        let renamed = try #require(try b.offloaded().first)
        #expect(renamed.snapshot != record.snapshot && renamed.secondSnapshot != record.secondSnapshot)

        let restored = try b.restore(record.backupID, now: now)
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent(secret).path))
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("correspondence/notary/letter.pdf").path))
    }
}

@testable import Backup
import Foundation
import Testing

/// Regressions from the sixth adversarial review of increment 1 (a resumed restore's baseline, withdrawal by a binder
/// whose name collides, digits of other scripts in untrusted text). Invented data only.
@Suite(.serialized) struct AstraReview6Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    // MARK: - 1. A resumed restore's baseline is the snapshot, never the whole folder

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aFileAddedToAPartlyRestoredBinderIsBackedUpBeforeItLeaves() throws {
        let bb = BugbotBackupTests()
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        // Both repositories unreachable: the restore fails partway.
        let away = e.base.appendingPathComponent("away")
        try FileManager.default.createDirectory(at: away, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: e.primary, to: away.appendingPathComponent("primary"))
        try FileManager.default.moveItem(at: e.second, to: away.appendingPathComponent("second"))
        #expect(throws: Backup.Failure.self) { _ = try b.restore(record.backupID, now: now) }

        // The person puts a new document where the binder is going. Restoring again never writes over it: it is
        // refused until that is moved away. (Restores work in a private staging folder beside the destination.)
        let added = "correspondence/notary/invented-reply.pdf"
        try FileManager.default.createDirectory(at: e.folder.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented reply".utf8).write(to: e.folder.appendingPathComponent(added))
        try FileManager.default.moveItem(at: away.appendingPathComponent("primary"), to: e.primary)
        try FileManager.default.moveItem(at: away.appendingPathComponent("second"), to: e.second)
        #expect(throws: Backup.Failure.self) { _ = try b.restore(record.backupID, now: now) }
        #expect(try String(contentsOf: e.folder.appendingPathComponent(added), encoding: .utf8) == "invented reply")
        let kept = e.base.appendingPathComponent("invented-kept")
        try FileManager.default.moveItem(at: e.folder, to: kept)
        let restored = try b.restore(record.backupID, now: now)
        // The person adds their document to the restored binder.
        try FileManager.default.copyItem(at: kept.appendingPathComponent(added), to: restored.appendingPathComponent(added))
        #expect(try Backup.manifest(restored)[added] != nil)
        let baseline = try #require(try b.state().restored[record.backupID]?.manifest)
        #expect(baseline[added] == nil)
        #expect(baseline["correspondence/notary/letter.pdf"] != nil)

        // Offloading again takes a new snapshot that holds the added document before the folder goes.
        guard case .done(let again) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(again.snapshot != record.snapshot)
        #expect(!FileManager.default.fileExists(atPath: restored.path))
        let s = try b.settings()
        #expect(try b.engine(s.primary).files(again.snapshot).contains(added))
        let second = try #require(again.secondSnapshot)
        #expect(try b.engine(again.secondRepository ?? s.second).files(second).contains(added))
    }
}

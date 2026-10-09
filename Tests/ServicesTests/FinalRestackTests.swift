import Backup
import BinderFormat
import BinderStore
import Capture
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// The command layer on the merged lower layers: approval through Capture's gate, and the backup records the
/// runtime and backup_status report. Every value is invented.
@Suite(.serialized) struct FinalRestackTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    /// An approval goes through Capture's approval gate (`cardForApproval`), which settles the binder's capture work
    /// first: while Sprava's capture record cannot be read, nothing is approved, and the card stays as it was.
    @Test func anApprovalWaitsForTheCaptureGate() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, listed) = try ops.adoptCatalog(c, name: "garden-sample", """
        {"meta": {"schema_version": 2, "name": "garden-sample"}, "documents": [], "processing_log": [],
         "open_items": [{"id": "garden-sample-2026-001", "title": "Order the invented seeds", "status": "open", "priority": "normal"}]}
        """)
        let repair = try #require(listed.first { $0["title"] == .str("Fill in what this item is missing") })
        let edits = JSONValue.array([.obj([("index", .int(0)), ("due", .str("2026-12-01"))])])
        let state = c.inbox.stateURL
        try FileManager.default.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: state)

        let refused = try ops.approve(c, folder, repair, edits: edits)
        #expect(refused["ok"] == .bool(false))
        #expect(refused["error"]?.stringValue?.contains("cannot be approved now") == true, "\(refused)")
        #expect(ProposalStore.list(in: folder).first { $0.0.id == repair["id"]?.stringValue }?.0.state == "proposed")
        #expect(Teka.read(folder).items.first?.raw["due"] == nil)

        try FileManager.default.removeItem(at: state)
        let approved = try ops.approve(c, folder, repair, edits: edits)
        #expect(approved["ok"] == .bool(true), "\(approved)")
        #expect(Teka.read(folder).items.first?.raw["due"] == .str("2026-12-01"))
    }

    /// Two binders on the Shelf that hold the same backup id (one copied from the other with its `.sprava`) are
    /// listed, so the person can give the copy its own; the second backup's last check is reported beside the first's.
    @Test func backupStatusListsFoldersThatShareABackupID() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (shed, _) = try ops.createdBinder(c, name: "shed-sample")
        let (porch, _) = try ops.createdBinder(c, name: "porch-sample")
        let id = "0123456789abcdef0123456789abcdef"
        for folder in [shed, porch] { try Data((id + "\n").utf8).write(to: folder.appendingPathComponent(".sprava/backup-id")) }

        let status = try ops.call(c, [("command", .str("backup_status"))])
        #expect(status["ok"] == .bool(true), "\(status)")
        #expect(status["last_second_check"] == .null)
        let shared = status["shared_backup_ids"]?.arrayValue ?? []
        #expect(Set(shared.compactMap { $0["name"]?.stringValue }) == ["shed-sample", "porch-sample"], "\(shared)")
        #expect(shared.allSatisfy { $0["backup_id"] == .string(id) })

        // Once the copy has an id of its own, nothing is listed.
        try Data(("fedcba9876543210fedcba9876543210" + "\n").utf8).write(to: porch.appendingPathComponent(".sprava/backup-id"))
        #expect(try ops.call(c, [("command", .str("backup_status"))])["shared_backup_ids"] == .array([]))
    }

    /// The scheduled backup's outcome counts a copied binder that holds another binder's backup id among its failures.
    @Test func theBackupJobReportsSharedBackupIDs() {
        #expect(BackupJob.outcome(failed: 0, failedParts: [], sharedBackupIDs: 0, requests: .ok) == .ok)
        #expect(BackupJob.outcome(failed: 2, failedParts: ["check"], sharedBackupIDs: 1, requests: .ok)
            == .error(code: "backup_failed", culprit: "2 failure(s), including check, 1 copied binder(s) holding another binder's backup id"))
        #expect(BackupJob.outcome(failed: 1, failedParts: [], sharedBackupIDs: 0, requests: .ok)
            == .error(code: "backup_failed", culprit: "1 failure(s) in binder backups"))
    }
}

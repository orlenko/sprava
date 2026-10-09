@testable import Backup
import Darwin
import Foundation
import Testing

/// Regressions from the third adversarial review of increment 1 (closed items under the title ratchet, rewrites
/// of tampered cards, the clerk and the disclosure ratchet, readings that could not be written, waiting parties on
/// repair cards, failed state backups, and file names in the capture journal). Invented data only.
@Suite(.serialized) struct AstraReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra3-\(label)-\(UUID().uuidString)")
    }

    // MARK: - 6. A failed backup of Sprava's own state is a failure

    @Test func aFailedStateBackupAndRetentionAreCountedAndStayDue() throws {
        let support = temp("support")
        // No restic here: every restic run fails.
        let b = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, uploadCheck: { _ in .notInICloud })
        var s = Backup.Settings()
        s.primary = temp("mirror").path
        try b.save(s)
        #expect(try b.isConfigured)
        let m = b.maintain(rows: [], deviceID: "dev", now: now)
        #expect(!m.stateSnapshot && !m.retention && !m.checked)
        #expect(m.failed == 3)
        #expect(m.failedParts == ["state_snapshot", "retention", "check"])
        let st = try b.state()
        #expect(st.stateSnapshotAt == nil && st.lastForget == nil && st.lastCheck == nil)
        // Due again on the next run.
        #expect(b.maintain(rows: [], deviceID: "dev", now: now.addingTimeInterval(60)).failedParts == ["state_snapshot", "retention", "check"])
    }
}

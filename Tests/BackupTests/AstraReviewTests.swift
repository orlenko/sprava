@testable import Backup
import BinderStore
import Darwin
import Foundation
import SpravaTestSupport
import Testing

/// Regressions from the adversarial review of increment 1 (proposal ids, privacy raises, offload, readings,
/// state files that cannot be read, the clerk's and the Inbox's hand-overs, the document reader, MCP logs).
/// Invented data only.
@Suite(.serialized) struct AstraReviewTests {
    // MARK: - 3. The offload's last check and removal hold the binder lock

    @Test func offloadRemovesTheFolderUnderTheBinderLock() throws {
        let e = try BugbotBackupTests().env()
        let locked = BugbotBackupTests.Switch(false)
        let trash = e.trash
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB", removeFolder: { url in
            // A writer arriving now finds the binder locked, so no approval can slip in before the folder goes.
            locked.on = (try? TekaStore(folder: url).withLock(timeout: 0) {}) == nil
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }, hubSpool: e.spool, uploadCheck: { _ in .notInICloud })
        let id = try Backup.backupID(e.folder)
        var job = Backup.InProgress(path: e.folder.standardizedFileURL.path, stage: "leaving")
        job.snapshot = "invented-snapshot"
        job.manifestSHA = Backup.digest(Backup.manifest(e.folder))
        var st = Backup.State()
        st.offloads[id] = job
        st.offloaded = [Backup.Offloaded(backupID: id, name: "estate-example", originalPath: job.path, snapshot: "invented-snapshot",
                                         secondSnapshot: nil, secondRepository: nil, bytes: 1, at: "2026-10-06T10:00:00Z", summary: "",
                                         documents: [], openItemsConfirmed: 0)]
        try b.save(st)
        guard case .done = try b.continueOffload(id, now: pNow) else { Issue.record("expected the offload to finish"); return }
        #expect(locked.on)
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
    }
}

import Backup
import BinderFormat
import BinderStore
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The Health page's read, made in the app's own process while the runtime is stopped: it shows the doctor and
/// the backup records and never writes into Sprava's state or a binder. Invented data only.
@Suite(.serialized) struct HealthSnapshotTests {
    let ops = BugbotOpsTests()
    let fm = FileManager.default

    @Test func theChecksReadOnlyAndNeverMakeIDs() throws {
        let c = ops.commands()
        let (folder, _) = try ops.readyBinder(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        let backupID = folder.appendingPathComponent(".sprava/backup-id")
        try? fm.removeItem(at: backupID)

        // No device id yet: no binder is this Mac's, and none is made.
        var checks = HealthSnapshot.checks(support: c.support)
        #expect(checks.findings.isEmpty && checks.deviceIDError == nil)
        #expect(!fm.fileExists(atPath: c.support.appendingPathComponent("device-id").path))
        // Backup not set up is not an error; the binder is listed with no record, and no backup id is made for it.
        #expect(!checks.backupConfigured && checks.backupSettingsError == nil)
        let name = try #require(ShelfStore(supportDirectory: c.support).rows().first?.name)
        #expect(checks.backups == [HealthSnapshot.BackupLine(name: name, at: nil, error: nil)])
        #expect(!fm.fileExists(atPath: backupID.path))

        // A device id that cannot be read is reported and left as it is.
        let deviceID = c.support.appendingPathComponent("device-id")
        try Data("not an id".utf8).write(to: deviceID)
        checks = HealthSnapshot.checks(support: c.support)
        #expect(checks.deviceIDError != nil)
        #expect(try String(contentsOf: deviceID, encoding: .utf8) == "not an id")

        // Backup settings that cannot be read are reported, not shown as "not set up".
        let settings = c.support.appendingPathComponent("backup/settings.json")
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: settings)
        checks = HealthSnapshot.checks(support: c.support)
        #expect(!checks.backupConfigured && checks.backupSettingsError != nil)
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{broken")
    }

    @Test func theRuntimeRecordsAreReadWithoutFollowingLinks() throws {
        let c = ops.commands()
        let dir = HealthSnapshot.runtimeDirectory(support: c.support)
        try AtomicFile.makePrivateFolder(dir)
        var state = RuntimeState()
        state.day = "2026-10-07"
        state.startsToday = 3
        try JSONEncoder().encode(state).write(to: RuntimeState.url(dir))
        #expect(HealthSnapshot.runtime(support: c.support, today: "2026-10-07").startsToday == 3)
        #expect(HealthSnapshot.runtime(support: c.support, today: "2026-10-08").startsToday == 0)

        try Data("refused 1\nrefused 2\nrefused 3\nrefused 4\n".utf8).write(to: dir.appendingPathComponent("lease-refusals.log"))
        #expect(HealthSnapshot.runtime(support: c.support).refusals == ["refused 2", "refused 3", "refused 4"])

        // A watch record that is a link to another file is not shown.
        let elsewhere = c.support.appendingPathComponent("elsewhere.json")
        try Data("{\"invented\": true}".utf8).write(to: elsewhere)
        try fm.createSymbolicLink(atPath: dir.appendingPathComponent("watch.json").path, withDestinationPath: elsewhere.path)
        let r = HealthSnapshot.runtime(support: c.support)
        #expect(r.watchRecord == nil)
        #expect(!r.backgroundOff)
        if case .failure(.missing) = r.heartbeat {} else { Issue.record("a missing heartbeat read as \(r.heartbeat)") }
    }
}

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
@Suite(.serialized) struct HealthSnapshotTests: BinderCommandFixture {
    let fm = FileManager.default

    @Test func aRefusedRegistryIsReportedRatherThanTreatedAsEmpty() throws {
        let c = commands()
        try fm.createDirectory(at: c.support, withIntermediateDirectories: true)
        let registry = c.support.appendingPathComponent("invented-registry.toml")
        let missing = try HealthSnapshot.doctorFindings(support: c.support, deviceID: "dev", registryURL: registry)
        #expect(!missing.contains { $0.text.contains("registry cannot be read") })
        try fm.createSymbolicLink(at: registry, withDestinationURL: c.support.appendingPathComponent("missing-target"))
        let refused = try HealthSnapshot.doctorFindings(support: c.support, deviceID: "dev", registryURL: registry)
        #expect(refused.contains { $0.text == "lifeproj's registry cannot be read; Health could not check which binders it can still publish" })
        #expect(try fm.destinationOfSymbolicLink(atPath: registry.path) == c.support.appendingPathComponent("missing-target").path)
    }

    @Test func theChecksReadOnlyAndNeverMakeIDs() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        let backupID = folder.appendingPathComponent(".sprava/backup-id")
        try? fm.removeItem(at: backupID)

        // No device id yet: no binder is this Mac's, and none is made.
        var checks = HealthSnapshot.checks(support: c.support)
        #expect(checks.findings.contains { $0.text.contains("privacy checks are unavailable") } && checks.deviceIDError == nil)
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

    @Test func missingAndCopiedDeviceIDsStillCheckTheExplicitSpoolReadOnly() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        try TekaStore(folder: folder).apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .str("none"))]),
                                                  actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        let spool = c.support.appendingPathComponent("chosen-spool")
        try fm.createDirectory(at: spool.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        let name = try #require(Teka.read(folder).catalog?["meta"]?["name"]?.stringValue)
        let slice = spool.appendingPathComponent("inbox/\(name).agenda.json")
        let bytes = Data("{}".utf8)
        try bytes.write(to: slice)
        let registry = c.support.appendingPathComponent("invented-missing-registry")
        let id = c.support.appendingPathComponent("device-id")
        let noID = HealthSnapshot.checks(support: c.support, spool: spool, registryURL: registry)
        #expect(noID.findings.contains { $0.level == .fix && $0.text.contains("slice is still on the hub") })
        #expect(!fm.fileExists(atPath: id.path))
        let copied = Data(("0f0e0d0c-0b0a-4908-8706-050403020100\n" + String(repeating: "0", count: 64) + "\n").utf8)
        try copied.write(to: id)
        #expect(try DeviceID.existing(support: c.support) == nil)
        let migrated = HealthSnapshot.checks(support: c.support, spool: spool, registryURL: registry)
        #expect(migrated.findings.contains { $0.level == .fix && $0.text.contains("slice is still on the hub") })
        #expect(try Data(contentsOf: id) == copied && Data(contentsOf: slice) == bytes)
        try Data("unreadable id".utf8).write(to: id)
        let damaged = HealthSnapshot.checks(support: c.support, spool: spool, registryURL: registry)
        #expect(damaged.deviceIDError != nil)
        #expect(damaged.findings.contains { $0.level == .fix && $0.text.contains("slice is still on the hub") })
    }

    @Test func anUnconfiguredSpoolNeverFallsBackToTheCallersEnvironment() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        let findings = try HealthSnapshot.doctorFindings(support: c.support, deviceID: "dev", registryURL: c.support.appendingPathComponent("missing"))
        #expect(findings.contains { $0.level == .fix && $0.text == "the hub spool has not been configured here; its privacy checks are unavailable" })
    }

    @Test func anUnconfiguredRegistryDoesNotClaimACoexistenceCheck() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        let findings = try HealthSnapshot.doctorFindings(support: c.support, deviceID: "dev", spool: c.support)
        #expect(findings.contains { $0.level == .fix && $0.text == "lifeproj's registry path has not been configured here; coexistence privacy checks are unavailable" })
    }

    @Test func theRuntimeRecordsAreReadWithoutFollowingLinks() throws {
        let c = commands()
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

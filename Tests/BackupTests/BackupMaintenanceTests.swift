@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The backup job's scheduled work: what is due, what is left alone, and how a failure stays due and is counted.
/// restic runs against repositories in temporary folders only; those tests are skipped without it. Invented binders
/// only.
@Suite(.serialized) struct BackupMaintenanceTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let hasRestic = Restic.locate() != nil

    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-maintain-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func backup(_ support: URL, key: String? = "TEST-KEY-AAAAA-BBBBB") -> Backup {
        Backup(support: support, key: key, uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true })
    }

    func adopted(device: String = "dev") throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .string(device))]), now: now)
        return folder
    }

    func maintain(_ b: Backup, _ folders: [URL], at: Date? = nil) -> Backup.Maintenance {
        b.maintain(rows: Shelf.rows(registry: nil, picked: folders), deviceID: "dev", nameCollides: { _ in false }, now: at ?? now)
    }

    @Test func backupNotSetUpIsNoWork() throws {
        let support = try temp("not-set-up")
        #expect(maintain(backup(support), [try adopted()]) == Backup.Maintenance())
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("backup/state.json").path))
    }

    @Test func settingsThatCannotBeReadAreAFailureNotNotSetUp() throws {
        let support = try temp("unreadable")
        let b = backup(support)
        try AtomicFile.makePrivateFolder(b.dir)
        try Data("{broken".utf8).write(to: b.settingsURL)
        let m = maintain(b, [try adopted()])
        #expect(m.failed == 1 && m.failedParts == ["backup_settings"])
        #expect(try String(contentsOf: b.settingsURL, encoding: .utf8) == "{broken")
    }

    @Test(.enabled(if: hasRestic)) func aMissingKeyStopsTheWorkAsAFailure() throws {
        let base = try temp("no-key")
        let support = base.appendingPathComponent("support")
        try backup(support).setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
        let m = maintain(backup(support, key: nil), [try adopted()])
        #expect(m.failedParts == ["backup_key"] && m.snapshots == 0)
    }

    @Test(.enabled(if: hasRestic)) func whatIsDueRunsOnceAndWaitsItsTurn() throws {
        let base = try temp("due")
        let support = base.appendingPathComponent("support")
        let b = backup(support)
        try b.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
        let mine = try adopted(), another = try adopted(device: "another-mac")
        let first = maintain(b, [mine, another])
        #expect(first.snapshots == 1 && first.failed == 0, "\(first)")
        #expect(first.stateSnapshot && first.retention && first.checked)
        // Another Mac's binder is not this Mac's to back up.
        #expect(Backup.existingBackupID(another) == nil)
        // Within the hour nothing is due again.
        let soon = maintain(b, [mine, another], at: now.addingTimeInterval(600))
        #expect(soon == Backup.Maintenance())
        // After the hour the binder is due; unchanged, it takes no snapshot. The state, retention and check wait.
        let later = maintain(b, [mine], at: now.addingTimeInterval(3700))
        #expect(later.unchanged == 1 && later.snapshots == 0 && !later.stateSnapshot && !later.retention && !later.checked)
    }

    @Test(.enabled(if: hasRestic)) func aBinderWhoseWritesAreBlockedIsCountedNotBackedUp() throws {
        let base = try temp("blocked")
        let support = base.appendingPathComponent("support")
        let b = backup(support)
        try b.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
        let folder = try adopted()
        // A duplicate key makes the catalog unsafe JSON, which blocks every write until it is repaired.
        let catalog = folder.appendingPathComponent("catalog.json")
        let text = try String(contentsOf: catalog, encoding: .utf8)
        try text.replacingOccurrences(of: "{", with: #"{"invented": 1, "invented": 2,"#, options: [], range: text.range(of: "{"))
            .write(to: catalog, atomically: true, encoding: .utf8)
        #expect(Teka.read(folder).writesBlocked)
        let m = maintain(b, [folder])
        #expect(m.blockedBinders == [folder.standardizedFileURL.path] && m.failed == 1 && m.snapshots == 0)
        #expect(Backup.existingBackupID(folder) == nil)
    }
}

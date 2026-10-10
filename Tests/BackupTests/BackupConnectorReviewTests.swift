@testable import Backup
import Darwin
import Foundation
import SpravaKit
import Testing

/// Regressions from the exact-head connector review of the Backup layer. Every repository, queue and binder path is
/// invented and lives in a temporary folder.
@Suite(.serialized) struct BackupConnectorReviewTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()

    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-connector-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Leaves repository metadata readable while making every stored pack unreadable to restic.
    func damageData(in repository: URL) throws {
        let data = repository.appendingPathComponent("data")
        let walker = try #require(FileManager.default.enumerator(at: data, includingPropertiesForKeys: nil))
        var damaged = 0
        for case let url as URL in walker {
            var info = stat()
            guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
            _ = Darwin.chmod(url.path, 0o600)
            try Data(repeating: 0, count: Int(info.st_size)).write(to: url)
            damaged += 1
        }
        #expect(damaged > 0)
    }

    @Test func anOrdinaryFolderOnThisMacIsNotASecondBackup() throws {
        let base = try temp("second-location")
        let ordinary = base.appendingPathComponent("Backups/Sprava Second")
        #expect(!Backup.isIndependentSecondLocation(ordinary))
        let madeUpProvider = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage/InventedProvider-\(UUID().uuidString)/Sprava Second")
        #expect(!Backup.isIndependentSecondLocation(madeUpProvider))

        let backup = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil,
                            uploadCheck: { _ in .uploaded })
        #expect(throws: Backup.Failure.self) {
            try backup.refuseSharedFate(ordinary, primary: base.appendingPathComponent("iCloud/Sprava Backup"))
        }
    }

    @Test func oldConfirmationOutcomesExpireWithOtherFinishedRequests() throws {
        let requests = BackupRequests(support: try temp("confirmation-expiry"))
        let old = BackupRequests.Request(id: "invented-old-confirmation", kind: "offload", binder: "/Invented/Estate",
                                         state: "needs_confirmation", at: "2000-01-01T00:00:00Z")
        try requests.save([old])
        #expect(try requests.all().isEmpty)
    }

    @Test func theRequestQueueRefusesLinksAndSpecialFilesWithoutBlocking() throws {
        let support = try temp("request-special")
        let requests = BackupRequests(support: support)
        try AtomicFile.makePrivateFolder(requests.url.deletingLastPathComponent())
        let elsewhere = support.appendingPathComponent("invented-elsewhere.json")
        try Data("[]".utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: requests.url, withDestinationURL: elsewhere)
        #expect(throws: Backup.Failure.self) { try requests.all() }
        try FileManager.default.removeItem(at: requests.url)
        #expect(mkfifo(requests.url.path, 0o600) == 0)
        let started = Date()
        #expect(throws: Backup.Failure.self) { try requests.all() }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func aMissingMountIsNotTreatedAsAnAlreadyRemovedBinder() throws {
        let base = try temp("unavailable-binder")
        let backup = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil,
                            uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true })
        var settings = Backup.Settings()
        settings.primary = base.appendingPathComponent("mirror").path
        settings.second = base.appendingPathComponent("second").path
        try backup.save(settings)
        let id = "0123456789abcdef0123456789abcdef"
        let missingMount = base.appendingPathComponent("disconnected-volume/Estate", isDirectory: true)
        var state = Backup.State()
        var job = Backup.InProgress(path: missingMount.path, stage: "leaving")
        job.snapshot = "0123abcd"
        job.repository = settings.primary
        state.offloads[id] = job
        state.offloaded = [.init(backupID: id, name: "estate-example", originalPath: missingMount.path,
                                 snapshot: "0123abcd", repository: settings.primary, secondSnapshot: "4567abcd",
                                 secondRepository: settings.second, bytes: 1, at: ISOTime.string(now), summary: "",
                                 documents: [], openItemsConfirmed: 0)]
        try backup.save(state)
        #expect(Backup.folderEntry(missingMount) == .unavailable)
        #expect(throws: Backup.Failure.self) { _ = try backup.continueOffload(id, now: now) }
        #expect(try backup.state().offloads[id]?.stage == "leaving")
        #expect(try backup.state().offloaded.contains { $0.backupID == id })
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func replacingTheMirrorFallsBackFromDamagedPrimaryAndMigratesRecoveryState() throws {
        let e = try bb.env()
        let backup = try bb.configured(e)
        guard case .done(let first) = try backup.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the binder did not offload"); return
        }
        // The old mirror can still list the pinned snapshot, but its data pack cannot be restored. Migration must
        // continue to the independently stored second copy instead of stopping at the first metadata match.
        try damageData(in: e.primary)
        let replacement = e.base.appendingPathComponent("icloud/Sprava Replacement")
        try backup.setUp(primary: replacement, iCloudKeychain: false)

        let migrated = try #require(try backup.offloaded().first)
        #expect(try backup.settings().primary == replacement.standardizedFileURL.path)
        #expect(migrated.repository == replacement.standardizedFileURL.path)
        let mirror = try backup.engine(replacement.path)
        #expect(try mirror.snapshots(tag: "offloaded").contains { $0.id == migrated.snapshot })
        let stateSnapshot = try #require(try mirror.snapshots(tag: "sprava-state").last?.id)
        let saved = e.base.appendingPathComponent("invented-migrated-state.json")
        try mirror.dump(stateSnapshot, path: "/backup/state.json", to: saved)
        let recovered = try JSONDecoder().decode(Backup.State.self, from: Data(contentsOf: saved))
        #expect(recovered.offloaded.first?.repository == replacement.standardizedFileURL.path)

        // The replacement mirror is independently restorable after both the live binder and former destinations
        // are unavailable.
        let retiredSecond = e.base.appendingPathComponent("invented-retired-second")
        try FileManager.default.moveItem(at: e.second, to: retiredSecond)
        #expect(try backup.restore(first.backupID, now: now).path == e.folder.standardizedFileURL.path)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func offloadSelectsItsPinnedCopyInsteadOfANewerDrillSnapshot() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(true)
        let backup = try bb.configured(e, waiting: waiting)
        guard case .waitingForICloud = try backup.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the offload did not wait"); return
        }
        let id = try Backup.backupID(e.folder)
        let sourceID = try #require(try backup.state().offloads[id]?.snapshot)
        let primary = try backup.engine(e.primary.path)
        let second = try backup.engine(e.second.path)
        try second.copy(sourceID, from: primary)

        let drill = e.base.appendingPathComponent("invented-drill")
        try FileManager.default.createDirectory(at: drill, withIntermediateDirectories: true)
        try Data("invented later drill".utf8).write(to: drill.appendingPathComponent("drill.txt"))
        let drillID = try #require(try second.backup(drill, tags: ["sprava", "binder:\(id)"], excludes: [],
                                                     skipIfUnchanged: false).snapshot)
        waiting.on = false
        guard case .done(let record) = try backup.continueOffload(id, now: now) else {
            Issue.record("the offload did not finish"); return
        }
        #expect(record.secondSnapshot != drillID)
        #expect(try second.snapshots(tag: "offloaded").contains { $0.id == record.secondSnapshot })
    }
}

@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import Security
import SpravaKit
import Testing

/// Regressions from the review of the Backup layer: unreadable state and destinations, incomplete manifests, a
/// replaced mirror, repositories that share a fate, the hub's slices, the iCloud Keychain copy of the key, and the
/// request queue's transitions. Repositories, binders and spools live in temporary folders only. Invented data only.
@Suite(.serialized) struct BackupLayerReviewTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()

    func chmod(_ url: URL, _ mode: mode_t) { _ = Darwin.chmod(url.path, mode) }

    // MARK: - 1. A state file that is a link to a place that is away is not a fresh state

    @Test func aStateLinkToAPlaceThatIsAwayIsNeverReplaced() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        try AtomicFile.makePrivateFolder(b.dir)
        let away = e.base.appendingPathComponent("unmounted-disk/state.json").path
        try FileManager.default.createSymbolicLink(atPath: b.stateURL.path, withDestinationPath: away)
        #expect(throws: Backup.Failure.self) { _ = try b.offloaded() }
        #expect(throws: Backup.Failure.self) { try b.backUpState(now: now) }
        #expect(b.status(checkUpload: false).stateError != nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.stateURL.path) == away)
    }

    // MARK: - 2. A restore never goes into a folder it cannot list

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aRestoreRefusesAFolderItCannotList() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        // Something else now sits where the binder was, in a folder that can be written but not listed.
        try FileManager.default.createDirectory(at: e.folder, withIntermediateDirectories: true)
        try Data("invented note".utf8).write(to: e.folder.appendingPathComponent("catalog.json"))
        chmod(e.folder, 0o300)
        defer { chmod(e.folder, 0o755) }
        #expect(throws: Backup.Failure.self) { _ = try b.restore(record.backupID, now: now) }
        chmod(e.folder, 0o755)
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.folder.path) == ["catalog.json"])
        #expect(try String(contentsOf: e.folder.appendingPathComponent("catalog.json"), encoding: .utf8) == "invented note")
        #expect(try b.state().restoring.isEmpty)
        #expect(try b.offloaded().count == 1)
    }

    // MARK: - 3. A manifest leaves nothing out

    @Test func aManifestThrowsForWhatItCannotReadAndHoldsLinks() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-manifest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("documents/empty"), withIntermediateDirectories: true)
        try Data("invented deed".utf8).write(to: folder.appendingPathComponent("documents/deed.pdf"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("documents/current.pdf").path, withDestinationPath: "deed.pdf")
        let m = try Backup.manifest(folder)
        #expect(m["documents/current.pdf"] == "link deed.pdf")
        #expect(m["documents/empty"] == "folder")
        #expect(m["documents/deed.pdf"]?.count == 64)

        let hidden = folder.appendingPathComponent("documents/hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("invented secret".utf8).write(to: hidden.appendingPathComponent("note.pdf"))
        chmod(hidden, 0o000)
        defer { chmod(hidden, 0o755) }
        #expect(throws: Backup.Failure.self) { _ = try Backup.manifest(folder) }
        chmod(hidden, 0o755)
        chmod(hidden.appendingPathComponent("note.pdf"), 0o000)
        defer { chmod(hidden.appendingPathComponent("note.pdf"), 0o644) }
        #expect(throws: Backup.Failure.self) { _ = try Backup.manifest(folder) }
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func anUnreadableFolderAddedAfterARestoreStopsTheOffload() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        let restored = try b.restore(record.backupID, now: now)
        let added = restored.appendingPathComponent("correspondence/invented-new")
        try FileManager.default.createDirectory(at: added, withIntermediateDirectories: true)
        try Data("invented reply".utf8).write(to: added.appendingPathComponent("reply.pdf"))
        chmod(added, 0o000)
        defer { chmod(added, 0o755) }
        #expect(throws: (any Error).self) { _ = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("catalog.json").path))
        chmod(added, 0o755)

        guard case .done(let again) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(again.snapshot != record.snapshot)
        let s = try b.settings()
        #expect(try b.engine(s.primary).files(again.snapshot).contains("correspondence/invented-new/reply.pdf"))
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aLinkRetargetedAfterARestoreIsBackedUpAgain() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let link = "correspondence/notary/current.pdf"
        try FileManager.default.createSymbolicLink(atPath: e.folder.appendingPathComponent(link).path, withDestinationPath: "letter.pdf")
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        let restored = try b.restore(record.backupID, now: now)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: restored.appendingPathComponent(link).path) == "letter.pdf")
        try FileManager.default.removeItem(at: restored.appendingPathComponent(link))
        try FileManager.default.createSymbolicLink(atPath: restored.appendingPathComponent(link).path, withDestinationPath: "invented-later.pdf")
        guard case .done(let again) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(again.snapshot != record.snapshot)
        let back = try b.restore(again.backupID, now: now)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: back.appendingPathComponent(link).path) == "invented-later.pdf")
    }

    // MARK: - 4. A snapshot is reused only while the mirror holds it

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func anUnchangedBinderIsSnapshottedIntoANewMirror() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(record.repository == e.primary.standardizedFileURL.path)
        let restored = try b.restore(record.backupID, now: now)
        let newMirror = e.base.appendingPathComponent("icloud2/Sprava Backup")
        try b.setUp(primary: newMirror, iCloudKeychain: false)

        guard case .done(let again) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(again.repository == newMirror.standardizedFileURL.path)
        #expect(try b.engine(newMirror.path).snapshots().contains { $0.id == again.snapshot })
        #expect(try b.restore(again.backupID, now: now).path == restored.path)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func anOffloadWaitingWhileTheMirrorIsReplacedRemovesNothing() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(true)
        let b = try bb.configured(e, waiting: waiting)
        guard case .waitingForICloud = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("expected to wait for iCloud"); return
        }
        let id = try Backup.backupID(e.folder)
        try b.setUp(primary: e.base.appendingPathComponent("icloud2/Sprava Backup"), iCloudKeychain: false)
        waiting.on = false
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.state().offloads[id] == nil)
    }

    // MARK: - 5. A mirror in or around the second backup is refused

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aMirrorInsideTheSecondBackupIsRefused() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let before = try b.settings()
        #expect(throws: Backup.Failure.self) { try b.setUp(primary: e.second.appendingPathComponent("new-primary"), iCloudKeychain: false) }
        #expect(throws: Backup.Failure.self) { try b.setUp(primary: e.second.deletingLastPathComponent(), iCloudKeychain: false) }
        #expect(try b.settings() == before)
    }

    @Test func anOffloadRefusesSettingsWhoseRepositoriesShareAFate() throws {
        let e = try bb.env()
        let b = bb.backup(e)
        var s = Backup.Settings()
        s.second = e.second.path
        s.primary = e.second.appendingPathComponent("new-primary").path
        try b.save(s)
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.appendingPathComponent("catalog.json").path))
        #expect(try b.state().offloads.isEmpty)
    }

    // MARK: - 6. An offload never takes another binder's slice off the hub

    @Test func aBinderRenamedFromOutsideIsNotOffloaded() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        let inbox = e.spool.appendingPathComponent("inbox")
        let own = inbox.appendingPathComponent("\(e.folder.lastPathComponent).agenda.json")
        let other = inbox.appendingPathComponent("invented-other.agenda.json")
        try Data("{\"invented\": \"own slice\"}".utf8).write(to: own)
        try Data("{\"invented\": \"other slice\"}".utf8).write(to: other)
        // An outside edit gives the binder the other binder's name.
        let catalogURL = e.folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: catalogURL)) as? [String: Any])
        var meta = try #require(catalog["meta"] as? [String: Any])
        meta["name"] = "invented-other"
        catalog["meta"] = meta
        try JSONSerialization.data(withJSONObject: catalog).write(to: catalogURL)

        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(throws: Backup.Failure.self) { try b.removeHubSlice(Teka.read(e.folder)) }
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(FileManager.default.fileExists(atPath: own.path))
        #expect(FileManager.default.fileExists(atPath: catalogURL.path))
    }

    // MARK: - 7. A spool that cannot be searched is not a slice already gone

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aSpoolThatCannotBeSearchedStopsTheOffload() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let inbox = e.spool.appendingPathComponent("inbox")
        let slice = inbox.appendingPathComponent("\(e.folder.lastPathComponent).agenda.json")
        try Data("{\"invented\": \"slice\"}".utf8).write(to: slice)
        chmod(inbox, 0o600)
        defer { chmod(inbox, 0o755) }
        #expect(throws: Backup.Failure.self) { _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.appendingPathComponent("catalog.json").path))
        chmod(inbox, 0o755)
        #expect(FileManager.default.fileExists(atPath: slice.path))

        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(!FileManager.default.fileExists(atPath: slice.path))
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
    }

    // MARK: - 8. Opting out of iCloud Keychain takes the key out of it

    final class FakeKeychain: @unchecked Sendable {
        var calls: [String] = []
        var deleteStatus: OSStatus = errSecSuccess
        var keychain: BackupKey.Keychain {
            BackupKey.Keychain(put: { _, acct, sync in self.calls.append("put \(acct) \(sync)") },
                               delete: { acct, sync in self.calls.append("delete \(acct) \(sync)"); return self.deleteStatus })
        }
    }

    @Test func optingOutOfICloudKeychainDeletesTheSynchronizedKey() throws {
        let fake = FakeKeychain()
        try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: true, keychain: fake.keychain)
        #expect(fake.calls == ["put repository-key false", "put repository-key-icloud true"])

        fake.calls = []
        try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: false, keychain: fake.keychain)
        #expect(fake.calls == ["put repository-key false", "delete repository-key-icloud true"])

        // Nothing there to delete is fine; a deletion the Keychain refuses is reported.
        fake.deleteStatus = errSecItemNotFound
        try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: false, keychain: fake.keychain)
        fake.deleteStatus = errSecInteractionNotAllowed
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: false, keychain: fake.keychain) }
    }

    // MARK: - 9. The queue's transitions are saved, or the run says they were not

    @Test func aRequestThatCannotBeMarkedRunningIsNotRun() throws {
        let e = try bb.env()
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, hubSpool: e.spool, uploadCheck: { _ in .notInICloud })
        let requests = BackupRequests(support: e.support)
        let r = try requests.enqueue(.init(id: "invented-1", kind: "backup_now", binder: e.folder.path, at: ISOTime.string(now)))
        let folder = requests.url.deletingLastPathComponent()
        chmod(folder, 0o500)
        defer { chmod(folder, 0o700) }
        #expect(throws: (any Error).self) { try requests.run(r, backup: b, deviceID: "dev", now: now) }
        // Not run: a backup would have given the binder its backup id first.
        #expect(!FileManager.default.fileExists(atPath: e.folder.appendingPathComponent(".sprava/backup-id").path))
        chmod(folder, 0o700)
        #expect(try requests.all().first?.state == "queued")
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func anEndThatCannotBeSavedIsReported() throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        let requests = BackupRequests(support: e.support)
        let url = requests.url
        // The queue becomes unreadable while the request runs.
        b.afterSnapshot = { try? Data("[{\"id\": broken".utf8).write(to: url) }
        let r = try requests.enqueue(.init(id: "invented-2", kind: "backup_now", binder: e.folder.path, at: ISOTime.string(now)))
        #expect(throws: (any Error).self) { try requests.run(r, backup: b, deviceID: "dev", now: now) }
    }

    @Test func aRecoveryThatCannotBeSavedThrows() throws {
        let e = try bb.env()
        let requests = BackupRequests(support: e.support)
        try requests.enqueue(.init(id: "invented-3", kind: "drill", binder: "/Invented/binder", state: "running", at: ISOTime.string(now)))
        let folder = requests.url.deletingLastPathComponent()
        chmod(folder, 0o500)
        defer { chmod(folder, 0o700) }
        #expect(throws: (any Error).self) { try requests.recoverInterrupted(now: now) }
        chmod(folder, 0o700)
        #expect(try requests.all().first?.state == "running")
    }
}

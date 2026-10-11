@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Setting up the mirror and the second backup, binder snapshots, backup ids, manifests, retention, checks and the
/// restore drill. restic runs against repositories in temporary folders only, or is replaced by a /bin/sh stand-in;
/// the tests that need the real restic are skipped without it. Invented data only.
@Suite(.serialized) struct BackupSnapshotTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let hasRestic = Restic.locate() != nil

    struct Env {
        let base: URL
        let support: URL
        let folder: URL
        var primary: URL { base.appendingPathComponent("icloud/Sprava Backup") }
        var second: URL { base.appendingPathComponent("external/Sprava Second") }
    }

    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-snapshots-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// An adopted binder holding one invented letter, and an empty support folder.
    func env() throws -> Env {
        let base = try temp("env")
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: folder.appendingPathComponent("correspondence/notary/letter.pdf"))
        return Env(base: base, support: base.appendingPathComponent("support"), folder: folder)
    }

    func backup(_ e: Env, key: String = "TEST-KEY-AAAAA-BBBBB", upload: Backup.Upload = .uploaded) -> Backup {
        Backup(support: e.support, key: key, uploadCheck: { _ in upload }, secondLocationCheck: { _ in true })
    }

    /// A Backup with the mirror and the second backup set up.
    func configured(_ e: Env) throws -> Backup {
        let b = backup(e)
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        try b.setSecond(e.second)
        return b
    }

    // MARK: - Setup

    @Test func setupRefusesAResticItCannotRead() throws {
        let base = try temp("unreadable")
        let binary = base.appendingPathComponent("restic")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        chmod(binary.path, 0o111)
        let b = Backup(support: base.appendingPathComponent("support"), key: "TEST-KEY-AAAAA-BBBBB", resticBinary: binary,
                       uploadCheck: { _ in .uploaded })
        do {
            try b.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
            Issue.record("set up with a restic it cannot read")
        } catch let failure as Backup.Failure {
            #expect(failure.message.contains("cannot be read to check it"))
        }
        #expect(try b.settings().primary == nil)
    }

    @Test func settingsThatCannotBeOpenedAreNeverSavedOver() throws {
        let e = try env()
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: URL(fileURLWithPath: "/usr/bin/true"),
                       uploadCheck: { _ in .notInICloud })
        try AtomicFile.makePrivateFolder(b.dir)
        let data = Data(#"{"primary": "/invented/mirror", "keepLast": 5}"#.utf8)
        try data.write(to: b.settingsURL)
        chmod(b.settingsURL.path, 0o000)
        defer { chmod(b.settingsURL.path, 0o600) }
        #expect(throws: Backup.Failure.self) { try b.setUp(primary: e.primary, iCloudKeychain: false) }
        #expect(throws: Backup.Failure.self) { try b.setSecond(e.second) }
        chmod(b.settingsURL.path, 0o600)
        #expect(try Data(contentsOf: b.settingsURL) == data)
    }

    @Test func theSecondBackupCannotShareTheMirrorsFate() throws {
        let e = try env()
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .uploaded })
        var s = Backup.Settings()
        s.primary = e.primary.path
        try b.save(s)
        try FileManager.default.createDirectory(at: e.primary, withIntermediateDirectories: true)
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Invented Second")
        for folder in [e.primary, e.primary.appendingPathComponent("sub"), e.primary.deletingLastPathComponent(), iCloud] {
            #expect(throws: Backup.Failure.self) { try b.setSecond(folder) }
        }
        #expect(try b.settings().second == nil)
        #expect(!FileManager.default.fileExists(atPath: iCloud.path))
    }

    @Test(.enabled(if: hasRestic)) func aPrimaryOutsideICloudIsNeverSavedAsTheMirror() throws {
        let e = try env()
        #expect(throws: Backup.Failure.self) { try backup(e, upload: .notInICloud).setUp(primary: e.primary, iCloudKeychain: false) }
        #expect(try backup(e).settings().primary == nil)
        // The repository setup made there is taken away again.
        #expect(!FileManager.default.fileExists(atPath: e.primary.path))
    }

    @Test(.enabled(if: hasRestic)) func aMirrorInsideTheSecondBackupIsRefused() throws {
        let e = try env()
        let b = try configured(e)
        let before = try b.settings()
        #expect(throws: Backup.Failure.self) { try b.setUp(primary: e.second.appendingPathComponent("new-primary"), iCloudKeychain: false) }
        #expect(throws: Backup.Failure.self) { try b.setUp(primary: e.second.deletingLastPathComponent(), iCloudKeychain: false) }
        #expect(try b.settings() == before)
    }

    @Test(.enabled(if: hasRestic)) func resticCanBeTrustedAgainWhileTheSecondDiskIsAway() throws {
        let e = try env()
        let b = try configured(e)
        let away = e.second.deletingLastPathComponent().appendingPathComponent("invented-away")
        try FileManager.default.moveItem(at: e.second, to: away)
        let refusing = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .uploaded },
                              secondLocationCheck: { _ in false })
        var stale = try b.settings()
        stale.resticSHA256 = String(repeating: "0", count: 64)
        try b.save(stale)
        try refusing.setUp(primary: e.primary, iCloudKeychain: false)
        #expect(try b.settings().resticSHA256 == Restic.sha256(of: try #require(Restic.locate())))
        // A new mirror still needs the second backup to be independent of it.
        #expect(throws: Backup.Failure.self) {
            try refusing.setUp(primary: e.base.appendingPathComponent("icloud/Another Mirror"), iCloudKeychain: false)
        }
        try FileManager.default.moveItem(at: away, to: e.second)
    }

    @Test(.enabled(if: hasRestic)) func aRepositoryMadeAgainAtItsOwnPathStartsEmpty() throws {
        let e = try env()
        let b = try configured(e)
        try b.backUp(e.folder, now: now)
        try b.check(readData: true, now: now)
        let id = try Backup.backupID(e.folder)
        // The mirror's folder is gone; setup again at the same path makes an empty one.
        try FileManager.default.removeItem(at: e.primary)
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        var st = try b.state()
        #expect(st.binders[id]?.snapshot == nil && st.binders[id]?.at == nil && st.lastCheck == nil)
        // The second backup's folder is gone too: while a binder is offloaded, it is not made again empty.
        try FileManager.default.removeItem(at: e.second)
        st.offloaded = [Backup.Offloaded(backupID: id, name: "Invented", originalPath: e.folder.path, snapshot: "0123abcd",
                                         bytes: 1, at: ISOTime.string(now), summary: "invented", documents: [], openItemsConfirmed: 0)]
        try b.save(st)
        #expect(throws: Backup.Failure.self) { try b.setSecond(e.second) }
        #expect(!FileManager.default.fileExists(atPath: e.second.appendingPathComponent("config").path))
    }

    @Test(.enabled(if: hasRestic)) func aWrongKeyNeverReplacesTheWorkingMirror() throws {
        let e = try env()
        let b = backup(e)
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        let other = e.base.appendingPathComponent("other/Sprava Backup")
        try Backup(support: e.base.appendingPathComponent("support2"), key: "OTHER-KEY-CCCCC",
                   uploadCheck: { _ in .uploaded }).setUp(primary: other, iCloudKeychain: false)
        #expect(throws: (any Error).self) { try backup(e, key: "WRONG-KEY-DDDDD").setUp(primary: other, iCloudKeychain: false) }
        #expect(try b.settings().primary == e.primary.standardizedFileURL.path)
    }

    @Test(.enabled(if: hasRestic)) func movingAMirrorKeepsTheOldOneForExpungingAndWaitsForOffloadedBinders() throws {
        let e = try env()
        let b = try configured(e)
        try b.backUp(e.folder, now: now)
        try b.check(readData: true, now: now)
        try b.drill(e.folder, now: now)
        try b.drill(e.folder, repository: .second, now: now)
        let id = try Backup.backupID(e.folder)
        let moved = e.base.appendingPathComponent("icloud/Sprava Backup Moved")
        try b.setUp(primary: moved, iCloudKeychain: false)
        #expect(try b.state().binders[id]?.repositories.contains(e.primary.standardizedFileURL.path) == true)
        // The binder's last snapshot is in the old mirror: in the new one it is due, and not shown as backed up.
        #expect(try b.state().binders[id]?.snapshot == nil && b.state().binders[id]?.at == nil && b.state().binders[id]?.error == nil)
        // The old mirror's checks do not count for the new one; the second backup's still do.
        var checked = try b.state()
        #expect(checked.lastCheck == nil && checked.lastReadData == nil && checked.readDataPart == 0 && checked.lastDrill == nil)
        #expect(checked.lastSecondDrill == ISOTime.string(now))
        #expect(checked.lastSecondCheck == ISOTime.string(now) && checked.secondReadDataPart == 1)
        try b.setSecond(e.base.appendingPathComponent("external/Another Second"))
        checked = try b.state()
        #expect(checked.lastSecondCheck == nil && checked.lastSecondReadData == nil && checked.secondReadDataPart == 0)
        #expect(checked.lastSecondDrill == nil)
        try b.setSecond(e.second)

        // An offloaded binder's pinned snapshots are its only copies: no repository moves away from them yet.
        var st = try b.state()
        st.offloaded = [Backup.Offloaded(backupID: id, name: "Invented", originalPath: e.folder.path, snapshot: "0123abcd",
                                         bytes: 1, at: ISOTime.string(now), summary: "invented", documents: [], openItemsConfirmed: 0)]
        try b.save(st)
        let settings = try b.settings()
        #expect(throws: Backup.Failure.self) { try b.setUp(primary: e.primary, iCloudKeychain: false) }
        #expect(throws: Backup.Failure.self) { try b.setSecond(e.base.appendingPathComponent("external/Another Second")) }
        #expect(try b.settings() == settings)
    }

    // MARK: - Snapshots, retention, checks and the drill

    @Test(.enabled(if: hasRestic)) func snapshotsSkipWhenNothingChanged() throws {
        let e = try env()
        let b = try configured(e)
        // A link with an attribute of its own, and a hard link: the drills below compare them after a real restore.
        let link = e.folder.appendingPathComponent("correspondence/notary/current.pdf")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "letter.pdf")
        let note = Array("invented link note".utf8)
        #expect(setxattr(link.path, "com.example.invented", note, note.count, 0, XATTR_NOFOLLOW) == 0)
        try FileManager.default.linkItem(at: e.folder.appendingPathComponent("correspondence/notary/letter.pdf"),
                                         to: e.folder.appendingPathComponent("correspondence/notary/letter-copy.pdf"))
        #expect(try b.backUp(e.folder, now: now).snapshot != nil)
        #expect(try b.backUp(e.folder, now: now).snapshot == nil)
        try Data("more".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/second.pdf"))
        #expect(try b.backUp(e.folder, now: now).snapshot != nil)
        try b.backUpState(now: now)
        try b.applyRetention(now: now)
        try b.check(readData: true, now: now)
        try b.drill(e.folder, repository: .second, now: now)
        // A drill of the second backup says nothing about restoring from the mirror.
        #expect(try b.state().lastDrill == nil && b.state().lastSecondDrill == ISOTime.string(now))
        try b.drill(e.folder, now: now)
        let st = try b.state()
        #expect(st.lastDrill == ISOTime.string(now) && st.stateSnapshotAt == ISOTime.string(now))
        // Retention runs on both repositories, and the second backup's drill snapshots follow it too.
        try b.applyRetention(now: now)
    }

    @Test(.enabled(if: hasRestic)) func theDrillRestoresTheSnapshotItTookNotTheLatestByTime() throws {
        let e = try env()
        let b = try configured(e)
        let id = try Backup.backupID(e.folder)
        // A snapshot of other contents, taken under a clock that was ahead, sorts last by time.
        let letter = e.folder.appendingPathComponent("correspondence/notary/letter.pdf")
        try Data("invented earlier letter".utf8).write(to: letter)
        let planted = try b.engine(e.primary.path).run(["backup", ".", "--host", "sprava", "--tag", "sprava", "--tag", "binder:\(id)",
                                                         "--time", "2099-01-01 00:00:00"], cwd: e.folder)
        #expect(planted.status == 0)
        try Data("invented current letter".utf8).write(to: letter)
        try b.drill(e.folder, now: now)
        #expect(try b.state().lastDrill == ISOTime.string(now))
    }

    @Test(.enabled(if: hasRestic)) func aSnapshotWhoseRecordWasLostIsRecordedOnTheNextRun() throws {
        let e = try env()
        let b = try configured(e)
        let first = try #require(try b.backUp(e.folder, now: now).snapshot)
        // As if the run had stopped right after restic wrote the snapshot, before its record was saved.
        let id = try Backup.backupID(e.folder)
        var st = try b.state()
        st.binders[id]?.snapshot = nil
        st.binders[id]?.at = nil
        try b.save(st)
        #expect(try b.backUp(e.folder, now: now).snapshot == nil)
        #expect(try b.state().binders[id]?.snapshot == first)
    }

    @Test(.enabled(if: hasRestic)) func aSkippedRunRecordsTheParentResticUsed() throws {
        let e = try env()
        let b = try configured(e)
        let current = try #require(try b.backUp(e.folder, now: now).snapshot)
        let id = try Backup.backupID(e.folder)
        // A snapshot of other contents, taken under a clock that was ahead, is the latest by date.
        let letter = e.folder.appendingPathComponent("correspondence/notary/letter.pdf")
        let original = try Data(contentsOf: letter)
        try Data("invented earlier letter".utf8).write(to: letter)
        _ = try b.engine(e.primary.path).run(["backup", ".", "--host", "sprava", "--tag", "sprava", "--tag", "binder:\(id)",
                                              "--time", "2099-01-01 00:00:00"], cwd: e.folder)
        try original.write(to: letter)
        try FileManager.default.setAttributes([.modificationDate: try #require(
            try b.engine(e.primary.path).snapshots(tag: "binder:\(id)").first { $0.id == current }?.date)], ofItemAtPath: letter.path)
        var st = try b.state()
        st.binders[id]?.snapshot = nil
        try b.save(st)
        let rerun = try b.backUp(e.folder, now: now)
        #expect(try b.state().binders[id]?.snapshot == (rerun.snapshot ?? current))
        #expect(try b.state().binders[id]?.snapshot != b.engine(e.primary.path).snapshots(tag: "binder:\(id)").last { $0.date ?? .distantPast > Date() }?.id)
    }

    @Test(.enabled(if: hasRestic)) func aFailedBackupKeepsNoFileNameInItsError() throws {
        let e = try env()
        let b = try configured(e)
        let secret = e.folder.appendingPathComponent("correspondence/notary/invented-private-name.pdf")
        try Data("invented".utf8).write(to: secret)
        chmod(secret.path, 0o000)
        defer { chmod(secret.path, 0o644) }
        #expect(throws: (any Error).self) { try b.backUp(e.folder, now: now) }
        let error = try #require(try b.state().binders[Backup.backupID(e.folder)]?.error)
        #expect(!error.contains("invented-private-name") && !error.contains(e.folder.lastPathComponent))
    }

    @Test(.enabled(if: hasRestic)) func aMovedBinderTakesItsRecordAlong() throws {
        let e = try env()
        let b = try configured(e)
        try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        let moved = e.folder.deletingLastPathComponent().appendingPathComponent("invented-moved", isDirectory: true)
        try FileManager.default.moveItem(at: e.folder, to: moved)
        try b.backUp(moved, now: now)
        #expect(try b.state().binders[id]?.path == moved.standardizedFileURL.path)
    }

    @Test(.enabled(if: hasRestic)) func aWriteDuringASnapshotLeavesTheBinderDue() throws {
        let e = try env()
        var b = try configured(e)
        let landed = e.folder.appendingPathComponent("correspondence/notary/invented-during-snapshot.pdf")
        b.afterSnapshot = { try? Data("invented late document".utf8).write(to: landed) }
        #expect(try b.backUp(e.folder, now: now).snapshot != nil)
        let id = try Backup.backupID(e.folder)
        #expect(try b.state().binders[id]?.at == nil)
        b.afterSnapshot = nil
        try b.backUp(e.folder, now: now)
        #expect(try b.state().binders[id]?.at == ISOTime.string(now))
    }

    @Test(.enabled(if: hasRestic)) func aDrillOfTheMirrorCountsAsTheBindersBackup() throws {
        let e = try env()
        let b = try configured(e)
        try b.drill(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        let record = try #require(try b.state().binders[id])
        #expect(record.at == ISOTime.string(now) && record.snapshot != nil && record.error == nil)
    }

    @Test(.enabled(if: hasRestic)) func aChangeToTheFoldersOwnSettingsDuringADrillFailsIt() throws {
        let e = try env()
        var b = try configured(e)
        let folder = e.folder
        b.afterSnapshot = { _ = chmod(folder.path, 0o700) }
        #expect(throws: Backup.Failure.self) { try b.drill(e.folder, now: now) }
        #expect(try b.state().lastDrill == nil)
    }

    @Test(.enabled(if: hasRestic)) func aChangeToTheFoldersOwnSettingsDuringASnapshotLeavesTheBinderDue() throws {
        let e = try env()
        var b = try configured(e)
        let folder = e.folder
        b.afterSnapshot = { _ = chmod(folder.path, 0o700) }
        #expect(try b.backUp(e.folder, now: now).snapshot != nil)
        #expect(try b.state().binders[Backup.backupID(e.folder)]?.at == nil)
    }

    @Test(.enabled(if: hasRestic)) func theStateSnapshotLeavesTheRuntimesLogsOutAndKeepsCaptures() throws {
        let e = try env()
        let b = try configured(e)
        let runtime = e.support.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        for name in ["jobs.log", "jobs.log.1", "lease-refusals.log", "lease-refusals.log.2", "settings.json"] {
            try Data("invented\n".utf8).write(to: runtime.appendingPathComponent(name))
        }
        // A capture's attachment may end in .log: it is the person's document, and stays in the backup.
        let captures = e.support.appendingPathComponent("Captures/invented-device", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try Data("invented attachment\n".utf8).write(to: captures.appendingPathComponent("0b6f1a52-6f0e-4c1e-9a55-3c2f8e1d7a10.file-1.log"))
        let mcp = e.support.appendingPathComponent("mcp", isDirectory: true)
        try FileManager.default.createDirectory(at: mcp.appendingPathComponent("audit"), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: mcp.appendingPathComponent("clients.json"))
        for name in ["invented-client.ndjson", "invented-client.ndjson.1"] {
            try Data("{}\n".utf8).write(to: mcp.appendingPathComponent("audit/\(name)"))
        }
        try b.backUpState(now: now)
        let r = try b.engine(e.primary.path)
        let snap = try #require(try r.snapshots(tag: "sprava-state").last)
        let files = try r.files(snap.id)
        #expect(files.contains("runtime/settings.json"))
        #expect(files.contains("Captures/invented-device/0b6f1a52-6f0e-4c1e-9a55-3c2f8e1d7a10.file-1.log"))
        #expect(!files.contains { $0.hasPrefix("runtime/") && $0.contains(".log") })
        #expect(files.contains("mcp/clients.json") && !files.contains { $0.hasPrefix("mcp/audit") })
    }

    @Test func retentionForgetsEveryBinderThenPrunesOnce() throws {
        let base = try temp("retention")
        let log = base.appendingPathComponent("restic-arguments.log")
        let binary = base.appendingPathComponent("restic")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\nexit 0\n".utf8).write(to: binary)
        chmod(binary.path, 0o755)
        let b = Backup(support: base.appendingPathComponent("support"), key: "TEST-KEY-AAAAA-BBBBB", resticBinary: binary,
                       uploadCheck: { _ in .uploaded })
        var settings = Backup.Settings()
        settings.primary = base.appendingPathComponent("mirror").path
        settings.resticSHA256 = Restic.sha256(of: binary)
        try b.save(settings)
        var st = Backup.State()
        st.binders["0123456789abcdef0123456789abcdef"] = .init()
        st.binders["fedcba9876543210fedcba9876543210"] = .init()
        try b.save(st)

        try b.applyRetention(now: now)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 4)
        #expect(lines.filter { $0.hasPrefix("forget ") }.count == 3)
        #expect(lines.contains { $0.hasPrefix("forget ") && $0.contains("sprava-state") })
        #expect(lines.filter { $0.hasPrefix("forget ") }.allSatisfy { !$0.contains("--prune") })
        #expect(lines.filter { $0.hasPrefix("prune ") }.count == 1)
        #expect(try b.state().lastForget == ISOTime.string(now))
    }

    @Test(.enabled(if: hasRestic)) func theSecondBackupIsCheckedOnItsOwnAndRetriesItsPart() throws {
        let e = try env()
        let b = try configured(e)
        try b.check(readData: true, now: now)
        var st = try b.state()
        #expect(st.readDataPart == 1 && st.secondReadDataPart == 1)
        #expect(st.lastCheck != nil && st.lastSecondCheck != nil)

        // A second backup that is away fails the check and stays due; the mirror's check still counts.
        let later = now.addingTimeInterval(31 * 86_400)
        let away = e.second.deletingLastPathComponent().appendingPathComponent("invented-away")
        try FileManager.default.moveItem(at: e.second, to: away)
        do {
            try b.check(readData: true, now: later)
            Issue.record("a missing second backup passed its check")
        } catch {
            #expect("\(error)".contains("the second backup"))
        }
        st = try b.state()
        #expect(st.readDataPart == 2 && st.lastReadData == ISOTime.string(later) && st.lastCheck == ISOTime.string(later))
        #expect(st.secondReadDataPart == 1 && st.lastSecondReadData == ISOTime.string(now) && st.lastSecondCheck == ISOTime.string(now))

        // Back again, it reads the part it missed.
        try FileManager.default.moveItem(at: away, to: e.second)
        let retried = later.addingTimeInterval(3600)
        try b.check(readPrimaryData: false, readSecondData: true, primary: false, second: true, now: retried)
        st = try b.state()
        #expect(st.secondReadDataPart == 2 && st.lastSecondReadData == ISOTime.string(retried))
    }

    @Test func aStateLinkToAPlaceThatIsAwayIsNeverReplaced() throws {
        let e = try env()
        let b = backup(e)
        var s = Backup.Settings()
        s.primary = e.primary.path
        try b.save(s)
        let away = e.base.appendingPathComponent("unmounted-disk/state.json").path
        try FileManager.default.createSymbolicLink(atPath: b.stateURL.path, withDestinationPath: away)
        #expect(throws: Backup.Failure.self) { try b.backUpState(now: now) }
        #expect(throws: Backup.Failure.self) { try b.backUp(e.folder, now: now) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: b.stateURL.path) == away)
    }
}

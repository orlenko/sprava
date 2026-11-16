@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// One Mac per repository (decisions.md D44): the per-Mac default folder, the marker setup and every run check, taking
/// a repository over, and retention that never forgets another Mac's snapshots. restic runs against repositories in
/// temporary folders only, never the person's iCloud Drive; those tests are skipped without it. Invented binders and
/// Mac names only.
@Suite(.serialized) struct BackupMacTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let hasRestic = Restic.locate() != nil

    struct Env {
        let base: URL
        let folder: URL
        var primary: URL { base.appendingPathComponent("icloud/Sprava Backup/Invented Studio") }
        var second: URL { base.appendingPathComponent("external/Sprava Second") }
        func support(_ mac: String) -> URL { base.appendingPathComponent("support-\(mac)") }
    }

    func env() throws -> Env {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-mac-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        try Data("invented letter".utf8).write(to: folder.appendingPathComponent("letter.pdf"))
        return Env(base: base, folder: folder)
    }

    /// The Backup of one invented Mac, with its own support folder and the shared test key.
    func backup(_ e: Env, _ mac: String) -> Backup {
        Backup(support: e.support(mac), key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true })
    }

    func maintain(_ b: Backup, _ e: Env, device: String = "dev", at: Date? = nil) -> Backup.Maintenance {
        b.maintain(rows: Shelf.rows(registry: nil, picked: [e.folder]), deviceID: device, nameCollides: { _ in false }, now: at ?? now)
    }

    @Test func theDefaultFolderIsTheMacsOwnAndSafeAsAName() {
        #expect(Backup.folderName(forMac: "Invented Studio") == "Invented Studio")
        #expect(Backup.folderName(forMac: "Lab/Desk: 2") == "Lab-Desk- 2")
        #expect(Backup.folderName(forMac: "..hidden") == "hidden")
        #expect(Backup.folderName(forMac: " \n ") == "This Mac")
        #expect(Backup.folderName(forMac: String(repeating: "x", count: 300)).count == 80)
        let folder = Backup.defaultPrimary(macName: "Invented Studio")
        #expect(folder.path.hasSuffix("/com~apple~CloudDocs/Sprava Backup/Invented Studio"))
        #expect(Backup.macMark("dev").wholeMatch(of: /[0-9a-f]{16}/) != nil && Backup.macMark("dev") != Backup.macMark("other"))
    }

    @Test(.enabled(if: hasRestic)) func setupRefusesAnotherMacsRepositoryUntilTakenOver() throws {
        let e = try env()
        let studio = backup(e, "studio")
        try studio.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "dev")
        let marker = try #require(try Backup.readMarker(e.primary))
        #expect(marker.mac == Backup.macMark("dev"))
        // A second Mac, signed in to the same iCloud Drive, picks the same folder: refused, and nothing is saved.
        let laptop = backup(e, "laptop")
        do {
            try laptop.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "laptop")
            Issue.record("set up on another Mac's repository")
        } catch let other as Backup.OtherMac {
            #expect(other.repository == "primary" && other.name == marker.name)
            #expect(other.description.contains("belongs to another Mac"))
        }
        #expect(try laptop.settings().primary == nil)
        #expect(try Backup.readMarker(e.primary) == marker)
        // Taken over by choice: the repository names the laptop, and the studio's snapshots follow its retention.
        try laptop.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "laptop", takeOver: true)
        #expect(try Backup.readMarker(e.primary)?.mac == Backup.macMark("laptop"))
        #expect(try laptop.settings().formerMacs == [Backup.macMark("dev")])
        // Handed back to the studio by choice: having taken it once gives the laptop no right to take it again.
        try studio.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "dev", takeOver: true)
        let snapshots = try studio.engine(e.primary.path).snapshots().map(\.id)
        let m = laptop.maintain(rows: [], deviceID: "laptop", nameCollides: { _ in false }, now: now)
        #expect(m.failedParts == ["other_mac"] && !m.retention)
        #expect(try Backup.readMarker(e.primary)?.mac == Backup.macMark("dev"))
        #expect(try studio.engine(e.primary.path).snapshots().map(\.id) == snapshots)
    }

    @Test(.enabled(if: hasRestic)) func aRunOnARepositoryAnotherMacTookStopsBeforePruning() throws {
        let e = try env()
        let studio = backup(e, "studio")
        try studio.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "dev")
        #expect(maintain(studio, e).snapshots == 1)
        let r = try studio.engine(e.primary.path)
        let before = try r.snapshots().map(\.id)
        try backup(e, "laptop").setUp(primary: e.primary, iCloudKeychain: false, deviceID: "laptop", takeOver: true)
        // A week later everything would be due; nothing runs, and the status says why.
        try Data("invented page".utf8).write(to: e.folder.appendingPathComponent("page.pdf"))
        let m = maintain(studio, e, at: now.addingTimeInterval(8 * 86_400))
        #expect(m.failedParts == ["other_mac"] && m.snapshots == 0 && !m.retention && !m.checked)
        #expect(studio.status(checkUpload: false).otherMac?.repository == "primary")
        #expect(try r.snapshots().map(\.id) == before)
        // Every command on it is refused too, not only the scheduled run.
        #expect(throws: Backup.OtherMac.self) { try studio.backUp(e.folder, now: now) }
        #expect(throws: Backup.OtherMac.self) { try studio.applyRetention(now: now) }
    }

    @Test(.enabled(if: hasRestic)) func settingsCopiedFromAnotherMacStopUntilTakenOver() throws {
        let e = try env()
        let b = backup(e, "studio")
        try b.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "dev")
        try b.setSecond(e.second, deviceID: "dev")
        // The same support folder on a new Mac (Migration Assistant): its device id is new.
        let m = maintain(b, e, device: "new-mac")
        #expect(m.failedParts == ["other_mac"] && m.snapshots == 0)
        #expect(b.status(checkUpload: false).otherMac == Backup.OtherMac(repository: "settings", name: nil))
        #expect(throws: Backup.OtherMac.self) { try b.setSecond(e.second, deviceID: "new-mac") }
        // The second backup's disk is away while the person takes the backups over.
        let away = e.base.appendingPathComponent("external/away")
        try FileManager.default.moveItem(at: e.second, to: away)
        try b.takeOver("new-mac")
        #expect(try Backup.readMarker(e.primary)?.mac == Backup.macMark("new-mac"))
        #expect(try b.settings().formerMacs == [Backup.macMark("dev")])
        #expect(b.status(checkUpload: false).otherMac == nil)
        // Back, it still names the old Mac, whose backups were taken over: the next run marks it, with no second choice.
        try FileManager.default.moveItem(at: away, to: e.second)
        #expect(try Backup.readMarker(e.second)?.mac == Backup.macMark("dev"))
        #expect(try b.settings().pendingTakeOver == [e.second.standardizedFileURL.path])
        #expect(maintain(b, e, device: "new-mac").failed == 0)
        #expect(try Backup.readMarker(e.second)?.mac == Backup.macMark("new-mac"))
        // Used once: the permission does not stay behind.
        #expect(try b.settings().pendingTakeOver == nil)
    }

    @Test(.enabled(if: hasRestic)) func aRepositorySetUpBeforeTheMarkerIsMarkedAtTheNextRun() throws {
        let e = try env()
        let b = backup(e, "studio")
        try b.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "dev")
        try FileManager.default.removeItem(at: e.primary.appendingPathComponent(Backup.markerName))
        var s = try b.settings()
        s.mac = nil
        try b.save(s)
        // Until then nothing is forgotten: whose snapshots these are is not known yet.
        #expect(throws: Backup.Failure.self) { try b.applyRetention(now: now) }
        #expect(maintain(b, e).failed == 0)
        #expect(try b.settings().mac == Backup.macMark("dev"))
        #expect(try Backup.readMarker(e.primary) == Backup.Marker(mac: Backup.macMark("dev"), name: Backup.thisMacName(), legacy: true))
        #expect(try b.settings().legacy == [e.primary.standardizedFileURL.path])
    }

    /// The Mac that first marks a repository set up before D44 adopts its snapshots from then (host `sprava`): its
    /// retention covers them, never another Mac's; a takeover hands them on with the rest.
    @Test(.enabled(if: hasRestic)) func theMacThatMarksAnOlderRepositoryAdoptsItsOldSnapshots() throws {
        let e = try env()
        let studio = backup(e, "studio")
        try studio.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "dev")
        // A repository made here is new: nothing from before D44 to adopt.
        #expect(try studio.settings().legacy == nil && Backup.readMarker(e.primary)?.legacy == nil)
        var s = try studio.settings()
        s.keepLast = 1
        try studio.save(s)
        try studio.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        let r = try studio.engine(e.primary.path)
        for (host, day) in [(Backup.legacyHost, 1), (Backup.legacyHost, 2), (Backup.legacyHost, 3),
                            ("sprava-0123456789abcdef", 1), ("sprava-0123456789abcdef", 2)] {
            try r.checked(["backup", ".", "--host", host, "--tag", "sprava", "--tag", "binder:\(id)", "--time",
                           "2020-01-0\(day) 12:00:00", "-q"], cwd: e.folder)
        }
        // As the repository was before D44: no marker, and settings that name no Mac.
        try FileManager.default.removeItem(at: e.primary.appendingPathComponent(Backup.markerName))
        s = try studio.settings()
        s.mac = nil
        try studio.save(s)
        func count(_ host: String) throws -> Int { try r.snapshots(tag: "binder:\(id)").filter { $0.hostname == host }.count }
        let m = maintain(studio, e)
        #expect(m.failed == 0 && m.retention)
        #expect(try Backup.readMarker(e.primary)?.legacy == true)
        // restic keeps January 2020's last and the oldest while the monthly and yearly counts are not reached.
        #expect(try count(Backup.legacyHost) == 2)
        #expect(try count("sprava-0123456789abcdef") == 2)
        // Taken over, they go with the rest.
        let laptop = backup(e, "laptop")
        try laptop.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "laptop", takeOver: true)
        #expect(try laptop.settings().legacy == [e.primary.standardizedFileURL.path])
        #expect(try Backup.readMarker(e.primary)?.legacy == true && Backup.readMarker(e.primary)?.mac == Backup.macMark("laptop"))
    }

    @Test func aRepositoryInsideAnotherIsRefused() throws {
        let e = try env()
        let outer = e.base.appendingPathComponent("icloud/Sprava Backup")
        try FileManager.default.createDirectory(at: outer.appendingPathComponent("keys"), withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: outer.appendingPathComponent("config"))
        let b = backup(e, "laptop")
        do {
            try b.setUp(primary: outer.appendingPathComponent("Invented Laptop"), iCloudKeychain: false, deviceID: "laptop")
            Issue.record("set up inside another repository")
        } catch let failure as Backup.Failure {
            #expect(failure.message.contains("inside another backup"))
        }
        #expect(try b.settings().primary == nil)
    }

    @Test func aMarkerThatIsNotOneIsUnreadableNeverAnotherMac() throws {
        let e = try env()
        let folder = e.base.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(try Backup.readMarker(folder) == nil)
        let file = folder.appendingPathComponent(Backup.markerName)
        try Data(#"{"mac":"not-a-mark","name":"Invented"}"#.utf8).write(to: file)
        #expect(throws: Backup.Failure.self) { try Backup.readMarker(folder) }
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: e.folder.appendingPathComponent("letter.pdf"))
        #expect(throws: Backup.Failure.self) { try Backup.readMarker(folder) }
        try FileManager.default.removeItem(at: file)
        try Data(#"{"mac":"0123456789abcdef","name":"Invented\u0007 Studio"}"#.utf8).write(to: file)
        #expect(try Backup.readMarker(folder) == Backup.Marker(mac: "0123456789abcdef", name: "Invented Studio"))
    }

    /// The second wall: whatever the markers say, retention forgets only this Mac's snapshots (and a taken-over Mac's),
    /// never another Mac's nor those from before D44.
    @Test(.enabled(if: hasRestic)) func retentionNeverForgetsAnotherMacsSnapshots() throws {
        let e = try env()
        let b = backup(e, "studio")
        try b.setUp(primary: e.primary, iCloudKeychain: false, deviceID: "dev")
        var s = try b.settings()
        s.keepLast = 1
        try b.save(s)
        try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        let r = try b.engine(e.primary.path)
        // Old snapshots of the same binder under three hosts: this Mac's, another Mac's, and the one before D44.
        for (host, day) in [(r.host, 1), (r.host, 2), (r.host, 3), ("sprava-0123456789abcdef", 1), ("sprava-0123456789abcdef", 2),
                            (Backup.legacyHost, 1), (Backup.legacyHost, 2)] {
            try r.checked(["backup", ".", "--host", host, "--tag", "sprava", "--tag", "binder:\(id)", "--time",
                           "2020-01-0\(day) 12:00:00", "-q"], cwd: e.folder)
        }
        func count(_ host: String) throws -> Int { try r.snapshots(tag: "binder:\(id)").filter { $0.hostname == host }.count }
        #expect(try count(r.host) == 4)
        try b.applyRetention(now: now)
        // Some of this Mac's are forgotten (restic keeps the newest, January 2020's last, and the oldest while the
        // monthly and yearly counts are not reached); nothing of the others is touched.
        #expect(try count(r.host) == 3)
        #expect(try count("sprava-0123456789abcdef") == 2 && count(Backup.legacyHost) == 2)
    }
}

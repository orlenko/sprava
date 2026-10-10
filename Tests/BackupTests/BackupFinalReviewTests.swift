@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
import Security
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the last Bugbot review of the Backup layer and issue #205 (a restic run that waits forever).
/// restic runs against repositories in temporary folders only, or is replaced by a /bin/sh stand-in. Invented data only.
@Suite(.serialized) struct BackupFinalReviewTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()

    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-final-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A Restic whose binary is `script`, a /bin/sh stand-in, with its own repository and support folders.
    func standIn(_ script: String) throws -> (Restic, URL) {
        let base = try temp("standin")
        let binary = base.appendingPathComponent("restic")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: binary)
        chmod(binary.path, 0o755)
        var r = Restic(binary: binary, repository: base.appendingPathComponent("repo"), key: "TEST-KEY-AAAAA-BBBBB",
                       support: base.appendingPathComponent("support"))
        r.grace = 0.5
        return (r, base)
    }

    // MARK: - #205: a restic run can wait forever

    @Test func aChildLeftHoldingResticsOutputNeverHoldsUpTheRun() throws {
        let (r, base) = try standIn("sleep 30 &\necho $! > \"$(dirname \"$0\")/child.pid\"\necho done\nexit 0")
        let started = Date()
        let o = try r.run(["snapshots"])
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(o.status == 0)
        #expect(String(decoding: o.stdout, as: UTF8.self) == "done\n")
        // The child it left is stopped with it.
        let pid = try #require(Int32(String(contentsOf: base.appendingPathComponent("child.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<100 where !gone {
            gone = kill(pid, 0) != 0 && errno == ESRCH
            if !gone { usleep(20_000) }
        }
        #expect(gone)
    }

    @Test func aResticThatIgnoresSIGTERMIsKilledAtTheDeadline() throws {
        let (r, _) = try standIn("trap '' TERM\nsleep 30 &\nwhile :; do sleep 1; done")
        let started = Date()
        #expect(throws: Restic.Failure.self) { try r.run(["check"], timeout: 1) }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: - q5Hag: the no-progress cutoff

    @Test func aResticThatOnlyCountsTheSecondsIsStoppedAsStalled() throws {
        let (r, _) = try standIn("i=0\nwhile :; do i=$((i+1)); echo \"[0:0$i] 10.00%  1 / 10 packs\"; sleep 0.1; done")
        let started = Date()
        do {
            try r.run(["check"], stall: 1)
            Issue.record("a stalled run finished")
        } catch let failure as Restic.Failure {
            #expect(failure.message.contains("no progress"))
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(ResticProcess.progressKey(#"{"message_type":"status","seconds_elapsed":5,"seconds_remaining":9,"percent_done":0.5}"#)
            == ResticProcess.progressKey(#"{"message_type":"status","seconds_elapsed":10,"seconds_remaining":4,"percent_done":0.5}"#))
    }

    @Test func aResticThatMakesProgressIsNeverStopped() throws {
        let (r, _) = try standIn("for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo \"[0:0$i] $i.00%  $i / 15 packs\"; sleep 0.2; done")
        let o = try r.run(["check"], stall: 1)
        #expect(o.status == 0)
    }

    @Test func theCutoffEndsWithTheMarkerItWaitsFor() throws {
        // restore --verify prints its summary when the files are in place, then reads them back without a word.
        let (r, _) = try standIn("echo '{\"message_type\":\"summary\",\"files_restored\":2}'\nsleep 3\nexit 0")
        let o = try r.run(["restore"], stall: 1, stallEndsAt: Restic.summaryMarker)
        #expect(o.status == 0)
        #expect(throws: Restic.Failure.self) { try r.run(["restore"], stall: 1) }
    }

    // MARK: - qnY_p: peeked documents are streamed to their file

    @Test func dumpWritesTheDocumentToItsFileNotToMemory() throws {
        let (r, base) = try standIn("head -c 3000000 /dev/zero")
        let file = base.appendingPathComponent("deed.pdf")
        let o = try r.run(["dump"], stdoutTo: file)
        #expect(o.stdout.isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? Int == 3_000_000)
        try r.dump("0123abcd", path: "/documents/deed.pdf", to: base.appendingPathComponent("again.pdf"))
        #expect((try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("again.pdf").path))[.size] as? Int == 3_000_000)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: base.path)).contains { $0.hasSuffix(".part") })
    }

    @Test func aDocumentWithTheLongestNameCanBePeeked() throws {
        let (r, base) = try standIn("echo invented")
        let name = String(repeating: "a", count: 251) + ".pdf"
        try r.dump("0123abcd", path: "/documents/" + name, to: base.appendingPathComponent(name))
        #expect(try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8) == "invented\n")
    }

    // MARK: - Sleep: the cutoff runs on a clock that stops while the Mac sleeps

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let jumpAfter: Int?
        init(jumpAfter: Int?) { self.jumpAfter = jumpAfter }
        /// Frozen at 0 (a Mac asleep throughout), or jumping an hour ahead at read `jumpAfter + 1`, which takes a
        /// moment of real time, as a Mac that sleeps while restic's output comes in, on a clock that counts the sleep.
        func now() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            guard let jumpAfter else { return 0 }
            if calls == jumpAfter + 1 { usleep(300_000) }
            return calls > jumpAfter ? 3600 : 0
        }
    }

    @Test func theCutoffIsMeasuredOnTheInjectedClock() throws {
        var (r, _) = try standIn("echo '[0:01] 10.00%  1 / 10 packs'\nsleep 2\nexit 0")
        let frozen = FakeClock(jumpAfter: nil)
        r.clock = { frozen.now() }
        #expect(try r.run(["check"], stall: 1).status == 0)
    }

    @Test func outputWaitingAfterASleepIsReadBeforeTheCutoff() throws {
        var (r, _) = try standIn("for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo \"[0:0$i] $i.00%  $i / 15 packs\"; sleep 0.1; done")
        let jumping = FakeClock(jumpAfter: 6)
        r.clock = { jumping.now() }
        #expect(try r.run(["check"], stall: 600).status == 0)
    }

    // MARK: - q5Hav: key files an interrupted run left behind

    @Test func keyFilesLeftByAnInterruptedRunAreRemovedByTheNextRun() throws {
        let (r, _) = try standIn("exit 0")
        try AtomicFile.makePrivateFolder(r.runDir)
        let stale = r.runDir.appendingPathComponent("stale-key")
        let fresh = r.runDir.appendingPathComponent("fresh-key")
        try Data("INVNT-KEYAA\n".utf8).write(to: stale)
        try Data("INVNT-KEYBB\n".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        try r.run(["snapshots"])
        let left = try FileManager.default.contentsOfDirectory(atPath: r.runDir.path)
        #expect(left == ["fresh-key"])
    }

    // MARK: - q5Ha2: verification restores a crash left behind

    @Test func verificationRestoresLeftBehindAreCleaned() throws {
        let e = try bb.env()
        let b = bb.backup(e)
        let verify = b.dir.appendingPathComponent("verify/0123456789abcdef", isDirectory: true)
        try FileManager.default.createDirectory(at: verify, withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: verify.appendingPathComponent("letter.pdf"))
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-2 * 86_400)], ofItemAtPath: verify.path)
        b.cleanPeeks(now: now)
        #expect(!FileManager.default.fileExists(atPath: verify.path))
    }

    // MARK: - qnY_e: a restic that cannot be read is never pinned as nothing

    @Test func setupRefusesAResticItCannotRead() throws {
        let base = try temp("unreadable")
        let binary = base.appendingPathComponent("restic")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        chmod(binary.path, 0o111)
        let b = Backup(support: base.appendingPathComponent("support"), key: "TEST-KEY-AAAAA-BBBBB", resticBinary: binary, uploadCheck: { _ in .uploaded })
        do {
            try b.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
            Issue.record("set up with a restic it cannot read")
        } catch let failure as Backup.Failure {
            #expect(failure.message.contains("cannot be read to check it"))
        }
        #expect(try b.settings().primary == nil)
    }

    // MARK: - q5HaT: a binder that is gone gets no skeleton

    @Test func aBinderThatIsGoneGetsNoBackupID() throws {
        let base = try temp("gone")
        let gone = base.appendingPathComponent("moved-away/Estate", isDirectory: true)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(gone) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("moved-away").path))
    }

    // MARK: - qmH56: the mirror must be in iCloud before anything leaves on it

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func offloadRefusesAMirrorThatIsNotInICloud() throws {
        let e = try bb.env()
        let b = try bb.configured(e, upload: .notInICloud)
        do {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
            Issue.record("offloaded onto a mirror that is not in iCloud")
        } catch let failure as Backup.Failure {
            #expect(failure.message.contains("not in iCloud"))
        }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.offloaded().isEmpty)
    }

    // MARK: - qnY_i: the offload record is in the mirror before the folder leaves

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func theOffloadRecordIsInTheMirrorBeforeTheFolderLeaves() throws {
        let e = try bb.env()
        let key = "TEST-KEY-AAAAA-BBBBB"
        let probe = Restic(binary: try #require(Restic.locate()), repository: e.primary, key: key, support: e.base.appendingPathComponent("probe"))
        let held = BugbotBackupTests.Switch(false)
        let probeFile = e.base.appendingPathComponent("state-at-removal.json")
        let trash = e.trash
        let b = Backup(support: e.support, key: key, removeFolder: { url in
            // What the mirror holds of Sprava's state as the folder goes: the offload record must be there.
            if let snap = try? probe.snapshots(tag: "sprava-state").last?.id {
                try? probe.dump(snap, path: "/backup/state.json", to: probeFile)
                let id = (try? Backup.storedBackupID(url)) ?? nil
                held.on = id.map { (try? String(contentsOf: probeFile, encoding: .utf8))?.contains("\"backupID\" : \"\($0)\"") == true } ?? false
            }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(UUID().uuidString))
        }, hubSpool: e.spool, uploadCheck: { _ in .uploaded })
        try b.setUp(primary: e.primary, iCloudKeychain: false)
        try b.setSecond(e.second)
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else { Issue.record("not done"); return }
        #expect(held.on)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func theFolderWaitsUntilICloudHasTheRecord() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(false)
        var b = try bb.configured(e, waiting: waiting)
        // iCloud has the binder's snapshot, then falls behind just as the record is kept.
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        guard case .waitingForICloud = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the folder left before iCloud had the record"); return
        }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        b.atStep = nil
        // A retry while iCloud uploads only waits: it adds no state snapshot for iCloud to upload in turn.
        let states = try b.engine(e.primary.path).snapshots(tag: "sprava-state").count
        guard case .waitingForICloud = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the folder left before iCloud had the record"); return
        }
        #expect(try b.engine(e.primary.path).snapshots(tag: "sprava-state").count == states)
        waiting.on = false
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else { Issue.record("not done"); return }
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
    }

    /// An offload waiting at `leaving` for iCloud to upload the state snapshot holding its record.
    func waitingToLeave(_ e: BugbotBackupTests.Env, _ waiting: BugbotBackupTests.Switch) throws -> (Backup, String) {
        var b = try bb.configured(e, waiting: waiting)
        b.atStep = { if $0 == "offload.leaving" { waiting.on = true } }
        guard case .waitingForICloud = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            throw Backup.Failure(message: "the offload did not wait to leave")
        }
        b.atStep = nil
        let id = try Backup.backupID(e.folder)
        #expect(try b.state().offloads[id]?.stage == "leaving")
        #expect(try b.state().offloads[id]?.stateSaved == true)
        return (b, id)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aMirrorReplacedWhileTheFolderWaitsToLeaveKeepsIt() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(false)
        let (b, id) = try waitingToLeave(e, waiting)
        try b.setUp(primary: e.base.appendingPathComponent("icloud/Sprava Backup 2"), iCloudKeychain: false)
        waiting.on = false
        // The scheduled run resumes the offload: the record never reached the new mirror, so nothing leaves.
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().offloads[id] == nil)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aSecondBackupReplacedWhileTheFolderWaitsToLeaveGetsTheCopy() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(false)
        let (b, id) = try waitingToLeave(e, waiting)
        let second = e.base.appendingPathComponent("external/Sprava Second 2")
        try b.setSecond(second)
        let states = try b.engine(e.primary.path).snapshots(tag: "sprava-state").count
        waiting.on = false
        guard case .done(let record) = try b.continueOffload(id, now: now) else { Issue.record("not done"); return }
        // The copy is made in the new second backup, and the record that names it is in the mirror again.
        #expect(record.secondRepository == second.standardizedFileURL.path)
        #expect(try b.engine(second.path).snapshots(tag: "binder:\(id)").map(\.id).contains(try #require(record.secondSnapshot)))
        #expect(try b.engine(e.primary.path).snapshots(tag: "sprava-state").count == states + 1)
        #expect(!FileManager.default.fileExists(atPath: e.folder.path))
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aBinderChangedWhileItWaitsToLeaveStartsOver() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(false)
        let (b, id) = try waitingToLeave(e, waiting)
        try bb.addLogEntry(e.folder, "invented entry while waiting")
        #expect(throws: Backup.Failure.self) { _ = try b.continueOffload(id, now: now) }
        #expect(try b.state().offloads[id] == nil)
        #expect(try b.offloaded().isEmpty)
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
    }

    // MARK: - qnY_X: the hub slice is withdrawn under the binder lock

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aSlicePublishedAgainDuringTheOffloadIsTakenOff() throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        let slice = e.spool.appendingPathComponent("inbox/\(Teka.read(e.folder).name).agenda.json")
        // A publish that lands after the first withdrawal puts the slice back.
        b.atStep = { step in
            if step == "offload.leaving" { try? Data(#"{"items":[]}"#.utf8).write(to: slice) }
        }
        guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else { Issue.record("not done"); return }
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    // MARK: - qnY_n, qnY_l: hidden files and unreadable cards are waiting work

    @Test func aHiddenFileInIntakeOrOutgoingIsWaitingWork() throws {
        for place in ["intake/.invoice.pdf", "outgoing/.draft.pdf", "intake/mail/.reply.eml"] {
            let e = try bb.env()
            let b = try bb.settingsOnly(e)
            let file = e.folder.appendingPathComponent(place)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("invented".utf8).write(to: file)
            do {
                _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
                Issue.record("\(place) did not stop the offload")
            } catch let failure as Backup.Failure {
                #expect(failure.message.contains("waiting in"), "\(place): \(failure.message)")
            }
        }
        #expect(Backup.leftOut(".DS_Store") && Backup.leftOut(".0a1b.tmp") && !Backup.leftOut(".invoice.pdf"))
    }

    @Test func aCardThatCannotBeReadStopsTheOffload() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        let cards = e.folder.appendingPathComponent(".sprava/proposals", isDirectory: true)
        try FileManager.default.createDirectory(at: cards, withIntermediateDirectories: true)
        try Data("{ not a card".utf8).write(to: cards.appendingPathComponent("0b6f1a52-6f0e-4c1e-9a55-3c2f8e1d7a10.json"))
        do {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
            Issue.record("an unreadable card did not stop the offload")
        } catch let failure as Backup.Failure {
            #expect(failure.message.contains("card"))
        }
    }

    // MARK: - qnY_2: no live binder in a synced folder

    static let iCloudDrive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents", isDirectory: true)

    @Test(.enabled(if: FileManager.default.fileExists(atPath: iCloudDrive.path))) func restoreRefusesAFolderASyncServiceUploads() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        var st = Backup.State()
        st.offloaded = [Backup.Offloaded(backupID: "0123456789abcdef0123456789abcdef", name: "estate-example", originalPath: e.folder.path,
                                         snapshot: "0123abcd", secondSnapshot: nil, secondRepository: nil, bytes: 1, at: "2026-10-06T10:00:00Z",
                                         summary: "", documents: [], openItemsConfirmed: 0)]
        try b.save(st)
        // The folder exists and holds things, so nothing is ever written there, with or without the check.
        do {
            _ = try b.restore("0123456789abcdef0123456789abcdef", to: Self.iCloudDrive, now: now)
            Issue.record("restored into a synced folder")
        } catch let failure as Backup.Failure {
            #expect(failure.message.contains("sync service"))
        }
    }

    // MARK: - qnY_t: a blocked binder is a failed backup, never a silent one

    @Test func aBinderWhoseWritesAreBlockedCountsAsAFailedBackup() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        try Data("{ not a catalog".utf8).write(to: e.folder.appendingPathComponent("catalog.json"))
        let teka = Teka.read(e.folder)
        #expect(teka.writesBlocked)
        let m = b.maintain(rows: [ShelfRow(folder: e.folder, source: .picked, archived: false, teka: teka)], deviceID: "dev", now: now)
        #expect(m.blockedBinders == [e.folder.standardizedFileURL.path])
        #expect(m.failed >= 1)
    }

    // MARK: - qnY_y: logs stay out of the state snapshot

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func theStateSnapshotLeavesTheRuntimesLogsOutAndKeepsCaptures() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let runtime = e.support.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        for name in ["jobs.log", "jobs.log.1", "lease-refusals.log", "lease-refusals.log.2", "settings.json"] {
            try Data("invented\n".utf8).write(to: runtime.appendingPathComponent(name))
        }
        // A capture's attachment may end in .log: it is the person's document, and stays in the backup.
        let captures = e.support.appendingPathComponent("Captures/invented-device", isDirectory: true)
        try FileManager.default.createDirectory(at: captures, withIntermediateDirectories: true)
        try Data("invented attachment\n".utf8).write(to: captures.appendingPathComponent("0b6f1a52-6f0e-4c1e-9a55-3c2f8e1d7a10.file-1.log"))
        try b.backUpState(now: now)
        let r = try b.engine(e.primary.path)
        let snap = try #require(try r.snapshots(tag: "sprava-state").last)
        let files = try r.files(snap.id)
        #expect(files.contains("runtime/settings.json"))
        #expect(files.contains("Captures/invented-device/0b6f1a52-6f0e-4c1e-9a55-3c2f8e1d7a10.file-1.log"))
        #expect(!files.contains { $0.hasPrefix("runtime/") && $0.contains(".log") })
    }

    // MARK: - q5HaY: a rewrite renames snapshots in its own repository only

    @Test func aRewriteRenamesOnlyTheSnapshotsOfItsRepository() {
        // A copy of a snapshot a rewrite made has the same id in both repositories.
        let (old, new) = (String(repeating: "a", count: 64), String(repeating: "b", count: 64))
        var st = Backup.State()
        st.offloaded = [Backup.Offloaded(backupID: "0123456789abcdef0123456789abcdef", name: "estate-example", originalPath: "/invented/Estate",
                                         snapshot: old, repository: "/invented/mirror", secondSnapshot: old, secondRepository: "/invented/second",
                                         bytes: 1, at: "2026-10-06T10:00:00Z", summary: "", documents: [], openItemsConfirmed: 0)]
        st.forgetting = [Backup.Forgetting(backupID: "0123456789abcdef0123456789abcdef", path: "documents/deed.pdf", at: "2026-10-06T10:00:00Z",
                                           requested: nil, scopes: [.init(repository: "/invented/mirror", snapshots: [old], done: false),
                                                                    .init(repository: "/invented/second", snapshots: [old], done: false)],
                                           request: "invented-deletion-1")]
        st.rename([old: new], in: "/invented/mirror")
        #expect(st.offloaded[0].snapshot == new)
        #expect(st.offloaded[0].secondSnapshot == old)
        #expect(st.forgetting[0].scopes.map(\.snapshots) == [[new], [old]])
    }

    // MARK: - q5Hao: a refused key change keeps the key that works

    @Test func aKeyChangeTheKeychainRefusesKeepsTheKeyThatWorks() throws {
        // A refused change throws, and nothing was deleted before it: `Items` has no delete to call.
        var calls: [String] = []
        let refusing = BackupKey.Items(update: { _, _ in calls.append("update"); return errSecInteractionNotAllowed },
                                       add: { _ in calls.append("add"); return errSecSuccess })
        #expect(throws: BackupKey.Failure.self) { try BackupKey.put("INVNT-NEWKY", account: "repository-key", synchronizable: false, items: refusing) }
        #expect(calls == ["update"])
        // An item already there is updated in place; one not there yet is added.
        calls = []
        let updating = BackupKey.Items(update: { _, _ in calls.append("update"); return errSecSuccess }, add: { _ in calls.append("add"); return errSecSuccess })
        try BackupKey.put("INVNT-NEWKY", account: "repository-key", synchronizable: false, items: updating)
        #expect(calls == ["update"])
        calls = []
        let adding = BackupKey.Items(update: { _, _ in calls.append("update"); return errSecItemNotFound }, add: { _ in calls.append("add"); return errSecSuccess })
        try BackupKey.put("INVNT-NEWKY", account: "repository-key", synchronizable: false, items: adding)
        #expect(calls == ["update", "add"])
    }

    // MARK: - Final review of 954ff7f

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aFailedSecondReadCheckRetriesTheSamePart() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        try b.check(readData: true, now: now)
        #expect(try b.state().readDataPart == 1)
        #expect(try b.state().secondReadDataPart == 1)

        let later = now.addingTimeInterval(31 * 86_400)
        let away = e.second.deletingLastPathComponent().appendingPathComponent("invented-away")
        try FileManager.default.moveItem(at: e.second, to: away)
        #expect(throws: (any Error).self) { try b.check(readData: true, now: later) }
        var st = try b.state()
        #expect(st.readDataPart == 2 && st.lastReadData == ISOTime.string(later))
        #expect(st.secondReadDataPart == 1 && st.lastSecondReadData == ISOTime.string(now))

        try FileManager.default.moveItem(at: away, to: e.second)
        let retried = later.addingTimeInterval(3600)
        #expect(b.maintain(rows: [], deviceID: "dev", now: retried).checked)
        st = try b.state()
        #expect(st.secondReadDataPart == 2 && st.lastSecondReadData == ISOTime.string(retried))
    }

    @Test func aRestoreKeepsTrackingStagingItCannotRemove() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        let id = "0123456789abcdef0123456789abcdef"
        let old = e.base.appendingPathComponent("old/Estate", isDirectory: true)
        let newer = e.base.appendingPathComponent("new/Estate", isDirectory: true)
        var st = Backup.State()
        st.offloaded = [Backup.Offloaded(backupID: id, name: "estate-example", originalPath: old.path, snapshot: "0123abcd",
                                         repository: e.primary.path, secondSnapshot: nil, secondRepository: nil, bytes: 1,
                                         at: ISOTime.string(now), summary: "", documents: [], openItemsConfirmed: 0)]
        st.restoring[id] = old.path
        try b.save(st)
        let staging = Backup.staging(for: old, id: id)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let document = staging.appendingPathComponent("deed.pdf")
        try Data("invented restored document".utf8).write(to: document)
        #expect(chflags(document.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(document.path, 0) }

        #expect(throws: Backup.Failure.self) { _ = try b.restore(id, to: newer, now: now) }
        #expect(try b.state().restoring[id] == old.path)
        #expect(FileManager.default.fileExists(atPath: document.path))
    }

    @Test func linkedWorkFoldersStopAnOffload() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        let outside = e.base.appendingPathComponent("invented-empty-outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let outgoing = e.folder.appendingPathComponent("outgoing", isDirectory: true)
        try? FileManager.default.removeItem(at: outgoing)
        try FileManager.default.createSymbolicLink(at: outgoing, withDestinationURL: outside)
        do {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
            Issue.record("a linked outgoing folder was accepted")
        } catch let failure as Backup.Failure {
            #expect(failure.message.contains("not a real folder"))
        }
        #expect(FileManager.default.fileExists(atPath: e.folder.path))
    }

    @Test func specialOrLinkedSettingsFilesAreRefusedWithoutBlocking() throws {
        let support = try temp("settings-entry")
        let b = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, uploadCheck: { _ in .notInICloud })
        try AtomicFile.makePrivateFolder(b.dir)
        #expect(mkfifo(b.settingsURL.path, 0o600) == 0)
        let started = Date()
        #expect(throws: Backup.Failure.self) { try b.settings() }
        #expect(Date().timeIntervalSince(started) < 2)
        unlink(b.settingsURL.path)
        let target = support.appendingPathComponent("invented-settings.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: b.settingsURL, withDestinationURL: target)
        #expect(throws: Backup.Failure.self) { try b.settings() }

        let blockedSupport = try temp("settings-parent-file")
        try Data("not a directory".utf8).write(to: blockedSupport.appendingPathComponent("backup"))
        let blocked = Backup(support: blockedSupport, key: nil, resticBinary: nil, uploadCheck: { _ in .notInICloud })
        #expect(throws: Backup.Failure.self) { try blocked.settings() }
    }

    @Test func aTerminalRequestGetsItsCompletionTime() throws {
        let support = try temp("request-time")
        let requests = BackupRequests(support: support)
        let finished = Date()
        let started = finished.addingTimeInterval(-2 * 86_400)
        let request = try requests.enqueue(.init(id: "invented-request", kind: "invented-unknown", at: ISOTime.string(started)))
        let b = Backup(support: support, key: nil, resticBinary: nil, uploadCheck: { _ in .notInICloud })
        try requests.run(request, backup: b, deviceID: "dev", now: started, finishedAt: finished)
        let saved = try #require(requests.all().first)
        #expect(saved.state == "failed" && saved.at == ISOTime.string(finished))
    }

    @Test func retentionForgetsEveryBinderThenPrunesOnce() throws {
        let base = try temp("retention")
        let log = base.appendingPathComponent("restic-arguments.log")
        let binary = base.appendingPathComponent("restic")
        let script = "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '\(log.path)'\nexit 0\n"
        try Data(script.utf8).write(to: binary)
        chmod(binary.path, 0o755)
        let b = Backup(support: base.appendingPathComponent("support"), key: "TEST-KEY-AAAAA-BBBBB", resticBinary: binary,
                       uploadCheck: { _ in .uploaded })
        var settings = Backup.Settings()
        settings.primary = base.appendingPathComponent("mirror").path
        try b.save(settings)
        var st = Backup.State()
        st.binders["0123456789abcdef0123456789abcdef"] = .init()
        st.binders["fedcba9876543210fedcba9876543210"] = .init()
        try b.save(st)

        try b.applyRetention(now: now)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 3)
        #expect(lines.filter { $0.hasPrefix("forget ") }.count == 2)
        #expect(lines.filter { $0.hasPrefix("forget ") }.allSatisfy { !$0.contains("--prune") })
        #expect(lines.filter { $0.hasPrefix("prune ") }.count == 1)
    }
}

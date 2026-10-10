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
        _ = try bb.configured(e)
        // Setup now rejects a non-iCloud primary itself. Model iCloud becoming unavailable after a valid setup to
        // retain this offload-specific regression.
        let b = bb.backup(e, upload: .notInICloud)
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

    // MARK: - Final review of 632487d

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aRewriteJournalIsInTheUploadedStateBeforeOriginalsAreForgotten() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(false)
        let b = try bb.configured(e, waiting: waiting)
        _ = try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        waiting.on = true
        #expect(try !b.forget(id, path: "correspondence/notary/letter.pdf", request: "invented-deletion-durable", now: now))

        let repository = try b.engine(e.primary.path)
        let stateSnapshot = try #require(try repository.snapshots(tag: "sprava-state").last?.id)
        let recoveredFile = e.base.appendingPathComponent("invented-recovered-state.json")
        try repository.dump(stateSnapshot, path: "/backup/state.json", to: recoveredFile)
        let recovered = try JSONDecoder().decode(Backup.State.self, from: Data(contentsOf: recoveredFile))
        #expect(recovered.rewrites.contains { $0.repository == e.primary.path && $0.before.count == 1 })
        let snapshots = try repository.snapshots(tag: "sprava-state").count
        #expect(try !b.forget(id, path: "correspondence/notary/letter.pdf", request: "invented-deletion-durable", now: now))
        #expect(try repository.snapshots(tag: "sprava-state").count == snapshots)
        waiting.on = false
        #expect(try b.forget(id, path: "correspondence/notary/letter.pdf", request: "invented-deletion-durable", now: now))
        #expect(try b.state().rewrites.isEmpty)
        // Recover the uploaded pre-rewrite state after the rewrite: even though its local phase said "waiting", it
        // follows restic's replacement link instead of retaining the now-missing original id.
        try AtomicFile.write(try Data(contentsOf: recoveredFile), to: b.stateURL)
        var recoveredState = try b.state()
        try b.reconcileRewrites(&recoveredState)
        #expect(recoveredState.rewrites.isEmpty)
        let replacement = try #require(recoveredState.binders[id]?.snapshot)
        #expect(try !repository.files(replacement).contains("correspondence/notary/letter.pdf"))
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aWaitingRewriteCheckpointsAgainAfterTheMirrorChanges() throws {
        let e = try bb.env()
        let waiting = BugbotBackupTests.Switch(false)
        let b = try bb.configured(e, waiting: waiting)
        _ = try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        waiting.on = true
        #expect(try !b.forget(id, path: "correspondence/notary/letter.pdf", request: "invented-deletion-new-mirror", now: now))

        let replacement = e.base.appendingPathComponent("icloud/Sprava Backup 2")
        try b.setUp(primary: replacement, iCloudKeychain: false)
        #expect(try b.engine(replacement.path).snapshots(tag: "sprava-state").isEmpty)
        #expect(try !b.forget(id, path: "correspondence/notary/letter.pdf", request: "invented-deletion-new-mirror", now: now))
        #expect(try b.engine(replacement.path).snapshots(tag: "sprava-state").count == 1)
        #expect(try b.state().rewrites.first?.stateRepository == replacement.standardizedFileURL.path)

        waiting.on = false
        #expect(try b.forget(id, path: "correspondence/notary/letter.pdf", request: "invented-deletion-new-mirror", now: now))
    }

    @Test func everyUnconfirmedRegularRepositoryFilePreventsUploaded() {
        let uploaded = Backup.UploadEntry(regular: true, ubiquitous: true, uploaded: true)
        let local = Backup.UploadEntry(regular: true, ubiquitous: false, uploaded: nil)
        let unknown = Backup.UploadEntry(regular: nil, ubiquitous: nil, uploaded: nil)
        let directory = Backup.UploadEntry(regular: false, ubiquitous: false, uploaded: nil)
        #expect(Backup.uploadStatus([uploaded, local, directory]) == .waiting(1))
        #expect(Backup.uploadStatus([uploaded, unknown]) == .waiting(1))
        #expect(Backup.uploadStatus([local]) == .notInICloud)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aChangedReoffloadUnpinsTheEarlierCopies() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let first) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("first offload did not finish"); return
        }
        let oldSecond = try #require(first.secondSnapshot)
        let restored = try b.restore(first.backupID, now: now)
        try Data("invented changed letter".utf8).write(to: restored.appendingPathComponent("correspondence/notary/letter.pdf"))
        guard case .done(let second) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true,
                                                     now: now.addingTimeInterval(3600)) else {
            Issue.record("second offload did not finish"); return
        }
        #expect(second.snapshot != first.snapshot)
        #expect(second.secondSnapshot != oldSecond)
        let primaryPins = try b.engine(e.primary.path).snapshots(tag: "offloaded").map(\.id)
        let secondPins = try b.engine(e.second.path).snapshots(tag: "offloaded").map(\.id)
        #expect(primaryPins.contains(second.snapshot) && !primaryPins.contains(first.snapshot))
        #expect(secondPins.contains(try #require(second.secondSnapshot)) && !secondPins.contains(oldSecond))
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func oldPinCleanupFailsBeforeTheRestoredBinderLeaves() throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        guard case .done(let first) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("first offload did not finish"); return
        }
        let restored = try b.restore(first.backupID, now: now)
        let replacement = e.base.appendingPathComponent("external/Sprava Second 2")
        try b.setSecond(replacement)
        try Data("invented changed letter".utf8).write(to: restored.appendingPathComponent("correspondence/notary/letter.pdf"))
        let away = e.base.appendingPathComponent("invented-old-second-away")
        b.atStep = { step in
            if step == "offload.leaving" { try? FileManager.default.moveItem(at: e.second, to: away) }
        }
        #expect(throws: (any Error).self) {
            _ = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now.addingTimeInterval(3600))
        }
        #expect(FileManager.default.fileExists(atPath: restored.path))
        #expect(try b.state().offloads[first.backupID]?.stage == "leaving")

        b.atStep = nil
        try FileManager.default.moveItem(at: away, to: e.second)
        guard case .done = try b.continueOffload(first.backupID, now: now.addingTimeInterval(3600)) else {
            Issue.record("the retried offload did not finish"); return
        }
        #expect(try b.state().offloads[first.backupID] == nil)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aSecondRepositoryAliasDoesNotUnpinTheCurrentCopy() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let first) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("first offload did not finish"); return
        }
        let oldSecond = try #require(first.secondSnapshot)
        let restored = try b.restore(first.backupID, now: now)
        let alias = e.base.appendingPathComponent("invented-second-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: e.second)
        try b.setSecond(alias)
        guard case .done(let second) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true,
                                                     now: now.addingTimeInterval(3600)) else {
            Issue.record("second offload did not finish"); return
        }
        #expect(second.snapshot == first.snapshot)
        #expect(second.secondSnapshot == oldSecond)
        #expect(try b.engine(alias.path).snapshots(tag: "offloaded").contains { $0.id == oldSecond })
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aQueuedDrillCanExerciseOnlyTheSecondRepository() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let requests = BackupRequests(support: e.support)
        let request = try requests.enqueue(.init(id: "invented-second-drill", kind: "drill", binder: e.folder.path,
                                                 repository: "second", at: ISOTime.string(now)))
        try requests.run(request, backup: b, deviceID: "dev", now: now, finishedAt: Date())
        #expect(try requests.all().first?.state == "done")
        let id = try Backup.backupID(e.folder)
        #expect(try b.engine(e.primary.path).snapshots(tag: "binder:\(id)").isEmpty)
        #expect(try b.engine(e.second.path).snapshots(tag: "binder:\(id)").count == 1)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aNonCatalogWriteDuringASnapshotLeavesTheBinderDue() throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        let landed = e.folder.appendingPathComponent("correspondence/notary/invented-during-snapshot.pdf")
        b.afterSnapshot = { try? Data("invented late document".utf8).write(to: landed) }
        _ = try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        #expect(try b.state().binders[id]?.at == nil)
    }

    @Test func specialOrLinkedBackupStateIsRefusedWithoutBlocking() throws {
        let e = try bb.env()
        let b = try bb.settingsOnly(e)
        #expect(mkfifo(b.stateURL.path, 0o600) == 0)
        let started = Date()
        #expect(throws: Backup.Failure.self) { try b.state() }
        #expect(Date().timeIntervalSince(started) < 2)
        unlink(b.stateURL.path)
        let target = e.base.appendingPathComponent("invented-state.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: b.stateURL, withDestinationURL: target)
        #expect(throws: Backup.Failure.self) { try b.state() }

        let blockedSupport = try temp("state-parent-file")
        try Data("not a directory".utf8).write(to: blockedSupport.appendingPathComponent("backup"))
        let blocked = Backup(support: blockedSupport, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil,
                             uploadCheck: { _ in .notInICloud })
        #expect(throws: Backup.Failure.self) { try blocked.state() }
    }

    @Test func aLargeStateWrittenByBackupCanBeReadBack() throws {
        let support = try temp("large-state")
        let b = Backup(support: support, key: nil, resticBinary: nil, uploadCheck: { _ in .notInICloud })
        let id = "0123456789abcdef0123456789abcdef"
        let large = String(repeating: "a", count: 17 * 1024 * 1024)
        var state = Backup.State()
        state.restored[id] = .init(snapshot: "0123abcd", repository: "/invented/mirror", secondSnapshot: nil,
                                   secondRepository: nil, manifest: ["documents/invented.pdf": large], bytes: 1, rootEntry: nil)
        try b.save(state)
        #expect(try b.state().restored[id]?.manifest["documents/invented.pdf"]?.count == large.count)
    }

    @Test func aConfiguredRepositoryWithoutItsKeyFailsMaintenance() throws {
        let support = try temp("missing-key")
        let b = Backup(support: support, key: nil, resticBinary: nil, uploadCheck: { _ in .notInICloud })
        var settings = Backup.Settings()
        settings.primary = support.appendingPathComponent("invented-mirror").path
        try b.save(settings)
        let maintenance = b.maintain(rows: [], deviceID: "dev", now: now)
        #expect(maintenance.failed == 1)
        #expect(maintenance.failedParts == ["backup_key"])
    }

    // MARK: - Final review of 831da3d

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func replacingTheSecondBackupMigratesEveryOffloadedBinderFirst() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let first) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the binder did not offload"); return
        }
        let away = e.base.appendingPathComponent("invented-retired-second")
        try FileManager.default.moveItem(at: e.second, to: away)
        let replacement = e.base.appendingPathComponent("external/Sprava Second Replacement")
        try b.setSecond(replacement)
        let migrated = try #require(try b.offloaded().first)
        #expect(try b.settings().second == replacement.standardizedFileURL.path)
        #expect(migrated.secondRepository == replacement.standardizedFileURL.path)
        #expect(try b.engine(replacement.path).snapshots(tag: "offloaded").contains { $0.id == migrated.secondSnapshot })

        // The new second copy is independently usable even with both the live binder and its original second disk gone.
        let primaryAway = e.base.appendingPathComponent("invented-primary-away")
        try FileManager.default.moveItem(at: e.primary, to: primaryAway)
        #expect(try b.restore(first.backupID, now: now).path == e.folder.standardizedFileURL.path)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aPartialSecondMigrationLeavesItsDestinationDiscoverable() throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the binder did not offload"); return
        }
        let replacement = e.base.appendingPathComponent("external/Sprava Interrupted Replacement")
        let away = e.base.appendingPathComponent("invented-interrupted-replacement")
        let once = BugbotBackupTests.Switch(true)
        b.atStep = { step in
            if step == "second.migration.copied", once.on {
                once.on = false
                try? FileManager.default.moveItem(at: replacement, to: away)
            }
        }
        #expect(throws: (any Error).self) { try b.setSecond(replacement) }
        #expect(try b.settings().second == e.second.standardizedFileURL.path)
        #expect(try b.state().binders[record.backupID]?.repositories.contains(replacement.standardizedFileURL.path) == true)
    }

    @Test func aFailedSynchronizedKeyChangeLeavesTheLocalKeyUntouched() {
        var values = [BackupKey.account: "INVNT-OLDKY-AAAAA", BackupKey.syncedAccount: "INVNT-OLDKY-AAAAA"]
        var calls: [String] = []
        var refuseSynchronizedPut = true
        var refuseSynchronizedDelete = false
        let keychain = BackupKey.Keychain(put: { key, account, _ in
            calls.append("put \(account)")
            if account == BackupKey.syncedAccount, refuseSynchronizedPut, key == "INVNT-NEWKY-BBBBB" {
                throw BackupKey.Failure(message: "invented refusal")
            }
            values[account] = key
        }, delete: { account, _ in
            calls.append("delete \(account)")
            if account == BackupKey.syncedAccount, refuseSynchronizedDelete { return errSecInteractionNotAllowed }
            return values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }, read: { account, _ in
            values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        })
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: true, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(calls == ["put \(BackupKey.rollbackAccount)", "put \(BackupKey.syncedAccount)", "put \(BackupKey.account)",
                          "put \(BackupKey.syncedAccount)", "delete \(BackupKey.rollbackAccount)"])
        calls = []
        refuseSynchronizedPut = false
        refuseSynchronizedDelete = true
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: false, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] == nil)
    }

    @Test func aFailedLocalKeyChangeRestoresTheCloudRecoveryKey() {
        var values = [BackupKey.account: "INVNT-OLDKY-AAAAA", BackupKey.syncedAccount: "INVNT-OLDKY-AAAAA"]
        var calls: [String] = []
        let keychain = BackupKey.Keychain(put: { key, account, _ in
            calls.append("put \(account)")
            if account == BackupKey.account, key == "INVNT-NEWKY-BBBBB" { throw BackupKey.Failure(message: "invented local refusal") }
            values[account] = key
        }, delete: { account, _ in
            calls.append("delete \(account)")
            return values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }, read: { account, _ in
            values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        })
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: true, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(calls == [
            "put \(BackupKey.rollbackAccount)", "put \(BackupKey.syncedAccount)", "put \(BackupKey.account)",
            "put \(BackupKey.account)", "put \(BackupKey.syncedAccount)", "delete \(BackupKey.rollbackAccount)",
        ])
        calls = []
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: false, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(calls == [
            "put \(BackupKey.rollbackAccount)", "delete \(BackupKey.syncedAccount)", "put \(BackupKey.account)",
            "put \(BackupKey.account)", "put \(BackupKey.syncedAccount)", "delete \(BackupKey.rollbackAccount)",
        ])
    }

    @Test func anInterruptedKeyChangeKeepsLoadingAndCanRecoverTheCommittedKey() throws {
        let previous = BackupKey.StoredKeys(local: nil, synchronized: "INVNT-OLDKY-AAAAA")
        let journal = try #require(String(data: JSONEncoder().encode(previous), encoding: .utf8))
        var values = [BackupKey.rollbackAccount: journal, BackupKey.syncedAccount: "INVNT-NEWKY-BBBBB"]
        let keychain = BackupKey.Keychain(put: { key, account, _ in values[account] = key }, delete: { account, _ in
            values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }, read: { account, _ in
            values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        })
        #expect(BackupKey.load(keychain: keychain) == "INVNT-OLDKY-AAAAA")
        try BackupKey.store("INVNT-NEXTK-CCCCC", inICloudKeychain: true, keychain: keychain)
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(BackupKey.load(keychain: keychain) == "INVNT-NEXTK-CCCCC")
    }

    @Test func aRestoreRenameIsFlushedBeforeItsStateCanAdvance() throws {
        let base = try temp("restore-flush")
        let destination = base.appendingPathComponent("Invented Binder", isDirectory: true)
        let id = "0123456789abcdef0123456789abcdef"
        let staging = Backup.staging(for: destination, id: id)
        try AtomicFile.makePrivateFolder(staging.appendingPathComponent(".sprava", isDirectory: true))
        try AtomicFile.write(Data((id + "\n").utf8), to: staging.appendingPathComponent(".sprava/backup-id"))
        let contents = Backup.State.RestoredContents(path: destination.path, baseline: nil, staging: staging.path)
        var b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .notInICloud })
        let refusing = BugbotBackupTests.Switch(true)
        let called = BugbotBackupTests.Switch(false)
        b.flushRestoreParent = { _ in
            called.on = true
            if refusing.on { throw Backup.Failure(message: "invented flush refusal") }
        }
        #expect(throws: Backup.Failure.self) { try b.install(contents, id: id) }
        #expect(FileManager.default.fileExists(atPath: destination.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        // A retry recognizes that the rename landed, but still cannot advance while the same barrier fails.
        called.on = false
        #expect(throws: Backup.Failure.self) { try b.install(contents, id: id) }
        #expect(called.on)
        refusing.on = false
        called.on = false
        try b.install(contents, id: id)
        #expect(called.on)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aSnapshotInterruptedBeforeVerificationIsResumedWithoutAnotherPin() throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        let away = e.base.appendingPathComponent("invented-mirror-away")
        b.atStep = { step in
            if step == "offload.snapshotted" { try? FileManager.default.moveItem(at: e.primary, to: away) }
        }
        #expect(throws: (any Error).self) {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        }
        let id = try Backup.backupID(e.folder)
        let interrupted = try #require(try b.state().offloads[id]?.snapshot)
        try FileManager.default.moveItem(at: away, to: e.primary)
        b.atStep = nil
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the interrupted offload did not finish"); return
        }
        #expect(record.snapshot == interrupted)
        #expect(try b.engine(e.primary.path).snapshots(tag: "offloaded").map(\.id) == [interrupted])
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aDefinitivelyMismatchingSnapshotIsUnpinnedAndRestartable() throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        let id = try Backup.backupID(e.folder)
        let before = try Backup.digest(Backup.manifest(e.folder))
        try Data("invented write during snapshot".utf8).write(to: e.folder.appendingPathComponent("correspondence/notary/letter.pdf"))
        let primary = try b.engine(e.primary.path)
        let result = try primary.backup(e.folder, tags: ["sprava", "binder:\(id)", "offloaded"], excludes: Backup.excludes,
                                        skipIfUnchanged: false)
        let snapshot = try #require(result.snapshot)
        var state = try b.state()
        var job = Backup.InProgress(path: e.folder.standardizedFileURL.path, stage: "snapshotted")
        job.snapshot = snapshot
        job.repository = e.primary.standardizedFileURL.path
        job.manifestSHA = before
        state.offloads[id] = job
        try b.save(state)

        let away = e.base.appendingPathComponent("invented-abandonment-away")
        b.atStep = { step in
            if step == "offload.abandoning" { try? FileManager.default.moveItem(at: e.primary, to: away) }
        }
        #expect(throws: (any Error).self) {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        }
        #expect(try b.state().offloads[id]?.stage == "abandoning")
        // A re-offload can retain the restored binder's earlier record until the new one is safely leaving. Recovery
        // must bypass the ordinary shared-id guard while abandonment cleans its interrupted pin.
        var interrupted = try b.state()
        interrupted.offloaded = [Backup.Offloaded(backupID: id, name: "estate-example", originalPath: job.path, snapshot: snapshot,
                                                   secondSnapshot: nil, secondRepository: nil, bytes: 1, at: ISOTime.string(now), summary: "",
                                                   documents: [], openItemsConfirmed: 0)]
        try b.save(interrupted)
        try FileManager.default.moveItem(at: away, to: e.primary)
        b.atStep = nil
        #expect(throws: Backup.Failure.self) {
            _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
        }
        #expect(try b.state().offloads[id] == nil)
        #expect(try !primary.snapshots(tag: "offloaded").contains { $0.id == snapshot })
        guard case .done(let replacement) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("the abandoned offload did not restart"); return
        }
        #expect(replacement.snapshot != snapshot)
    }

    @Test func everyResticCommandRechecksThePinnedExecutable() throws {
        let base = try temp("restic-pin")
        let binary = base.appendingPathComponent("restic")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        chmod(binary.path, 0o755)
        let digest = try #require(Restic.sha256(of: binary))
        let r = Restic(binary: binary, repository: base.appendingPathComponent("repo"), key: "TEST-KEY-AAAAA-BBBBB",
                       support: base.appendingPathComponent("support"), expectedSHA256: digest)
        #expect(try r.run(["version"]).status == 0)
        let marker = base.appendingPathComponent("invented-ran")
        try Data("#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n".utf8).write(to: binary)
        chmod(binary.path, 0o755)
        #expect(throws: Restic.Failure.self) { try r.run(["version"]) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aPrimaryOutsideICloudIsNeverSavedAsTheMirror() throws {
        let e = try bb.env()
        let b = Backup(support: e.support, key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .notInICloud })
        #expect(throws: Backup.Failure.self) { try b.setUp(primary: e.primary, iCloudKeychain: false) }
        #expect(try b.settings().primary == nil)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aRecordedBinderWhoseBackupIDWasRemovedStillForgets() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        _ = try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        try FileManager.default.removeItem(at: e.folder.appendingPathComponent(".sprava/backup-id"))
        try FileManager.default.removeItem(at: e.folder.appendingPathComponent("correspondence/notary/letter.pdf"))
        #expect(try b.forgetDocument(in: e.folder, path: "correspondence/notary/letter.pdf", request: "invented-missing-id", now: now))
        #expect(try Backup.storedBackupID(e.folder) == id)
        for snapshot in try b.engine(e.primary.path).snapshots(tag: "binder:\(id)") {
            #expect(try !b.engine(e.primary.path).files(snapshot.id).contains("correspondence/notary/letter.pdf"))
        }
    }

    @Test func aHeldRequestQueueLockStopsAtItsDeadline() throws {
        let support = try temp("request-lock")
        let requests = BackupRequests(support: support, lockTimeout: 0.05)
        try AtomicFile.makePrivateFolder(requests.lockURL.deletingLastPathComponent())
        let fd = open(requests.lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        #expect(fd >= 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        #expect(flock(fd, LOCK_EX) == 0)
        let started = Date()
        #expect(throws: Backup.Failure.self) {
            try requests.enqueue(.init(id: "invented-held-lock", kind: "backup_now", binder: "/Invented/Binder", at: ISOTime.string(now)))
        }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(!FileManager.default.fileExists(atPath: requests.url.path))
    }
}

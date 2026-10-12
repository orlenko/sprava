@testable import Backup
import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The backup commands and the runtime's backup job: status that never mistakes unreadable settings for "not set
/// up", requests only for this Mac's binders, and the job's request-then-maintenance pass with its outcome codes.
/// restic runs against repositories in temporary folders only; those tests are skipped without it. Invented binders
/// only.
@Suite(.serialized) struct BackupCommandTests: BinderCommandFixture {
    static let hasRestic = Restic.locate() != nil

    func adopted(_ c: Commands, device: String = "dev") throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .string(device))]), now: now)
        return folder
    }

    @Test func statusBeforeSetupAndWithSettingsThatCannotBeRead() throws {
        let c = commands()
        let status = try call(c, [("command", .str("backup_status"))])
        #expect(status["ok"] == .bool(true) && status["configured"] == .bool(false) && status["requests"] == .array([]))
        let settings = c.support.appendingPathComponent("backup/settings.json")
        try AtomicFile.makePrivateFolder(settings.deletingLastPathComponent())
        try Data("{broken".utf8).write(to: settings)
        #expect(try call(c, [("command", .str("backup_status"))])["ok"] == .bool(false))
        #expect(try String(contentsOf: settings, encoding: .utf8) == "{broken")
    }

    @Test func requestsAreQueuedOnlyForThisMacsBinders() throws {
        let c = commands()
        let mine = try adopted(c), another = try adopted(c, device: "another-mac")
        let first = try call(c, [("command", .str("backup_request")), ("kind", .str("backup_now")), ("binder", .string(mine.path))])
        let again = try call(c, [("command", .str("backup_request")), ("kind", .str("backup_now")), ("binder", .string(mine.path))])
        #expect(first["ok"] == .bool(true) && again["request"] == first["request"])
        let refused = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .string(another.path))])
        #expect(refused["ok"] == .bool(false) && refused["error"]?.stringValue?.contains("not managed by this Mac") == true)
        #expect(try call(c, [("command", .str("backup_request")), ("kind", .str("restore")), ("binder", .string(mine.path))])["ok"] == .bool(false))
        #expect(try call(c, [("command", .str("backup_request")), ("kind", .str("drill")), ("binder", .string(mine.path)),
                             ("repository", .str("elsewhere"))])["ok"] == .bool(false))
        let listed = try call(c, [("command", .str("backup_status"))])["requests"]?.arrayValue ?? []
        #expect(listed.count == 1 && listed.first?["kind"] == .str("backup_now"))
    }

    @Test func repositoryCommandsRefuseBindersAndTheirAncestorsBeforeInitialization() throws {
        let c = commands(), folder = try adopted(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        for path in [folder.path, folder.appendingPathComponent("repo").path, folder.deletingLastPathComponent().path] {
            let setup = try call(c, [("command", .str("backup_setup")), ("key", .str("INVENTED-KEY")), ("primary", .str(path))])
            let second = try call(c, [("command", .str("backup_second")), ("folder", .str(path))])
            #expect(setup["error"]?.stringValue?.contains("cannot contain a binder") == true)
            #expect(second["error"]?.stringValue?.contains("cannot contain a binder") == true)
        }
        let alias = c.support.appendingPathComponent("binder-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
        #expect(throws: Backup.Failure.self) {
            try Backup.refuseRepositoryOverlap(alias.appendingPathComponent("repo"), binders: [folder])
        }
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("repo/config").path))
    }

    @Test func queuedOffloadRequiresTheWorkThatWasActuallyReviewed() throws {
        let c = commands(), folder = try adopted(c)
        let digest = try Backup.offloadConfirmationDigest(in: folder)
        #expect(try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .str(folder.path)),
                            ("confirm_open_items", .bool(true))])["ok"] == .bool(false))
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .str(folder.path)),
                         ("confirm_open_items", .bool(true)), ("confirmation_digest", .str(digest))])
        var item = try #require(Teka.read(folder).items.first?.object)
        item.set("id", .str("invented-new-item")); item.set("title", .str("Invented new work"))
        try TekaStore(folder: folder).apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .object(item))]),
                                                  actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        let backup = Backup(support: c.support, key: "INVENTED-KEY", resticBinary: nil, uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true })
        var settings = Backup.Settings(); settings.primary = c.support.appendingPathComponent("mirror").path
        settings.second = c.support.appendingPathComponent("second").path
        try backup.save(settings)
        let queue = BackupRequests(support: c.support), request = try #require(try queue.next())
        try queue.run(request, backup: backup, deviceID: "dev", nameCollides: { _ in false }, now: now)
        let result = try #require(try queue.all().first)
        #expect(result.state == "needs_confirmation" && result.message?.contains("Invented new work") == true)
        #expect(result.confirmationDigest != digest)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    func context(_ c: Commands?, rows: [URL]) -> JobContext {
        JobContext(support: c?.support ?? FileManager.default.temporaryDirectory, commands: c,
                   rows: { Shelf.rows(registry: nil, picked: rows) }, commandQueue: nil, log: { _ in })
    }

    @Test func theJobSkipsWhenNotSetUpAndFailsOnUnreadableSettings() throws {
        let c = commands()
        let backup = Backup(support: c.support, key: nil, resticBinary: nil)
        #expect(BackupJob.run(context(nil, rows: []), backup: backup) { _, _, _ in } == .skipped)
        #expect(BackupJob.run(context(c, rows: []), backup: backup) { _, _, _ in } == .skipped)
        var configured = Backup.Settings()
        configured.primary = "/Invented/Mirror"
        configured.resticSHA256 = "invented"
        try backup.save(configured)
        #expect(BackupJob.run(context(c, rows: []), backup: backup) { _, _, _ in } == .error(code: "backup_key", culprit: nil))
        let settings = c.support.appendingPathComponent("backup/settings.json")
        try AtomicFile.makePrivateFolder(settings.deletingLastPathComponent())
        try Data("{broken".utf8).write(to: settings)
        #expect(BackupJob.run(context(c, rows: []), backup: backup) { _, _, _ in }
            == .error(code: "backup_settings_unreadable", culprit: "backup/settings.json"))
    }

    @Test(.enabled(if: hasRestic)) func theJobRunsARequestThenWhatIsDue() throws {
        let c = commands()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-backup-job-\(UUID().uuidString)")
        let backup = Backup(support: c.support, key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .uploaded })
        try backup.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
        let folder = try adopted(c)
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("backup_now")), ("binder", .string(folder.path))])
        var told: [String] = []
        #expect(BackupJob.run(context(c, rows: [folder]), backup: backup, now: now) { _, body, _ in told.append(body) } == .ok)
        #expect(told == ["Backup: backup now finished."])
        #expect(try BackupRequests(support: c.support).all().first?.state == "done")
        // A queue that cannot be read is reported, and the scheduled work still runs.
        try Data("[{".utf8).write(to: c.support.appendingPathComponent("backup/backup.sqlite"))
        let later = now.addingTimeInterval(7200)
        #expect(BackupJob.run(context(c, rows: [folder]), backup: backup, now: later) { _, _, _ in }
            == .error(code: "backup_requests_unreadable", culprit: nil))
        #expect(backup.status(checkUpload: false).binders.first?.at == ISOTime.string(later))
    }

    /// A value set on one thread and read on another.
    final class Locked<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// The upload walk stalls when iCloud does. Only the backup job starts it, off the command queue: while it hangs,
    /// the status and any other command still answer there, and the status then shows the result stored, with its
    /// time. The job has the mirror read again only when that result is old, and never shows another mirror's.
    @Test func aStalledUploadCheckLeavesTheCommandQueueFree() throws {
        let c = commands()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-upload-\(UUID().uuidString)")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let calls = Locked(0)
        let backup = Backup(support: c.support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, uploadCheck: { _ in
            calls.value += 1
            if calls.value == 1 { entered.signal(); release.wait() }
            return .waiting(2)
        })
        var settings = Backup.Settings()
        settings.primary = base.appendingPathComponent("Sprava Backup").path
        settings.resticSHA256 = "invented"
        try backup.save(settings)
        let context = context(c, rows: []), checks = BackupUploadCheck.of(c.support)
        _ = BackupJob.run(context, backup: backup, now: now) { _, _, _ in }
        #expect(entered.wait(timeout: .now() + 10) == .success)

        let queues = RequestQueues(watch: nil)
        let answers = Locked<[String: JSONValue]>([:])
        let answered = DispatchGroup()
        for command in ["backup_status", "ping"] {
            answered.enter()
            queues.submit(JSONWriter.compact(.obj([("command", .string(command))])), handle: { c.handle($0, now: now) }) { answer, _, _ in
                answers.value[command] = try? JSONParser.parse(answer).value
                answered.leave()
            }
        }
        #expect(answered.wait(timeout: .now() + 5) == .success)
        #expect(answers.value["ping"]?["ok"] == .bool(true))
        #expect(answers.value["backup_status"]?["upload"] == .str("not checked yet"))
        #expect(answers.value["backup_status"]?["upload_checked_at"] == .null)

        release.signal()
        #expect(checks.ended.wait(timeout: .now() + 10) == .success)
        let status = try call(c, [("command", .str("backup_status"))])
        #expect(status["upload"] == .str("waiting for iCloud: 2 file(s)"))
        let checked = try #require(ISOTime.date(status["upload_checked_at"]?.stringValue))
        #expect(checked >= now && checked < now.addingTimeInterval(60))

        // A fresh result stands; an old one is read again.
        _ = BackupJob.run(context, backup: backup, now: now.addingTimeInterval(60)) { _, _, _ in }
        #expect(checks.ended.wait(timeout: .now() + 10) == .success)
        #expect(calls.value == 1)
        _ = BackupJob.run(context, backup: backup, now: now.addingTimeInterval(60 + BackupUpload.recheck)) { _, _, _ in }
        #expect(checks.ended.wait(timeout: .now() + 10) == .success)
        #expect(calls.value == 2)
        // A result for another mirror is not shown.
        settings.primary = base.appendingPathComponent("Another Backup").path
        try backup.save(settings)
        #expect(try call(c, [("command", .str("backup_status"))])["upload"] == .str("not checked yet"))
    }

    /// The runtime runs the backup job one at a time, with no watchdog budget, so a job held by a stalled upload check
    /// would hold up every backup after it. The job returns while the check hangs, a request queued then runs at the
    /// next job, which starts no second check; once the stalled one is past its deadline, a job starts a fresh one,
    /// the status shows that one's result, and the stalled one's late result is dropped.
    @Test func aStalledUploadCheckNeverHoldsUpTheBackupJob() throws {
        let c = commands()
        let folder = try adopted(c)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-upload-\(UUID().uuidString)")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let calls = Locked(0)
        let backup = Backup(support: c.support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, uploadCheck: { _ in
            calls.value += 1
            if calls.value == 1 { entered.signal(); release.wait(); return .waiting(5) }
            return .uploaded
        })
        var settings = Backup.Settings()
        settings.primary = base.appendingPathComponent("Sprava Backup").path
        settings.resticSHA256 = "invented"
        try backup.save(settings)
        let context = context(c, rows: [folder]), at = now
        let first = DispatchGroup()
        DispatchQueue.global().async(group: first) { _ = BackupJob.run(context, backup: backup, now: at) { _, _, _ in } }
        #expect(first.wait(timeout: .now() + 10) == .success)
        #expect(entered.wait(timeout: .now() + 10) == .success)

        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("backup_now")), ("binder", .string(folder.path))])
        _ = BackupJob.run(context, backup: backup, now: now.addingTimeInterval(60)) { _, _, _ in }
        let request = try #require(try BackupRequests(support: c.support).all().first)
        #expect(BackupRequests.finished.contains(request.state))
        #expect(calls.value == 1)
        #expect(try call(c, [("command", .str("backup_status"))])["upload"] == .str("not checked yet"))

        _ = BackupJob.run(context, backup: backup, now: now.addingTimeInterval(BackupUploadCheck.deadline + 120)) { _, _, _ in }
        let patience = Date().addingTimeInterval(10)
        while try call(c, [("command", .str("backup_status"))])["upload"] != .str("uploaded"), Date() < patience {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(calls.value == 2)
        let status = try call(c, [("command", .str("backup_status"))])
        #expect(status["upload"] == .str("uploaded"))
        #expect(ISOTime.date(status["upload_checked_at"]?.stringValue).map { $0 >= now.addingTimeInterval(BackupUploadCheck.deadline) } == true)

        release.signal()
        #expect(BackupUploadCheck.of(c.support).ended.wait(timeout: .now() + 10) == .success)
        #expect(try call(c, [("command", .str("backup_status"))])["upload"] == .str("uploaded"))
    }

    /// The second-backup command waits for the backup job's turn with the state (`BackupStateLock`) before it reads
    /// anything.
    @Test func theSecondBackupCommandWaitsForTheBackupJob() throws {
        let c = commands()
        let holding = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let done = DispatchGroup()
        DispatchQueue.global().async(group: done) { BackupStateLock.of(c.support).job { holding.signal(); release.wait() } }
        #expect(holding.wait(timeout: .now() + 10) == .success)
        let answer = Locked<JSONValue?>(nil)
        DispatchQueue.global().async(group: done) {
            answer.value = try? call(c, [("command", .str("backup_second")), ("folder", .str("/Volumes/Invented Disk/Sprava Second"))])
        }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(answer.value == nil)
        release.signal()
        #expect(done.wait(timeout: .now() + 10) == .success)
        #expect(answer.value?["error"]?.stringValue == "set up backup first")
    }

    @Test(.enabled(if: hasRestic)) func aStalledOffloadUploadGateReleasesTheStateLockAndAllowsLaterRequests() throws {
        let c = commands(), folder = try adopted(c)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-offload-gate-\(UUID().uuidString)")
        let stall = Locked(false), removed = Locked(false)
        let release = DispatchSemaphore(value: 0)
        defer { stall.value = false; release.signal(); release.signal() }
        let backup = Backup(support: c.support, key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in
            if stall.value { release.wait() }
            return .uploaded
        }, secondLocationCheck: { _ in true }, removeFolder: { _ in removed.value = true },
                            hubSpool: base.appendingPathComponent("spool"))
        try backup.setUp(primary: base.appendingPathComponent("icloud/Mirror"), iCloudKeychain: false)
        try backup.setSecond(base.appendingPathComponent("external/Second"))
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")),
                         ("binder", .str(folder.path)), ("confirm_open_items", .bool(true)), ("confirmation_digest", .str(try Backup.offloadConfirmationDigest(in: folder)))])
        stall.value = true
        let ctx = context(c, rows: [])
        #expect(BackupJob.run(ctx, backup: backup, now: now, uploadCheckPatience: 0.02) { _, _, _ in } == .ok)
        #expect(!removed.value && FileManager.default.fileExists(atPath: folder.path))
        #expect(try BackupRequests(support: c.support).all().first?.state == "waiting_for_icloud")
        #expect(try BackupStateLock.of(c.support).command(patience: 0.1) { true })
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("backup_now")), ("binder", .str(folder.path))])
        #expect(BackupJob.run(ctx, backup: backup, now: now.addingTimeInterval(60), uploadCheckPatience: 0.02) { _, _, _ in } == .ok)
        let requests = try BackupRequests(support: c.support).all()
        #expect(requests.first { $0.kind == "backup_now" }?.state == "done")
        #expect(requests.first { $0.kind == "offload" }?.state == "waiting_for_icloud")
        #expect(!removed.value)
    }

    /// An offload that has made its copies, and a second backup chosen meanwhile: the change waits until the binder
    /// has left, so it never saves the state it read over the offload's record of the binder (which nothing would
    /// rebuild). It then finds an offloaded binder whose copies a new second backup would not hold, and is refused.
    @Test(.enabled(if: hasRestic)) func aSecondBackupChosenDuringAnOffloadKeepsTheOffloadsRecord() throws {
        let c = commands()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-backup-lock-\(UUID().uuidString)")
        let spool = base.appendingPathComponent("spool", isDirectory: true), trash = base.appendingPathComponent("trash", isDirectory: true)
        for sub in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: spool.appendingPathComponent(sub), withIntermediateDirectories: true)
            chmod(spool.appendingPathComponent(sub).path, 0o700)
        }
        chmod(spool.path, 0o700)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var backup = Backup(support: c.support, key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true },
                            removeFolder: { try FileManager.default.moveItem(at: $0, to: trash.appendingPathComponent(UUID().uuidString)) },
                            hubSpool: spool)
        try backup.setUp(primary: base.appendingPathComponent("icloud/Sprava Backup"), iCloudKeychain: false)
        let second = base.appendingPathComponent("external/Sprava Second").path
        try backup.setSecond(URL(fileURLWithPath: second, isDirectory: true))
        let folder = try adopted(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        let id = try Backup.backupID(folder)
        _ = try call(c, [("command", .str("backup_request")), ("kind", .str("offload")), ("binder", .string(folder.path)),
                         ("confirm_open_items", .bool(true)), ("confirmation_digest", .str(try Backup.offloadConfirmationDigest(in: folder)))])
        // The job's offload stops once its copies are made, the stage a change read in the lost update.
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        backup.atStep = { if $0 == "offload.copied" { reached.signal(); release.wait() } }
        let job = backup, done = DispatchGroup(), ctx = context(c, rows: []), at = now
        let outcome = Locked<JobOutcome?>(nil)
        DispatchQueue.global().async(group: done) { outcome.value = BackupJob.run(ctx, backup: job, now: at) { _, _, _ in } }
        #expect(reached.wait(timeout: .now() + 300) == .success)
        let started = Locked(false), changed = Locked<String?>(nil)
        DispatchQueue.global().async(group: done) {
            do {
                try BackupStateLock.of(c.support).command {
                    started.value = true
                    try job.setSecond(base.appendingPathComponent("elsewhere/Sprava Second"))
                }
                changed.value = "changed"
            } catch { changed.value = "\(error)" }
        }
        Thread.sleep(forTimeInterval: 0.5)
        #expect(!started.value)
        release.signal()
        #expect(done.wait(timeout: .now() + 600) == .success)
        #expect(outcome.value == .ok)
        #expect(try BackupRequests(support: c.support).all().first?.state == "done")
        #expect(changed.value?.contains("an offloaded binder's only copies are in the current backups") == true)
        #expect(try backup.offloaded().map(\.backupID) == [id])
        #expect(try backup.settings().second == second)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

import Backup
import BinderFormat
import BinderStore
import Brains
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the second review of the Services layer: a missing backup key, backup status off the command
/// queue, cards a command wrote kept for a later trust, links to state that is away, withdrawals that were not
/// saved, rejecting a changed card, the recovered summary marker and unreadable backup records. Invented data only.
@Suite(.serialized) struct LayerReview12Round2Tests {
    let ops = BugbotOpsTests()
    let fm = FileManager.default
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func tempDir() throws -> URL {
        let url = fm.temporaryDirectory.appendingPathComponent("sprava-layer12b-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func chmod(_ url: URL, _ mode: Int) throws {
        try fm.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    // MARK: - 1. Settings that name a mirror without the key are the job's error, never a skip

    @Test func aMissingBackupKeyFailsTheJob() throws {
        let support = try tempDir()
        #expect(BackupJob.readiness(Backup(support: support, key: nil)) == .skipped)
        let settings = support.appendingPathComponent("backup/settings.json")
        try fm.createDirectory(at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"primary":"/tmp/invented-mirror"}"#.utf8).write(to: settings)
        let missing = try #require(BackupJob.readiness(Backup(support: support, key: nil)))
        guard case .error(let code, _) = missing else { Issue.record("a missing key read as \(missing)"); return }
        #expect(code == "backup_key_unavailable")
        #expect(BackupJob.readiness(Backup(support: support, key: "invented-key")) == nil)
        try Data("{broken".utf8).write(to: settings)
        #expect(BackupJob.readiness(Backup(support: support, key: "invented-key"))
                == .error(code: "backup_settings_unreadable", culprit: "backup/settings.json"))

        // Recorded as a failure, so Health grades the job amber, though backup has no cadence.
        var record = JobRecord()
        record.finish(missing, at: now, durationMS: 1, threshold: 3)
        let spec = JobSpec(key: "backup", budget: .seconds(60), expectedCadence: nil, breakerThreshold: 3)
        #expect(HealthGrade.job(record.heartbeatJob(spec: spec, now: now, wedged: false), startedAt: now, lastWake: nil, now: now) == .amber)
    }

    // MARK: - 2. The backup status walks the mirror off the command queue

    @Test func aStalledBackupStatusLeavesTheCommandQueueFree() throws {
        let watch = WatchBox(budgets: RequestQueues.budgets)
        let queues = RequestQueues(watch: watch)
        let release = DispatchSemaphore(value: 0)
        let pingDone = DispatchSemaphore(value: 0)
        let statusDone = DispatchSemaphore(value: 0)
        queues.submit(#"{"command":"backup_status"}"#, handle: { _ in
            release.wait()
            return #"{"ok":true}"#
        }) { _, _, _ in statusDone.signal() }
        queues.submit(#"{"command":"approve"}"#, handle: { _ in #"{"ok":true}"# }) { _, _, _ in pingDone.signal() }
        #expect(pingDone.wait(timeout: .now() + 5) == .success)
        #expect(watch.runningFor("app_backup_request") != nil)
        release.signal()
        #expect(statusDone.wait(timeout: .now() + 5) == .success)
    }

    // MARK: - 3. A card a command wrote is kept for a later trust when the record cannot be written

    @Test func theStampCardOfAFailedRecordIsTrustedLater() throws {
        let c = ops.commands()
        let (folder, listed) = try ops.adoptCatalog(c, name: "estate-sample", """
        {"meta": {"schema_version": 2, "name": "estate-sample"}, "documents": [], "processing_log": [],
         "open_items": [{"id": "estate-sample-2026-001", "title": "Ask the bank for the statement", "status": "open", "priority": "normal"}]}
        """)
        let repair = try #require(listed.first { $0["title"] == .str("Fill in what this item is missing") })
        // Sprava's record of the cards can be read but not written.
        let runtime = c.support.appendingPathComponent("runtime", isDirectory: true)
        try chmod(runtime, 0o500)
        let r = try ops.approve(c, folder, repair, edits: .array([.obj([("index", .int(0)), ("due", .str("2026-12-01"))])]))
        try chmod(runtime, 0o700)
        #expect(r["ok"] == .bool(false))
        // The repair was applied and the stamp offered, but not trusted yet.
        let stampCard = { () throws -> JSONValue in
            try #require(try ops.cards(c, folder).first { $0["title"] == .str("Stamp this binder as binder v0") })
        }
        #expect(try stampCard()["verified"] == .bool(false))

        // A later pass (the runtime's settling, or the next command's trust) records it.
        try TrustBacklog.shared(support: c.support).retry(commands: c)
        let stamp = try stampCard()
        #expect(stamp["verified"] == .bool(true))
        #expect(try ops.approve(c, folder, stamp)["ok"] == .bool(true))
        #expect(Teka.read(folder).state == .ready, "\(Teka.read(folder).reasons)")
    }

    // MARK: - 4. A link to state that is away is unreadable, not absent

    @Test func aDanglingLinkIsNeverReadAsFreshState() throws {
        let dir = try tempDir()
        let breakers = dir.appendingPathComponent("breakers.json")
        let away = dir.appendingPathComponent("unmounted/breakers.json").path
        try fm.createSymbolicLink(atPath: breakers.path, withDestinationPath: away)
        let (records, aside) = JobRecords.loadAtStart(breakers, jobs: ["hub"], now: now)
        let kept = try #require(aside)
        #expect(records.jobs["hub"]?.breaker == "half_open")
        #expect(try fm.destinationOfSymbolicLink(atPath: kept.path) == away)

        let ids = dir.appendingPathComponent("binder-ids.json")
        #expect(try BinderIDs.load(ids).next == 1)   // absent: fresh
        try fm.createSymbolicLink(atPath: ids.path, withDestinationPath: dir.appendingPathComponent("unmounted/binder-ids.json").path)
        #expect(throws: BinderIDs.Unreadable.self) { try BinderIDs.load(ids) }
    }

    // MARK: - 5. A brain's card whose withdrawal was not saved is never approved

    @Test func aCardWhoseWithdrawalFailedCannotBeApproved() throws {
        let c = ops.commands()
        let (folder, _) = try ops.readyBinder(c)
        _ = try ops.call(c, [("command", .str("register_client")), ("client_id", .str("c1")), ("binders", .obj([(folder.path, .str("propose"))]))])
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("sprava/0.1")), (key: "model", value: .str("c1"))])
        let card = Proposal.make(title: "Noted", actor: brain, ops: [ops.body("add_log_entry", .obj([("entry", .obj([("action", .str("noted"))]))]))], now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)

        let proposals = folder.appendingPathComponent(".sprava/proposals", isDirectory: true)
        try chmod(proposals, 0o500)
        let r = try ops.call(c, [("command", .str("revoke_client")), ("client_id", .str("c1"))])
        try chmod(proposals, 0o700)
        #expect(r["withdrawn"] == .int(0) && r["not_withdrawn"] == .int(1))

        // Still waiting, but approval is refused, also after the brain is registered again under the same id.
        let listed = try #require(try ops.cards(c, folder).first { $0["id"] == .string(card.id) })
        #expect(listed["notes"]?.arrayValue?.first?.stringValue?.contains("disconnected") == true)
        #expect(try ops.approve(c, folder, listed)["ok"] == .bool(false))
        let again = JSONWriter.compact(.obj([("command", .str("register_client")), ("client_id", .str("c1")),
                                             ("binders", .obj([(folder.path, .str("propose"))]))]))
        #expect(try JSONParser.parse(c.handle(again, now: now.addingTimeInterval(60))).value["ok"] == .bool(true))
        let refused = try ops.approve(c, folder, listed)
        #expect(refused["ok"] == .bool(false))
        #expect(refused["error"]?.stringValue?.contains("disconnected") == true)
        #expect(ProposalStore.list(in: folder).first { $0.0.id == card.id }?.0.state == "proposed")
        // The person may still reject it.
        let rejected = try ops.call(c, [("command", .str("reject")), ("binder", .string(folder.path)), ("proposal", .string(card.id)),
                                        ("digest", listed["digest"]!)])
        #expect(rejected["ok"] == .bool(true), "\(rejected)")
    }

    // MARK: - 6. A trusted card changed by another program can be rejected as shown, never approved

    @Test func aChangedTrustedCardIsRejectedByItsCurrentDigest() throws {
        let c = ops.commands()
        let (folder, _) = try ops.readyBinder(c)
        let card = Proposal.make(title: "Drop", actor: ops.user, ops: [ops.body("drop", .obj([
            ("id", .str("item-0006")), ("closed_at", .str("2026-10-06T08:00:00Z")), ("source", .str("user"))]))], now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)
        let file = folder.appendingPathComponent(".sprava/proposals/\(card.id).json")
        try (try Data(contentsOf: file) + Data("\n".utf8)).write(to: file)

        let listed = try #require(try ops.cards(c, folder).first { $0["id"] == .string(card.id) })
        #expect(listed["verified"] == .bool(false))
        #expect(try ops.approve(c, folder, listed)["ok"] == .bool(false))
        let r = try ops.call(c, [("command", .str("reject")), ("binder", .string(folder.path)), ("proposal", .string(card.id)),
                                 ("digest", listed["digest"]!)])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(ProposalStore.list(in: folder).first { $0.0.id == card.id }?.0.state == "rejected")
    }

    // MARK: - 7. The recovered summary marker survives the start that recovered it

    @Test func theRecoveredSummaryMarkerIsSaved() throws {
        let dir = try tempDir()
        try Data("{\"day\": 7".utf8).write(to: RuntimeState.url(dir))
        let start = Date()
        let today = CalendarDate.today(now: start).description
        let (_, aside) = RuntimeState.loadAtStart(dir, now: start)
        #expect(aside != nil)
        #expect(RuntimeState.recordStart(dir))
        // The next start reads the saved marker, so today's summary is not sent again.
        let (state, again) = RuntimeState.loadAtStart(dir, now: start)
        #expect(again == nil)
        #expect(state.lastSummaryDate == today && state.startsToday == 1)
    }

    // MARK: - 8. Backup records that cannot be read are shown as such, not as never backed up

    @Test func unreadableBackupRecordsAreReported() throws {
        let c = ops.commands()
        let (folder, _) = try ops.readyBinder(c)
        try ShelfStore(supportDirectory: c.support).add(folder)
        let state = c.support.appendingPathComponent("backup/state.json")
        try fm.createDirectory(at: state.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{broken".utf8).write(to: state)
        let checks = HealthSnapshot.checks(support: c.support)
        #expect(checks.backupStateError != nil)
        let name = try #require(ShelfStore(supportDirectory: c.support).rows().first?.name)
        #expect(checks.backups == [HealthSnapshot.BackupLine(name: name, at: nil, error: HealthSnapshot.recordsUnreadable)])
        #expect(try String(contentsOf: state, encoding: .utf8) == "{broken")
    }
}

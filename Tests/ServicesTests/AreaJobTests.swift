import BinderFormat
import BinderStore
import Capture
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The runtime's area jobs as functions, without timers: capture, intake, the clerk, dashboards and the hub, each
/// given its context by the test. Temporary folders and invented binders only.
@Suite(.serialized) struct AreaJobTests: BinderCommandFixture {
    final class Lines: @unchecked Sendable { var all: [String] = [] }

    func context(_ c: Commands?, rows: [URL] = [], deviceIDError: String? = nil, lines: Lines = Lines()) -> JobContext {
        let support = c?.support ?? FileManager.default.temporaryDirectory.appendingPathComponent("sprava-area-\(UUID().uuidString)")
        return JobContext(support: support, commands: c, deviceIDError: deviceIDError,
                          rows: { Shelf.rows(registry: nil, picked: rows) }, commandQueue: nil, log: { lines.all.append($0) })
    }

    @Test func aJobThatWritesNeedsCommands() {
        #expect(CaptureJob.run(context(nil)) == .skipped)
        #expect(CaptureJob.run(context(nil, deviceIDError: "unreadable")) == .error(code: "device_id_unreadable", culprit: nil))
        #expect(IntakeJob.run(context(nil), reader: .inProcess) == .skipped)
        #expect(HubJob.run(context(nil)) == .skipped)
        #expect(DashboardJob.run(context(nil)) { _, _, _ in } == .skipped)
        #expect(ClerkJob.run(context(nil), model: .success(RecordingModel([]))).outcome == .skipped)
    }

    @Test func anUnreadableShelfFailsTheJob() {
        struct Unreadable: Error {}
        let c = commands()
        let broken = JobContext(support: c.support, commands: c, rows: { throw Unreadable() }, commandQueue: nil, log: { _ in })
        #expect(CaptureJob.run(broken) == SentinelJob.shelfUnreadable)
        #expect(IntakeJob.run(broken, reader: .inProcess) == SentinelJob.shelfUnreadable)
        #expect(HubJob.run(broken) == SentinelJob.shelfUnreadable)
        #expect(DashboardJob.run(broken) { _, _, _ in } == SentinelJob.shelfUnreadable)
    }

    @Test func theClerkWaitsForAModelItMayUse() {
        let c = commands()
        struct Unavailable: Error {}
        #expect(ClerkJob.run(context(c), model: .failure(Unavailable())).outcome == .skipped)
        // A model with a small context is gated off for the MVP unless the developer switch lifts it.
        #expect(ClerkJob.run(context(c), model: .success(RecordingModel([]))).outcome == .skipped)
        try? AtomicFile.makePrivateFolder(c.support)
        try? Data(#"{"clerk_any_model": true}"#.utf8).write(to: c.support.appendingPathComponent("developer.json"))
        let lifted = ClerkJob.run(context(c), model: .success(RecordingModel([])))
        #expect(lifted.outcome == .ok && lifted.read == 0)
    }

    @Test func theHubIsIdleWithoutASpoolAndPublishesAReadyBinder() throws {
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        let lines = Lines()
        #expect(HubJob.run(context(c, rows: [folder], lines: lines), root: spool.appendingPathComponent("missing")) == .idle)
        #expect(HubJob.run(context(c, rows: [folder], lines: lines), root: spool, now: now) == .ok)
        #expect(FileManager.default.fileExists(atPath: sliceURL(spool, "rental-elm-street").path))
        // The log names binders by opaque id only.
        #expect(lines.all.contains { $0.hasPrefix("hub binder=b1 published") })
        #expect(!lines.all.joined().contains("rental"))
    }

    @Test func anUnreadableDashboardRecordFailsTheJobNotTheOtherBinders() throws {
        let c = commands()
        let (a, _) = try readyBinder(c)
        let (b, _) = try readyBinder(c)
        let rows = Shelf.rows(registry: nil, picked: [a, b])
        let r = DashboardJob.run(rows, deviceID: c.deviceID) { folder in
            if folder.standardizedFileURL.path == a.standardizedFileURL.path {
                throw StateFile.Unreadable(path: folder.appendingPathComponent(".sprava/dashboard.json").path)
            }
            return .rendered(editedOutsideNotes: false)
        }
        #expect(r.rendered == 1 && r.failed == 1 && r.unreadable == 1)
        #expect(DashboardJob.outcome(r, settled: OutsideEdits.Settled()) == .error(code: "dashboard_state_unreadable", culprit: "1 binder(s)"))
        // A failed write (an AtomicFile flush) is a plain failure.
        let w = DashboardJob.run(rows, deviceID: c.deviceID) { _ in throw AtomicFile.Failure(step: "fsync", code: EIO) }
        #expect(DashboardJob.outcome(w, settled: OutsideEdits.Settled()) == .error(code: "dashboard_failed", culprit: "2 binder(s)"))
        // Cards left untrusted come before other failures.
        var untrusted = OutsideEdits.Settled()
        untrusted.untrusted = 1
        #expect(DashboardJob.outcome(w, settled: untrusted) == .error(code: "trust_failed", culprit: "1 card(s)"))
        // Binders another Mac owns are not this job's.
        #expect(DashboardJob.run(rows, deviceID: "another") { _ in .rendered(editedOutsideNotes: false) } == DashboardJob.Result())
    }

    @Test func captureSweepsAndIntakeScansWithNothingNew() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        #expect(CaptureJob.run(context(c, rows: [folder])) == .ok)
        #expect(IntakeJob.run(context(c, rows: [folder]), reader: .inProcess) == .ok)
    }

    @Test func unreadableFilingListPreservesTheHintedCardAndClerkQueue() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let inbox = c.inbox
        // This fixture must never follow a developer override into a real capture root.
        try #require(inbox.root.standardizedFileURL.path == c.support.appendingPathComponent("Captures").standardizedFileURL.path)
        let list = FilingList(support: c.support)
        try list.set(folder, .init(description: "Invented tasks", filing: true))
        let device = "00000000-0000-4000-8000-000000000001"
        try inbox.registerProducer(folder: device, app: "sprava")
        let producer = CaptureProducer(root: inbox.root, deviceID: device, support: c.support)
        let (event, digest) = try producer.writeNote("Remember the invented task", binderHint: Teka.read(folder).name,
                                                   startedAt: now, savedAt: now, locale: "en-CA")
        let eventID = try #require(event["id"]?.stringValue)
        try inbox.recordNotice(event: eventID, digest: digest, now: now)
        let rows = Shelf.rows(registry: nil, picked: [folder])
        _ = inbox.sweep(binders: rows, commands: c, now: now)
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.state == "proposed" })
        let cardURL = ProposalStore.dir(folder).appendingPathComponent(card.id + ".json")
        let files = [cardURL, c.support.appendingPathComponent("capture/state.json"),
                     c.support.appendingPathComponent("capture/journal.ndjson")]
        let before = try files.map { try Data(contentsOf: $0) }
        let settings = c.support.appendingPathComponent("binders.json")
        let original = try Data(contentsOf: settings)
        let answer = JSONValue.obj([("items", .array([.obj([
            ("quote", .str("Remember the invented task")), ("title", .str("Remember the invented task")),
            ("action", .str("other"))])]))])
        let model = ScriptedModel(extractions: [answer], binders: ["invented": Teka.read(folder).name], contextSize: 8192)
        for kind in ["malformed", "unreadable", "link", "fifo"] {
            try FileManager.default.removeItem(at: settings)
            switch kind {
            case "malformed": try Data("{ invalid".utf8).write(to: settings)
            case "unreadable":
                try original.write(to: settings)
                #expect(chmod(settings.path, 0o000) == 0)
            case "link":
                try FileManager.default.createSymbolicLink(atPath: settings.path, withDestinationPath: "missing.json")
            default: #expect(mkfifo(settings.path, 0o600) == 0)
            }
            let result = ClerkJob.run(context(c, rows: [folder]), model: .success(model))
            #expect(result.outcome == .error(code: "filing_list_unreadable", culprit: nil))
            #expect(result.read == 0)
            #expect(model.prompts.isEmpty)
            #expect(try files.map { try Data(contentsOf: $0) } == before)
            #expect(inbox.unfiled().isEmpty)
            if kind == "unreadable" { #expect(chmod(settings.path, 0o600) == 0) }
        }
        try FileManager.default.removeItem(at: settings)
        try original.write(to: settings)
        #expect(try Data(contentsOf: cardURL) == before[0])
        // Failed jobs never consumed poison attempts: restoring the settings lets the clerk keep the filing.
        let retry = ClerkJob.run(context(c, rows: [folder]), model: .success(model))
        #expect(retry.outcome == .ok && retry.read == 1)
        #expect(!model.prompts.isEmpty)
        #expect(inbox.unfiled().isEmpty)
        #expect(inbox.nextForClerk() == nil)
    }

    @Test func anUnlistableCaptureRootFailsTheJobAndRecovers() throws {
        let c = commands()
        let root = c.inbox.root
        try #require(root.standardizedFileURL.path == c.support.appendingPathComponent("Captures").standardizedFileURL.path)
        try AtomicFile.makePrivateFolder(root)
        #expect(chmod(root.path, 0o300) == 0)
        defer { chmod(root.path, 0o700) }
        #expect(CaptureJob.run(context(c), now: now) == .error(code: "capture_root_unlisted", culprit: nil))
        #expect(chmod(root.path, 0o700) == 0)
        #expect(CaptureJob.run(context(c), now: now) == .ok)
    }

    @Test func anUnwritableCaptureCursorFailsTheJobAndKeepsTheEventForRetry() throws {
        let c = commands()
        let inbox = c.inbox
        try #require(inbox.root.standardizedFileURL.path == c.support.appendingPathComponent("Captures").standardizedFileURL.path)
        let device = "00000000-0000-4000-8000-000000000001"
        try inbox.registerProducer(folder: device, app: "sprava")
        #expect(CaptureJob.run(context(c), now: now) == .ok)
        let file = c.support.appendingPathComponent("capture/state.json")
        let before = try Data(contentsOf: file)
        #expect(chflags(file.path, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(file.path, 0) }
        let producer = CaptureProducer(root: inbox.root, deviceID: device, support: c.support)
        let (event, digest) = try producer.writeNote("Keep this invented capture", startedAt: now, savedAt: now, locale: "en-CA")
        let id = try #require(event["id"]?.stringValue)
        try inbox.recordNotice(event: id, digest: digest, now: now)
        #expect(CaptureJob.run(context(c), now: now) == .error(code: "capture_state_unwritable", culprit: "state.json"))
        #expect(try Data(contentsOf: file) == before)
        #expect(inbox.unfiled().isEmpty)
        #expect(FileManager.default.fileExists(atPath: producer.folder.appendingPathComponent(id + ".json").path))
        #expect(chflags(file.path, 0) == 0)
        #expect(CaptureJob.run(context(c), now: now) == .ok)
        #expect(inbox.unfiled().count == 1)
        #expect(CaptureJob.run(context(c), now: now) == .ok)
        #expect(inbox.unfiled().count == 1)
    }
}

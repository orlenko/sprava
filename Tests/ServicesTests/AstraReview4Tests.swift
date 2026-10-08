import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import CryptoKit
import Darwin
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the fourth adversarial review of increment 1 (key and credential files in intake, hub
/// withdrawal while the outbox fails, private corrections that close items, correction cards that could not be
/// kept, unreadable op logs, exhausted id sequences) and the MCP socket's modes. Invented data only.
@Suite(.serialized) struct AstraReview4Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    // MARK: - 2. A drain that fails never holds back a withdrawal

    @Test func aBrokenOutboxDoesNotKeepAWithdrawnSliceOnTheHub() throws {
        let ops = BugbotOpsTests()
        let c = ops.commands()
        let (folder, spool) = try ops.readyBinder(c)
        let slice = ops.sliceURL(spool, "rental-elm-street")
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("not published"); return }
        let outbox = spool.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try Data("{ not json".utf8).write(to: outbox.appendingPathComponent("rental-elm-street.intake.json"))
        #expect(throws: (any Error).self) { try HubLane.drain(folder, root: spool, now: now) }

        // A redaction narrows the projection: published although the drain fails.
        _ = try ops.apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("redact", .bool(true)), ("kind", .str("payment"))]))]))
        let narrowed = HubLane.sync(folder, root: spool, now: now)
        #expect(narrowed.drainError != nil && narrowed.failed)
        guard case .published? = narrowed.published else { Issue.record("not published: \(String(describing: narrowed.publishError))"); return }
        let titles = try JSONParser.parse(try Data(contentsOf: slice)).value["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        #expect(titles.contains("[redacted]"))

        // Disclosure none withdraws the slice although the drain fails.
        try ops.outsideEdit(folder, ops.setMeta("disclosure", .str("none")))
        let withdrawn = HubLane.sync(folder, root: spool, now: now)
        #expect(withdrawn.drainError != nil)
        #expect(withdrawn.published == .removed)
        #expect(!FileManager.default.fileExists(atPath: slice.path))
    }

    // MARK: - 3. A private correction never closes an item in the clear

    @Test func aPrivateCorrectionRedactsBeforeItDrops() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-5555555555d1"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "R1", revision: "rev1", text: "Call the roofer\nOrder the blinds")
        try bFileAndApprove(s)
        let blinds = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Order the blinds") })
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "R1", revision: "rev2", text: "Call the roofer") {
            $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(pOpen(s).first { $0.title.contains("corrected") })
        let onBlinds = card.ops.filter { $0["args"]?["id"] == blinds["id"] }
        #expect(onBlinds.map { $0["op"]?.stringValue } == ["update_item", "drop"])
        #expect(onBlinds.first?["args"]?["set"]?["redact"] == .bool(true))
        #expect(onBlinds.first?["args"]?["set"]?["kind"] == .str("other"))

        // Approved before the separate redaction card, the closure still carries the redaction to the hub.
        _ = try TekaStore(folder: s.folder).approve(card, now: pNow)
        let closure = try #require(Teka.read(s.folder).catalog?["processing_log"]?.arrayValue?.last { $0["id"] == blinds["id"] })
        #expect(closure["final"]?["redact"] == .bool(true))
        let catalog = try #require(Teka.read(s.folder).catalog)
        var closed = closure["final"]?.objectValue ?? JSONObject()
        closed.set("id", blinds["id"]!)
        closed.set("title", closure["title"] ?? .str(""))
        let (slice, _) = try HubLane.project(catalog: catalog, folderName: s.folder.lastPathComponent, closedOnce: [closed],
                                             key: .init(size: .bits256), now: pNow)
        #expect(!JSONWriter.compact(slice).contains("blinds"))
    }

    func corrections(_ folder: URL, of event: String) -> [Proposal] {
        ProposalStore.list(in: folder).map(\.0).filter { CaptureInbox.isCorrection($0, of: event) && $0.state == "proposed" }
    }

    @Test func aRetryAfterAPartialFailureMakesNoSecondCard() async throws {
        let s = try pSetup()
        let b = BugbotCaptureTests()
        let (first, second, _, adapter) = try await b.splitNote(s, titles: ("Call the roofer", "Order the blinds"))
        let event = try pEvent(s, device: adapter, app: "adapter", ref: "S1", revision: "rev2",
                               text: "Call the roofer on Monday\nOrder the blinds on Friday")
        let rows = { [b.row(first), b.row(second)] }
        // The first binder's card is kept; the second binder's cannot be saved.
        chmod(ProposalStore.dir(second).path, 0o500)
        _ = s.inbox.sweep(binders: rows(), commands: s.commands, now: pNow)
        chmod(ProposalStore.dir(second).path, 0o700)
        #expect(try s.inbox.readState().ingested[event] == "ingested")
        #expect(corrections(first, of: event).count == 1)
        #expect(corrections(second, of: event).isEmpty)

        _ = s.inbox.sweep(binders: rows(), commands: s.commands, now: pNow)
        #expect(try s.inbox.readState().ingested[event] == "proposed")
        #expect(corrections(first, of: event).count == 1)
        #expect(corrections(second, of: event).count == 1)
    }
}

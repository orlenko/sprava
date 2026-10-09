import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the eleventh calibrated review of the capture layer: an `approx:` revision never outranks a
/// producer's own (capture-event-v0 §3.2), and a binder that was away during a correction gets that correction for
/// the items already filed in it when it is back. Invented data only.
@Suite(.serialized) struct CalibratedReview11Tests {
    let adapter = "11111111-2222-4333-8444-5555555555fb"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    func event(_ s: PSetup, ref: String, revision: String, text: String, wall: Int? = nil, private: Bool = false) throws -> String {
        try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: revision, text: text) { o in
            if let wall { o.set("hlc", .obj([("wall_ms", .int(wall)), ("counter", .int(1)), ("node", .string(adapter.replacingOccurrences(of: "-", with: "")))])) }
            if `private` { o.set("sensitivity", .str("private")) }
        }
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func waiting(_ s: PSetup) -> [Proposal] { pOpen(s) + s.inbox.unfiled() }

    func adds(_ p: Proposal) -> [String] {
        p.ops.compactMap { $0["op"] == .str("add_item") ? $0["args"]?["item"]?["title"]?.stringValue : nil }
    }

    func shows(_ s: PSetup, _ line: String) -> Bool {
        waiting(s).contains { adds($0).contains(line) || s.inbox.notFiled($0).contains(line) }
    }

    // MARK: - Approximate revisions

    @Test func aProducersEventWithALowerClockStillReplacesAnApproximation() throws {
        let s = try setup()
        _ = try event(s, ref: "A1", revision: "approx:0f1e", text: "Call the invented roofer", wall: 1_791_360_009_000)
        sweep(s)
        let real = try event(s, ref: "A1", revision: "rev1", text: "Call the invented roofer\nPay the invented levy", wall: 1_791_360_001_000)
        sweep(s)
        #expect(try s.inbox.readState().ingested[real] != "stale_revision")
        #expect(shows(s, "Pay the invented levy"), "the producer's words are carded")
    }

    @Test func anApproximationArrivingLaterNeverReplacesTheProducersEvent() throws {
        let s = try setup()
        let real = try event(s, ref: "A2", revision: "rev1", text: "Call the invented roofer\nPay the invented levy", wall: 1_791_360_001_000)
        sweep(s)
        let approx = try event(s, ref: "A2", revision: "approx:0f1e", text: "Call the invented roofer", wall: 1_791_360_009_000, private: true)
        sweep(s)
        #expect(try s.inbox.readState().ingested[approx] == "stale_revision")
        #expect(shows(s, "Pay the invented levy"), "the producer's card still waits")
        #expect(!waiting(s).contains { $0.raw["provenance"]?["events"] == .array([.string(approx)]) })
        // A raise of privacy still comes from every revision.
        #expect(waiting(s).first { $0.raw["provenance"]?["events"] == .array([.string(real)]) }?.raw["provenance"]?["private"] == .bool(true))
    }

    // MARK: - A binder back after a correction

    func away(_ s: PSetup) -> URL { s.folder.deletingLastPathComponent().appendingPathComponent(s.folder.lastPathComponent + ".away") }

    /// A note filed and approved in the binder, item by item.
    func approved(_ s: PSetup, ref: String, text: String) throws {
        let id = try event(s, ref: ref, revision: "rev1", text: text)
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { $0.raw["provenance"]?["events"] == .array([.string(id)]) }).id, into: s.folder, commands: s.commands)
        let card = try #require(pOpen(s).first { $0.raw["provenance"]?["events"] == .array([.string(id)]) })
        _ = try TekaStore(folder: s.folder).approve(try #require(s.inbox.cardForApproval(card.id, in: s.folder, commands: s.commands, now: pNow)), now: pNow)
    }

    @Test func aChangedLineIsCorrectedInTheBinderWhenItIsBackAndNotAddedAgain() throws {
        let s = try setup()
        try approved(s, ref: "B1", text: "Call the invented roofer")
        try FileManager.default.moveItem(at: s.folder, to: away(s))
        _ = try event(s, ref: "B1", revision: "rev2", text: "Call the invented roofer Monday\nPay the invented levy")
        sweep(s)
        #expect(shows(s, "Call the invented roofer Monday"), "while the binder is away, the revision waits whole")
        try FileManager.default.moveItem(at: away(s), to: s.folder)
        sweep(s)
        let item = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Call the invented roofer") })
        #expect(pOpen(s).contains { p in p.ops.contains { $0["args"]?["id"] == item["id"] && $0["args"]?["set"]?["title"] == .str("Call the invented roofer Monday") } })
        #expect(!waiting(s).contains { adds($0).contains("Call the invented roofer Monday") }, "the line is not added beside its item")
        #expect(shows(s, "Pay the invented levy"), "the new line still waits")
        #expect(!s.inbox.hasDeferredWork(in: s.folder))
        // A second sweep makes nothing more.
        let count = waiting(s).count
        sweep(s)
        #expect(waiting(s).count == count)
    }

    @Test func aRemovedLineIsOfferedForRemovalWhenTheBinderIsBack() throws {
        let s = try setup()
        try approved(s, ref: "B2", text: "Call the invented roofer\nPay the invented levy")
        try FileManager.default.moveItem(at: s.folder, to: away(s))
        _ = try event(s, ref: "B2", revision: "rev2", text: "Call the invented roofer")
        sweep(s)
        try FileManager.default.moveItem(at: away(s), to: s.folder)
        sweep(s)
        let levy = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Pay the invented levy") })
        #expect(pOpen(s).contains { p in p.ops.contains { $0["op"] == .str("drop") && $0["args"]?["id"] == levy["id"] } })
        #expect(!waiting(s).contains { adds($0).contains("Call the invented roofer") }, "the kept line is not added again")
    }
}

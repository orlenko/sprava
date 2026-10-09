import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the tenth calibrated review of the capture layer: the withdrawal gate copies only what Sprava
/// wrote, and a carried change keeps what its card assumed about the item it changes. Invented data only.
@Suite(.serialized) struct CalibratedReview10Tests {
    let review9 = CalibratedReview9Tests()
    let corrected = "Call the invented roofer about the gutter on Monday\nPaid the invented notary for the inventory"

    func carryCards(_ folder: URL) -> [Proposal] {
        review9.open(folder).filter { $0.raw["provenance"]?["carried_from"] != nil }
    }

    @Test func aCardChangedOutsideSpravaIsNeverCarriedIntoATrustedOne() throws {
        let (s, b) = try review9.setup()
        let (_, change) = try review9.readAndSplit(s, b: b, ref: "T1", second: ("complete", [
            ("id", .str("garden-example-2026-007")), ("closed_at", .str("2026-10-06T13:00:00Z")), ("source", .str("capture"))]))
        // Another program points the waiting completion at another item, keeping its span.
        let file = ProposalStore.dir(b).appendingPathComponent("\(change.id).json")
        let text = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "garden-example-2026-007", with: "garden-example-2026-011")
        try Data(text.utf8).write(to: file)
        let revision = try review9.event(s, ref: "T1", revision: "rev2", text: corrected)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(carryCards(b).isEmpty, "nothing of the changed card becomes a card Sprava trusts")
        #expect(!review9.open(b).contains { p in s.commands.isTrusted(p.id, in: b) && p.ops.contains { $0["args"]?["id"] == .str("garden-example-2026-011") } })
        #expect(review9.open(b).contains { $0.id == change.id }, "it stays, and the correction stays owed")
        #expect(try s.inbox.readState().ingested[revision] == "ingested")
    }

    @Test func aCarriedChangeStillStopsForALookWhenItsItemChangedSince() throws {
        let (s, b) = try review9.setup()
        let (_, change) = try review9.readAndSplit(s, b: b, ref: "T2", second: ("update_item", [
            ("id", .str("garden-example-2026-007")), ("set", .obj([("due", .str("2026-10-20"))]))]))
        // The person changes the same item through another card before the note is corrected.
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))])
        let other = Proposal.make(title: "Move the inventory", actor: actor, ops: [JSONObject([(key: "op", value: .str("update_item")),
            (key: "args", value: .obj([("id", .str("garden-example-2026-007")), ("set", .obj([("due", .str("2026-10-25"))]))]))])],
            provenance: JSONObject(), now: pNow)
        try ProposalStore.save(other, in: b)
        try s.commands.trustProposals([other.id], in: b)
        _ = try TekaStore(folder: b).approve(other, now: pNow)
        _ = try review9.event(s, ref: "T2", revision: "rev2", text: corrected)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(!review9.open(b).contains { $0.id == change.id })
        let carried = try #require(carryCards(b).first { $0.ops.contains { $0["args"]?["id"] == .str("garden-example-2026-007") } })
        #expect(!carried.changedSince(catalog: Teka.read(b).catalog).isEmpty)
        #expect(throws: (any Error).self) { _ = try TekaStore(folder: b).approve(carried, now: pNow) }
        let item = try #require(Teka.read(b).items.compactMap(\.object).first { $0["id"] == .str("garden-example-2026-007") })
        #expect(item["due"] == .str("2026-10-25"), "the change approved in between stands")
    }
}

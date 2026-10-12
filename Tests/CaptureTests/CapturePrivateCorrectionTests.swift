import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import CryptoKit
import Foundation
import Hub
import SpravaKit
import SpravaTestSupport
import Testing

/// A private capture that changes what was filed redacts every item it writes to, so neither the change card nor
/// the closure it carries ever puts the note's words on the hub. Invented data only.
@Suite(.serialized) struct CapturePrivateCorrectionTests {
    /// The binder's agenda slice items, as the hub would publish them.
    func hubItems(_ folder: URL, closedOnce: [JSONObject] = []) throws -> [JSONValue] {
        let catalog = try #require(Teka.read(folder).catalog)
        let (slice, _) = try HubLane.project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: closedOnce,
                                             key: SymmetricKey(size: .bits256), now: pNow)
        return slice["items"]?.arrayValue ?? []
    }

    @Test func aPrivateCorrectionCardIsRedacted() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-5555555555b1"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "Q1", revision: "rev1", text: "Call the roofer\nOrder the blinds")
        try bFileAndApprove(s)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "Q1", revision: "rev2",
                       text: "Call the roofer about the invented leak\nOrder the blinds\nBook the chimney sweep") {
            $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let card = try #require(pOpen(s).first { $0.title.contains("corrected") })
        #expect(card.raw["provenance"]?["private"] == .bool(true))
        let updates = card.ops.filter { $0["op"] == .str("update_item") }
        let adds = card.ops.filter { $0["op"] == .str("add_item") }
        // The changed line, and the unchanged one, which the private note now covers too; one new line.
        #expect(updates.count == 2 && adds.count == 1)
        #expect(updates.compactMap { $0["args"]?["set"]?["title"]?.stringValue } == ["Call the roofer about the invented leak"])
        for u in updates {
            #expect(u["args"]?["set"]?["redact"] == .bool(true))
            #expect(u["args"]?["set"]?["kind"] == .str("other"))
        }
        #expect(adds.first?["args"]?["item"]?["redact"] == .bool(true))
        #expect(adds.first?["args"]?["item"]?["kind"] == .str("other"))
        // Approving the correction card alone publishes none of the note's words.
        _ = try TekaStore(folder: s.folder).approve(card, now: pNow)
        let titles = try hubItems(s.folder).compactMap { $0["title"]?.stringValue }
        #expect(!titles.contains { $0.contains("roofer") || $0.contains("blinds") || $0.contains("chimney") })
    }

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
        var closed = closure["final"]?.objectValue ?? JSONObject()
        closed.set("id", blinds["id"]!)
        closed.set("title", closure["title"] ?? .str(""))
        #expect(!JSONWriter.compact(.array(try hubItems(s.folder, closedOnce: [closed]))).contains("blinds"))
    }

    @Test func aPrivateUpdateRedactsTheItem() async throws {
        let s = try pSetup()
        try bAddItem(s, id: "estate-example-2026-020", title: "Collect the garden photos")
        let ev = pEventObj("Collect the garden photos for the family by Friday.") { $0.set("sensitivity", .str("private")) }
        let model = RecordingModel([.obj([("items", .array([item("Collect the garden photos", "Collect the garden photos", "other", when: "by Friday")]))])])
        model.dup = ("estate-example-2026-020", "update")
        let interp = await Clerk(model: model).read(ev, filing: [bFiling(s)], hint: "estate-example", now: pNow)
        let cards = Clerk.proposals(interp, event: ev, today: CalendarDate(year: 2026, month: 10, day: 6)!, client: "t", now: pNow)
        let op = try #require(cards.first?.1.ops.first)
        #expect(op["op"] == .str("update_item"))
        #expect(op["args"]?["set"]?["due"] == .str("2026-10-09"))
        #expect(op["args"]?["set"]?["redact"] == .bool(true))
        #expect(op["args"]?["set"]?["kind"] == .str("other"))
        try ProposalStore.save(cards[0].1, in: s.folder)
        _ = try TekaStore(folder: s.folder).approve(cards[0].1, now: pNow)
        let titles = try hubItems(s.folder).compactMap { $0["title"]?.stringValue }
        #expect(!titles.contains("Collect the garden photos"))
        #expect(titles.filter { $0 == "[redacted]" }.count == 2)   // the fixture's own redacted item, and this one
    }
}

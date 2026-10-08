import CryptoKit
import Darwin
import Foundation
import Testing
@testable import SpravaCore

// Regression tests for the review of the capture and clerk modules (increment 1). Invented data only.

/// The binder's agenda slice items, as the hub would publish them.
func bSlice(_ folder: URL) throws -> [JSONValue] {
    let catalog = try #require(Teka.read(folder).catalog)
    let (slice, _) = try HubLane.project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: [],
                                         key: SymmetricKey(size: .bits256), now: pNow)
    return slice["items"]?.arrayValue ?? []
}

/// A filing binder for the test binder, read from its catalog.
func bFiling(_ s: PSetup, description: String = "Estate of an invented relative") -> FilingBinder {
    let teka = Teka.read(s.folder)
    return FilingBinder(name: teka.name, description: description, folder: s.folder,
                        words: FilingBinder.index(catalog: teka.catalog, description: description),
                        openItems: FilingBinder.candidates(catalog: teka.catalog))
}

/// Adds a public open item by hand, as the person would.
func bAddItem(_ s: PSetup, id: String, title: String, extra: [(String, JSONValue)] = [("no_deadline", .bool(true))]) throws {
    let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))])
    _ = try TekaStore(folder: s.folder).apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([
        ("id", .string(id)), ("title", .string(title)), ("status", .str("open")), ("priority", .str("normal"))] + extra))]), actor: actor)], now: pNow)
}

/// Sweeps, files the one unfiled card into the binder and approves it.
func bFileAndApprove(_ s: PSetup) throws {
    _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
    try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
    _ = try TekaStore(folder: s.folder).approve(try #require(pOpen(s).first), now: pNow)
}

@Suite(.serialized) struct BugbotCaptureTests {

    // MARK: - Privacy

    // p8-QS: a private correction's change card redacts what it writes.
    @Test func p8QS_aPrivateCorrectionCardIsRedacted() throws {
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
        #expect(updates.count == 1 && adds.count == 1)
        for u in updates {
            #expect(u["args"]?["set"]?["redact"] == .bool(true))
            #expect(u["args"]?["set"]?["kind"] == .str("other"))
        }
        #expect(adds.first?["args"]?["item"]?["redact"] == .bool(true))
        #expect(adds.first?["args"]?["item"]?["kind"] == .str("other"))
        // Approving the correction card alone publishes none of the private words.
        _ = try TekaStore(folder: s.folder).approve(card, now: pNow)
        let titles = try bSlice(s.folder).compactMap { $0["title"]?.stringValue }
        #expect(!titles.contains { $0.contains("leak") || $0.contains("chimney") })
    }

    // qcRsW: a private capture that updates a public item redacts it.
    @Test func qcRsW_aPrivateUpdateRedactsTheItem() async throws {
        let s = try pSetup()
        try bAddItem(s, id: "estate-example-2026-020", title: "Collect the garden photos")
        let text = "Collect the garden photos for the family by Friday."
        let ev = pEventObj(text) { $0.set("sensitivity", .str("private")) }
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
        let titles = try bSlice(s.folder).compactMap { $0["title"]?.stringValue }
        #expect(!titles.contains("Collect the garden photos"))
        #expect(titles.filter { $0 == "[redacted]" }.count == 2)   // the fixture's own redacted item, and this one
    }
}

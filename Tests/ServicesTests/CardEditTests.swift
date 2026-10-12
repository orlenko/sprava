import BinderFormat
import BinderStore
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct CardEditTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    @Test func thePersonEditsACardBeforeApproving() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-edit-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = c.handle(JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))])), now: now, today: today)
        func add(_ n: Int, _ title: String) -> JSONObject {
            JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .obj([
                ("id", .string("$new:\(n)")), ("title", .string(title)), ("status", .str("open")), ("priority", .str("normal")), ("no_deadline", .bool(true))]))]))])
        }
        let card = Proposal.make(title: "Add 2 items", actor: JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))]),
                                 ops: [add(1, "Pay plumber"), add(2, "Milk")], now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)
        let listed = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("proposals")), ("binder", .string(folder.path))])), now: now, today: today)).value
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        #expect(shown["editable"]?.arrayValue?.count == 2)
        let bad = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("approve")), ("binder", .string(folder.path)),
            ("proposal", .string(card.id)), ("digest", shown["digest"]!), ("edits", .array([.obj([("index", .int(0)), ("due", .str("Friday"))])]))])),
            now: now, today: today)).value
        #expect(bad["ok"] == .bool(false))
        let r = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("approve")), ("binder", .string(folder.path)),
            ("proposal", .string(card.id)), ("digest", shown["digest"]!), ("edits", .array([
                .obj([("index", .int(0)), ("title", .str("Pay the plumber")), ("due", .str("2026-10-12")), ("priority", .str("high"))]),
                .obj([("index", .int(1)), ("skip", .bool(true))]),
            ]))])), now: now, today: today)).value
        #expect(r["ok"] == .bool(true), "\(r)")
        let added = try #require(Teka.read(folder).items.last?.object)
        #expect(added["title"] == .str("Pay the plumber") && added["due"] == .str("2026-10-12") && added["priority"] == .str("high"))
        #expect(added["no_deadline"] == nil)
        #expect(!Teka.read(folder).items.contains { $0.title == "Milk" })
        #expect(ProposalStore.list(in: folder).first { $0.0.id == card.id }?.0.raw["edited"] == .bool(true))
    }
}


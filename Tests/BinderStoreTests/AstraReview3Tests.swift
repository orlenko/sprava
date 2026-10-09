@testable import BinderStore
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the third adversarial review of increment 1 (closed items under the title ratchet, rewrites
/// of tampered cards, the clerk and the disclosure ratchet, readings that could not be written, waiting parties on
/// repair cards, failed state backups, and file names in the capture journal). Invented data only.
@Suite(.serialized) struct AstraReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra3-\(label)-\(UUID().uuidString)")
    }

    /// Rewrites a stored card's file the way another program would, keeping it valid JSON.
    func tamper(_ id: String, in folder: URL, _ change: (inout JSONObject) -> Void) throws -> Data {
        let url = ProposalStore.dir(folder).appendingPathComponent("\(id).json")
        var raw = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        change(&raw)
        let data = Data(JSONWriter.pretty(.object(raw)).utf8)
        try data.write(to: url)
        return data
    }

    /// A card's first add_item retitled, as a tampering program might.
    func retitleFirstItem(_ raw: inout JSONObject) {
        var ops = raw["ops"]?.arrayValue ?? []
        guard case .object(var op)? = ops.first, var args = op["args"]?.objectValue, var item = args["item"]?.objectValue else { return }
        item.set("title", .str("Invented tampered task"))
        args.set("item", .object(item))
        op.set("args", .object(args))
        ops[0] = .object(op)
        raw.set("ops", .array(ops))
    }

    // MARK: - 2. A stored card changed by another program is never trusted again by a rewrite

    @Test func aRewriteRefusesACardChangedOutside() throws {
        let c = Commands(support: temp("support"), deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))])
        let item = JSONValue.obj([("id", .str("$new:1")), ("title", .str("Invented task")), ("status", .str("open")),
                                  ("priority", .str("normal")), ("no_deadline", .bool(true))])
        let card = Proposal.make(title: "Invented card", actor: actor,
                                 ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", item)]))])],
                                 provenance: JSONObject(), now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)

        // As Sprava wrote it: rewritten and trusted.
        try c.rewriteTrusted(card.id, in: folder) { p in
            var raw = p.raw
            raw.set("title", .str("Invented card, annotated"))
            return Proposal(raw: raw)
        }
        #expect(c.isTrusted(card.id, in: folder))

        // Changed outside: left as it is, unverified.
        let changed = try tamper(card.id, in: folder, retitleFirstItem)
        #expect(throws: ProposalStore.Tampered.self) { try c.rewriteTrusted(card.id, in: folder) { $0 } }
        #expect(throws: ProposalStore.Tampered.self) { try c.loadTrusted(card.id, in: folder) }
        #expect(try Data(contentsOf: ProposalStore.dir(folder).appendingPathComponent("\(card.id).json")) == changed)
        #expect(!c.isTrusted(card.id, in: folder))
    }

    // MARK: - 5. A repair card takes the waiting party the person writes

    @Test func aRepairCardTakesAWaitingParty() throws {
        let op = JSONObject([(key: "op", value: .str("update_item")),
                             (key: "args", value: .obj([("id", .str("item-0004")), ("set", .obj([("status", .str("waiting"))])),
                                                        ("unset", .array([.str("waiting_on")]))]))])
        let edited = try CardEdits.apply([.obj([("index", .int(0)), ("waiting_on", .str("  Invented Property Office "))])], to: [op])
        #expect(edited[0]["args"]?["set"]?["waiting_on"] == .str("Invented Property Office"))
        #expect(edited[0]["args"]?["unset"] == nil)
        #expect(throws: CardEdits.Failure.self) { try CardEdits.apply([.obj([("index", .int(0)), ("waiting_on", .str("  "))])], to: [op]) }
        #expect(throws: CardEdits.Failure.self) {
            try CardEdits.apply([.obj([("index", .int(0)), ("waiting_on", .string(String(repeating: "x", count: 201)))])], to: [op])
        }
    }
}

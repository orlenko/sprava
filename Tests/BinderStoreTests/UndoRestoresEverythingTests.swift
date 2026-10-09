import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Every undo gives back the item exactly as it was before the op it reverses, field for field: derived, the
/// waiting fields, recurrence, dismissed, the privacy fields and fields this format does not define. What it cannot
/// give back with the same meaning refuses the undo (from Bugbot's fourth pass on BinderStore part 2). Invented data.
@Suite(.serialized) struct UndoRestoresEverythingTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07
    let user = JSONObject([(key: "kind", value: .str("user"))])

    /// A waiting item with every kind of field, hidden and redacted, with inferred dates and a field of its own.
    static let rich: JSONValue = .obj([
        ("id", .str("estate-example-2026-101")), ("title", .str("Invented reply from the registry")), ("status", .str("waiting")),
        ("priority", .str("high")), ("due", .str("2026-11-01")), ("waiting_on", .str("the invented registry")),
        ("expected_by", .str("2026-10-19")), ("follow_up_at", .str("2026-10-20")), ("kind", .str("reply-owed")),
        ("redact", .bool(true)), ("slice_title", .str("Invented reply")), ("tags", .array([.str("registry")])),
        ("dismissed", .bool(true)), ("derived", .array([.str("follow_up_at"), .str("due")])),
        ("x_invented", .obj([("kept", .int(1))])), ("created_at", .str("2026-09-30T09:12:00Z")),
        ("updated_at", .str("2026-10-02T16:40:00Z")),
        ("provenance", .obj([("approved_by", .str("user")), ("proposal", .str("019a0f53-0a1b-7c2d-8e3f-4a5b6c7d8e90"))])),
    ])
    /// A repeating item whose due date the clerk inferred.
    static let repeating: JSONValue = .obj([
        ("id", .str("estate-example-2026-102")), ("title", .str("Invented monthly payment")), ("status", .str("open")),
        ("priority", .str("normal")), ("due", .str("2026-10-15")), ("kind", .str("payment")),
        ("recurrence", .obj([("freq", .str("monthly")), ("day", .int(15))])), ("derived", .array([.str("due")])),
        ("x_invented", .str("kept")),
    ])

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            guard case .object(var catalog) = try JSONParser.parse(try Data(contentsOf: url)).value else { return }
            catalog.set("open_items", .array((catalog["open_items"]?.arrayValue ?? []) + [Self.rich, Self.repeating]))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        return (folder, store)
    }

    /// The value with object keys in one order and the given keys left out, so two items compare by their fields.
    static func normal(_ v: JSONValue, without dropped: Set<String> = ["updated_at"]) -> JSONValue {
        switch v {
        case .object(let o):
            return .obj(o.entries.filter { !dropped.contains($0.key) }.sorted { $0.key < $1.key }
                .map { ($0.key, normal($0.value, without: dropped)) })
        case .array(let a): return .array(a.map { normal($0, without: dropped) })
        default: return v
        }
    }

    func items(_ folder: URL) -> [JSONValue] { Teka.read(folder).catalog?["open_items"]?.arrayValue ?? [] }

    struct Case: CustomStringConvertible {
        let name: String
        let op: String
        let args: [(String, JSONValue)]
        var description: String { name }
    }

    static let r = JSONValue.str("estate-example-2026-101")
    static let cases: [Case] = [
        Case(name: "update_item sets, unsets and confirms", op: "update_item", args: [("id", r), ("set", .obj([
            ("due", .str("2026-11-05")), ("title", .str("Invented other title")), ("tags", .array([]))])),
            ("unset", .array([.str("x_invented"), .str("expected_by")]))]),
        Case(name: "update_item writes derived itself", op: "update_item", args: [("id", r), ("set", .obj([("derived", .array([.str("due")]))]))]),
        Case(name: "update_item on privacy fields", op: "update_item", args: [("id", r), ("set", .obj([("slice_title", .str("Other invented"))])),
            ("unset", .array([.str("tags")]))]),
        Case(name: "set_status open drops the waiting fields", op: "set_status", args: [("id", r), ("status", .str("open"))]),
        Case(name: "set_status blocked with another party", op: "set_status", args: [("id", r), ("status", .str("blocked")),
            ("waiting_on", .str("another invented office"))]),
        Case(name: "set_status waiting on an open item", op: "set_status", args: [("id", .str("estate-example-2026-007")),
            ("status", .str("waiting")), ("waiting_on", .str("the invented notary")), ("follow_up_at", .str("2026-10-12"))]),
        Case(name: "dismiss", op: "dismiss", args: [("id", .str("estate-example-2026-007"))]),
        Case(name: "undismiss", op: "undismiss", args: [("id", r)]),
        Case(name: "complete one occurrence", op: "complete", args: [("id", .str("estate-example-2026-102")),
            ("next_due", .str("2026-11-15")), ("occurrence_due", .str("2026-10-15"))]),
        Case(name: "add_item", op: "add_item", args: [("item", .obj([("id", .str("estate-example-2026-103")),
            ("title", .str("Invented new task")), ("status", .str("open")), ("priority", .str("low")), ("no_deadline", .bool(true))]))]),
    ]

    @Test(arguments: cases)
    func undoGivesBackTheOpenItemsAsTheyWere(_ c: Case) throws {
        let (folder, store) = try adopted()
        let before = items(folder)
        let applied = try store.apply([.init(op: c.op, args: JSONObject(c.args.map { (key: $0.0, value: $0.1) }), actor: user)], now: now)
        #expect(Self.normal(.array(items(folder))) != Self.normal(.array(before)), "\(c): the op changed something")
        try store.undo(opID: applied[0]["id"]!.stringValue!, now: now)
        #expect(Self.normal(.array(items(folder))) == Self.normal(.array(before)), "\(c)")
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test(arguments: ["complete", "drop"])
    func undoingAClosureReopensEveryFieldUnderANewID(_ close: String) throws {
        let (folder, store) = try adopted()
        let before = items(folder)
        let closed = try store.apply([.init(op: close, args: JSONObject([(key: "id", value: Self.r),
            (key: "closed_at", value: .str("2026-10-07T09:00:00Z")), (key: "source", value: .str("user"))]), actor: user)], now: now)
        try store.undo(opID: closed[0]["id"]!.stringValue!, now: now)
        let after = items(folder)
        let reopened = try #require(after.first { $0["provenance"]?["reopened_from"] == Self.r })
        // Only what a reopening must change differs: the id, the times and the note of where it came from.
        let skip: Set<String> = ["id", "created_at", "updated_at", "reopened_from"]
        #expect(Self.normal(reopened, without: skip) == Self.normal(Self.rich, without: skip))
        let others = { (list: [JSONValue]) in Self.normal(.array(list.filter { $0["id"] != Self.r && $0["provenance"]?["reopened_from"] == nil })) }
        #expect(others(after) == others(before))
    }

    // Bugbot qsdrg: an entry whose `final` an outside edit removed reopens from the replayed item, never from defaults.
    @Test func aClosureEntryWithoutFinalReopensFromTheReplayedItem() throws {
        let (folder, store) = try adopted()
        let closed = try store.apply([.init(op: "drop", args: JSONObject([(key: "id", value: Self.r),
            (key: "closed_at", value: .str("2026-10-07T09:00:00Z")), (key: "source", value: .str("user"))]), actor: user)], now: now)
        let url = folder.appendingPathComponent("catalog.json")
        guard case .object(var catalog) = try JSONParser.parse(try Data(contentsOf: url)).value else { Issue.record("no catalog"); return }
        let log = (catalog["processing_log"]?.arrayValue ?? []).map { entry -> JSONValue in
            guard entry["id"] == Self.r, case .object(var o) = entry else { return entry }
            o.remove("final")
            return .object(o)
        }
        catalog.set("processing_log", .array(log))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)

        try store.undo(opID: closed[0]["id"]!.stringValue!, now: now)
        let reopened = try #require(items(folder).first { $0["provenance"]?["reopened_from"] == Self.r })
        let skip: Set<String> = ["id", "created_at", "updated_at", "reopened_from"]
        #expect(Self.normal(reopened, without: skip) == Self.normal(Self.rich, without: skip))
    }

    /// The compensation for closing `item`, built directly, so a closure the guard would never let through can be tried.
    func compensateClosure(of item: JSONObject, final: JSONObject?, stateBefore: [JSONValue] = []) throws -> (op: String, args: JSONObject) {
        var entry: [(String, JSONValue)] = [("id", item["id"]!), ("title", item["title"] ?? .str("")), ("action", .str("dropped")),
                                            ("op_id", .str("op-1"))]
        if let final { entry.append(("final", .object(final))) }
        let catalog = JSONObject([(key: "meta", value: .obj([("name", .str("estate-example"))])), (key: "open_items", value: .array([])),
                                  (key: "processing_log", value: .array([.obj(entry)]))])
        let target = JSONObject([(key: "id", value: .str("op-1")), (key: "op", value: .str("drop")),
                                 (key: "args", value: .obj([("id", item["id"]!)]))])
        return try Undo.compensate(target, catalog: catalog, opLog: [], stateBefore: JSONObject([(key: "open_items", value: .array(stateBefore))]),
                                   year: 2026, now: now)
    }

    func final(_ fields: [(String, JSONValue)]) -> JSONObject { JSONObject(fields.map { (key: $0.0, value: $0.1) }) }

    // Bugbot qsdrl: a saved date that cannot be read refuses the undo instead of turning into "no deadline".
    @Test(arguments: ["due", "follow_up_at", "expected_by"])
    func aSavedDateThatCannotBeReadRefusesTheUndo(_ field: String) throws {
        let item = final([("id", .str("x-1")), ("title", .str("Invented task"))])
        var fields: [(String, JSONValue)] = [("status", .str("waiting")), ("priority", .str("normal")), ("due", .str("2026-11-01"))]
        fields.removeAll { $0.0 == field }
        fields.append((field, .str("end of the invented month")))
        #expect(throws: Undo.Unsupported.self) { try compensateClosure(of: item, final: final(fields)) }
    }

    @Test func aClosureWithoutAnyRecordOfTheItemRefusesTheUndo() throws {
        let item = final([("id", .str("x-1")), ("title", .str("Invented task"))])
        #expect(throws: Undo.Unsupported.self) { try compensateClosure(of: item, final: nil) }
        // With the replayed item it reopens with that item's fields.
        let was: JSONValue = .obj([("id", .str("x-1")), ("title", .str("Invented task")), ("status", .str("open")),
                                   ("priority", .str("low")), ("due", .str("2026-12-01"))])
        let (op, args) = try compensateClosure(of: item, final: nil, stateBefore: [was])
        #expect(op == "reopen" && args["item"]?["priority"] == .str("low") && args["item"]?["due"] == .str("2026-12-01"))
    }

    @Test func fieldsTheReopenCannotGiveBackRefuseTheUndo() throws {
        let item = final([("id", .str("x-1")), ("title", .str("Invented task"))])
        // An unknown deadline (no due, no no_deadline), a deadline that is both, and no priority.
        for fields: [(String, JSONValue)] in [
            [("status", .str("open")), ("priority", .str("normal"))],
            [("status", .str("open")), ("priority", .str("normal")), ("due", .str("2026-11-01")), ("no_deadline", .bool(true))],
            [("status", .str("open")), ("due", .str("2026-11-01"))],
        ] {
            #expect(throws: Undo.Unsupported.self) { try compensateClosure(of: item, final: final(fields)) }
        }
        // A compact date is written out and marked inferred, as adoption does.
        let (_, args) = try compensateClosure(of: item, final: final([("status", .str("open")), ("priority", .str("normal")),
                                                                      ("due", .str("20261101"))]))
        #expect(args["item"]?["due"] == .str("2026-11-01") && args["item"]?["derived"] == .array([.str("due")]))
    }

    @Test func undoingADismissThatChangedNothingIsRefused() throws {
        let (folder, store) = try adopted()
        let applied = try store.apply([.init(op: "dismiss", args: JSONObject([(key: "id", value: Self.r)]), actor: user)], now: now)
        let before = items(folder)
        #expect(throws: Undo.Unsupported.self) { try store.undo(opID: applied[0]["id"]!.stringValue!, now: now) }
        #expect(Self.normal(.array(items(folder)), without: []) == Self.normal(.array(before), without: []))
    }
}

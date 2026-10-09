import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// A title that is not text is never lost by a closure, and a log written before that rule replays as it was
/// (from Bugbot's fifth pass on BinderStore part 2 and its review). Adoption closes such an item only on its repair
/// card, judged as one change, and only once the person gave it a title. Invented data only.
@Suite(.serialized) struct ClosureKeepsTitleTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    func close(_ item: [(String, JSONValue)], keep: String? = nil) throws -> JSONValue? {
        let catalog = JSONObject([(key: "open_items", value: .array([.obj(item)])), (key: "processing_log", value: .array([]))])
        var args: [(String, JSONValue)] = [("id", .str("x-1"))]
        if let keep { args.append(("keep_title_as", .string(keep))) }
        let line = JSONObject([(key: "id", value: .str("op-1")), (key: "at", value: .str("2026-10-07T09:00:00Z")), (key: "op", value: .str("drop")),
                               (key: "actor", value: .object(user)), (key: "args", value: .obj(args))])
        return try OpApplier.apply(line, to: catalog)["processing_log"]?.arrayValue?.last
    }

    @Test(arguments: [JSONValue.int(42), .obj([("en", .str("Invented"))]), .array([.str("Invented")]), .bool(false)])
    func theApplierKeepsATitleThatIsNotTextWhereTheOpSays(_ title: JSONValue) throws {
        let entry = try #require(try close([("id", .str("x-1")), ("title", title), ("status", .str("open"))], keep: "legacy_title"))
        #expect(entry["title"] == .str(""))
        #expect(entry["final"]?["legacy_title"] == title)
        // Without the argument the closure applies as it always did, so older logs replay unchanged.
        let old = try #require(try close([("id", .str("x-1")), ("title", title), ("status", .str("open"))]))
        #expect(old["final"]?["legacy_title"] == nil)
        // A name already taken in the item is refused, never written over.
        #expect(throws: OpApplier.Failure.self) {
            try close([("id", .str("x-1")), ("title", title), ("legacy_title", .str("older")), ("status", .str("open"))], keep: "legacy_title")
        }
    }

    @Test func aClosureLoggedBeforeTheRuleStillReplays() throws {
        // Written by the applier as it was before `keep_title_as` (commit d62dfba): a drop of an item titled 42.
        let url = try #require(TestFixtures.bundle.url(forResource: "legacy-title-closure", withExtension: "ndjson", subdirectory: "Fixtures/ops"))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(try JSONParser.parse(String($0)).value.objectValue)
        }
        let state = try Replay.run(lines)
        let entry = try #require(state["processing_log"]?.arrayValue?.last)
        #expect(entry["final"]?["legacy_title"] == nil && entry["title"] == .str(""))
    }

    /// The fixture binder adopted, with `fields` set on the item each names.
    func adopted(_ fields: [(String, [(String, JSONValue)])]) throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            guard case .object(var catalog) = try JSONParser.parse(try Data(contentsOf: url)).value else { return }
            catalog.set("open_items", .array((catalog["open_items"]?.arrayValue ?? []).map { item -> JSONValue in
                guard case .object(var o) = item else { return item }
                for (id, set) in fields where o["id"] == .string(id) { for (key, value) in set { o.set(key, value) } }
                return .object(o)
            }))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        return (folder, store)
    }

    @Test func theWriterNamesTheNextFreeLegacyTitleAndTheGuardRequiresIt() throws {
        let (folder, store) = try adopted([("estate-example-2026-007", [("title", .int(7)), ("legacy_title", .str("older"))])])
        let id = JSONValue.str("estate-example-2026-007")
        let lines = try store.apply([.init(op: "drop", args: JSONObject([(key: "id", value: id)]), actor: user)], now: now)
        #expect(lines[0]["args"]?["keep_title_as"] == .str("legacy_title_2"))
        let entry = try #require(Teka.read(folder).catalog?["processing_log"]?.arrayValue?.last { $0["id"] == id })
        #expect(entry["final"]?["legacy_title_2"] == .int(7) && entry["final"]?["legacy_title"] == .str("older"))
        _ = try Replay.run(try store.readOpLog().ops)

        // A closure line that does not keep it is refused by the guard.
        let (other, _) = try adopted([("estate-example-2026-008", [("title", .int(8))])])
        let catalog = try #require(Teka.read(other).catalog)
        let bare = JSONObject([(key: "id", value: .str("op-1")), (key: "at", value: .str("2026-10-07T09:00:00Z")), (key: "op", value: .str("drop")),
                               (key: "actor", value: .object(user)), (key: "args", value: .obj([("id", .str("estate-example-2026-008"))]))])
        #expect(throws: TransactionGuard.Rejection.self) { try TransactionGuard.check([bare], on: catalog) }
    }

    /// A binder whose item `item` gets a title that is not text (and maybe another status or id); the card that
    /// closes `closes` is looked for after adoption.
    struct Case: CustomStringConvertible, Sendable {
        let name: String
        let fixture: String
        let item: String
        let title: JSONValue
        var status: String? = nil
        var newID: String? = nil
        var closes: String { newID ?? item }
        var description: String { name }
    }

    static let cases: [Case] = [
        Case(name: "done in a lifeproj binder", fixture: "lifeproj-v2-live", item: "item-0005", title: .int(5)),
        Case(name: "an id that already closes a log entry", fixture: "lifeproj-v2-live", item: "item-0005", title: .int(5),
             status: "open", newID: "item-0001"),
        Case(name: "done in a stamped binder", fixture: "sprava-v0", item: "estate-example-2026-007", title: .int(7), status: "done"),
    ]

    @Test(arguments: cases)
    func theRepairThenCloseCardPassesOnceTheTitleIsGiven(_ c: Case) throws {
        let folder = try makeTeka(fixture: c.fixture) { folder in
            let url = folder.appendingPathComponent("catalog.json")
            guard case .object(var catalog) = try JSONParser.parse(try Data(contentsOf: url)).value else { return }
            catalog.set("open_items", .array((catalog["open_items"]?.arrayValue ?? []).map { item -> JSONValue in
                guard item["id"] == .string(c.item), case .object(var o) = item else { return item }
                o.set("title", c.title)
                if let status = c.status { o.set("status", .string(status)) }
                if let newID = c.newID { o.set("id", .string(newID)) }
                return .object(o)
            }))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "test-device", today: today, now: now)
        let closing = result.proposals.filter { $0.ops.contains { $0["op"] == .str("complete") && $0["args"]?["id"] == .string(c.closes) } }
        #expect(closing.count == 1, "\(c): one card closes it")
        let card = try #require(closing.first)
        #expect(card.ops.map { $0["op"]?.stringValue ?? "" } == ["update_item", "complete"])

        let store = TekaStore(folder: folder)
        // Approved unchanged, it is refused: the title it asks for is still missing when the closure would run.
        #expect(throws: TekaStore.Refused.self, "\(c)") { try store.approve(card, now: now) }
        let edited = try CardEdits.apply([.obj([("index", .int(0)), ("title", .str("Invented title"))])], to: card.ops)
        try store.approve(card, edited: edited, now: now)
        let entry = try #require(Teka.read(folder).catalog?["processing_log"]?.arrayValue?.last {
            ($0["id"] ?? $0["item"]) == .string(c.closes) && $0["op_id"] != nil })
        #expect(entry["title"] == .str("Invented title"), "\(c)")
        #expect(entry["final"]?["legacy_title"] == c.title, "\(c): the old title is kept")
        #expect(!(Teka.read(folder).catalog?["open_items"]?.arrayValue ?? []).contains { $0["id"] == .string(c.closes) }, "\(c)")
        _ = try Replay.run(try store.readOpLog().ops)
    }
}

import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// A title that is not text is never lost by a closure: adoption closes such an item only on its repair card, after
/// the person gives it a title, and the applier keeps any such title in `final` under `legacy_title` (from Bugbot's
/// fifth pass on BinderStore part 2). Invented data only.
@Suite(.serialized) struct ClosureKeepsTitleTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    func close(_ item: [(String, JSONValue)], op: String = "drop") throws -> JSONValue? {
        let catalog = JSONObject([(key: "open_items", value: .array([.obj(item)])), (key: "processing_log", value: .array([]))])
        let line = JSONObject([(key: "id", value: .str("op-1")), (key: "at", value: .str("2026-10-07T09:00:00Z")), (key: "op", value: .string(op)),
                               (key: "actor", value: .obj([("kind", .str("user"))])), (key: "args", value: .obj([("id", .str("x-1"))]))])
        return try OpApplier.apply(line, to: catalog)["processing_log"]?.arrayValue?.last
    }

    @Test(arguments: [JSONValue.int(42), .obj([("en", .str("Invented"))]), .array([.str("Invented")]), .bool(false)])
    func theApplierKeepsATitleThatIsNotTextInFinal(_ title: JSONValue) throws {
        let entry = try #require(try close([("id", .str("x-1")), ("title", title), ("status", .str("open"))]))
        #expect(entry["title"] == .str(""))
        #expect(entry["final"]?["legacy_title"] == title)
        // A taken legacy name moves it to the next one, and the earlier value stays.
        let taken = try #require(try close([("id", .str("x-1")), ("title", title), ("legacy_title", .str("older")), ("status", .str("open"))]))
        #expect(taken["final"]?["legacy_title"] == .str("older") && taken["final"]?["legacy_title_2"] == title)
        // A text title is the entry's title, and nothing is added.
        let plain = try #require(try close([("id", .str("x-1")), ("title", .str("Invented task")), ("status", .str("open"))]))
        #expect(plain["title"] == .str("Invented task") && plain["final"]?["legacy_title"] == nil)
    }

    @Test func adoptionClosesAnItemWithoutATextTitleOnlyOnItsRepairCard() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            guard case .object(var catalog) = try JSONParser.parse(try Data(contentsOf: url)).value else { return }
            let items = (catalog["open_items"]?.arrayValue ?? []).map { item -> JSONValue in
                guard item["id"] == .str("item-0005"), case .object(var o) = item else { return item }
                o.set("title", .int(5))
                return .object(o)
            }
            catalog.set("open_items", .array(items))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "test-device", today: today, now: now)
        // No card closes it before its title is given.
        let closing = result.proposals.filter { $0.ops.contains { $0["op"] == .str("complete") && $0["args"]?["id"] == .str("item-0005") } }
        #expect(closing.count == 1)
        let card = try #require(closing.first)
        #expect(card.ops.map { $0["op"]?.stringValue ?? "" } == ["update_item", "complete"])

        let store = TekaStore(folder: folder)
        let edited = try CardEdits.apply([.obj([("index", .int(0)), ("title", .str("Invented renewal"))])], to: card.ops)
        try store.approve(card, edited: edited, now: now)
        let entry = try #require(Teka.read(folder).catalog?["processing_log"]?.arrayValue?.last { $0["id"] == .str("item-0005") })
        #expect(entry["title"] == .str("Invented renewal"))
        #expect(entry["final"]?["legacy_title"] == .int(5))
    }
}

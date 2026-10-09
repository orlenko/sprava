import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Every value adoption replaces or removes stays in the catalog under a legacy key (binder-v0 §9.5), whatever its
/// shape (from layer 5's fifth calibrated review: a `derived` object rewritten to a list). Invented data only.
@Suite(.serialized) struct AdoptionKeepsAsideTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07
    let today = CalendarDate(year: 2026, month: 10, day: 7)!

    /// One rewrite: where the old value sits (`meta`, or the item's field), the legacy key it should end under, and
    /// the catalog that holds it.
    struct Case: CustomStringConvertible {
        let rewrite: String
        let old: JSONValue
        let inMeta: Bool
        let field: String
        let schemaVersion: JSONValue
        let meta: [(String, JSONValue)]
        let item: [(String, JSONValue)]
        var description: String { "\(rewrite) of \(JSONWriter.compact(old))" }
    }

    static let shapes: [JSONValue] = [.obj([("note", .str("Invented note"))]), .array([.str("x"), .int(1)]), .int(3)]
    static let plainItem: [(String, JSONValue)] = [("id", .str("p-1")), ("title", .str("Invented task")), ("status", .str("open")),
                                                   ("priority", .str("normal")), ("due", .str("2026-11-01"))]

    static func meta(_ rewrite: String, _ field: String, strings: [String], schemaVersion: JSONValue = .int(2)) -> [Case] {
        (shapes + strings.map(JSONValue.string)).map {
            Case(rewrite: rewrite, old: $0, inMeta: true, field: field, schemaVersion: schemaVersion,
                 meta: [(field, $0)], item: plainItem)
        }
    }

    static func item(_ rewrite: String, _ old: [JSONValue], _ build: (JSONValue) -> [(String, JSONValue)], field: String) -> [Case] {
        old.map { Case(rewrite: rewrite, old: $0, inMeta: false, field: field, schemaVersion: .int(2), meta: [], item: build($0)) }
    }

    static let cases: [Case] =
        meta("stamp: format_version", "format_version", strings: ["custom-v3"])
        + meta("stamp: disclosure", "disclosure", strings: ["lifeproj text"])
        + meta("stamp: name", "name", strings: [""])
        + meta("set_meta: lifecycle", "lifecycle", strings: ["legacy"])
        + meta("set_meta: created", "created", strings: ["June 2026"])
        + [.int(1), .str("1")].map {
            Case(rewrite: "stamp: schema_version", old: $0, inMeta: true, field: "schema_version", schemaVersion: $0, meta: [], item: plainItem)
        }
        + [.int(0), .int(-1)].map {
            Case(rewrite: "migration: schema_version", old: $0, inMeta: true, field: "schema_version", schemaVersion: $0, meta: [], item: plainItem)
        }
        + item("mechanical: due", [.str("20261101")], { [("id", .str("p-1")), ("title", .str("Invented task")), ("status", .str("open")),
                                                         ("priority", .str("normal")), ("due", $0)] }, field: "due")
        + item("mechanical: derived", shapes + [.str("due")], { [("id", .str("p-1")), ("title", .str("Invented task")),
                                                                 ("status", .str("open")), ("priority", .str("normal")),
                                                                 ("due", .str("20261101")), ("derived", $0)] }, field: "derived")
        + item("repair card: derived", shapes + [.str("x")], { [("id", .str("p-1")), ("title", .str("Invented wait")),
                                                                ("status", .str("waiting")), ("priority", .str("normal")),
                                                                ("due", .str("2026-11-01")), ("derived", $0)] }, field: "derived")

    func binder(_ c: Case) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-aside-\(UUID().uuidString)/tax", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var meta = JSONObject([(key: "schema_version", value: c.schemaVersion), (key: "name", value: .str("tax"))])
        for (k, v) in c.meta { meta.set(k, v) }
        let catalog = JSONObject([(key: "meta", value: .object(meta)), (key: "documents", value: .array([])),
                                  (key: "open_items", value: .array([.obj(c.item)])), (key: "processing_log", value: .array([]))])
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
        return folder
    }

    /// Adopts, approves each card adoption made (a repair card with what it asks for filled in), then the stamp.
    func adoptAndApprove(_ folder: URL) throws {
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        let store = TekaStore(folder: folder)
        func isStamp(_ p: Proposal) -> Bool { p.raw["provenance"]?["adoption"] == .str("stamp") }
        for card in result.proposals where !isStamp(card) {
            var edited: [JSONObject]?
            if let asked = card.raw["provenance"]?["repair"]?.arrayValue?.compactMap(\.stringValue) {
                var fill: [(String, JSONValue)] = [("index", .int(0))]
                if asked.contains("waiting_on") { fill.append(("waiting_on", .str("Invented party"))) }
                edited = try CardEdits.apply([.obj(fill)], to: card.ops)
            }
            try store.approve(card, edited: edited, now: now)
        }
        if let stamp = result.proposals.first(where: isStamp) {
            try store.approve(stamp, now: now)
        } else if let id = try Adoption.offerStamp(folder, now: now) {
            try store.approve(try ProposalStore.load(id, in: folder, expectedDigest: nil), now: now)
        }
    }

    @Test(arguments: cases) func everyReplacedValueIsKeptAside(_ c: Case) throws {
        let folder = try binder(c)
        try adoptAndApprove(folder)
        let teka = Teka.read(folder)
        #expect(teka.level == .tekaV0, "\(c): \(teka.reasons)")
        let holder = c.inMeta ? teka.catalog?["meta"]?.objectValue : teka.items.first?.object
        let legacy = (holder?.entries ?? []).filter { $0.key == "legacy_\(c.field)" || $0.key.hasPrefix("legacy_\(c.field)_") }
        #expect(legacy.contains { $0.value == c.old }, "\(c): \(legacy)")
    }

    // Layer 5 fifth calibrated review, finding 2: an item without an id gets a card the person settles by hand.
    @Test func anItemWithoutAnIDGetsAHandRepairCard() throws {
        let c = Case(rewrite: "none", old: .null, inMeta: false, field: "id", schemaVersion: .int(2), meta: [],
                     item: Array(Self.plainItem.dropFirst()))
        let folder = try binder(c)
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "t", today: today, now: now)
        let card = try #require(result.proposals.first { $0.raw["provenance"]?["adoption"] == .str("no-id") })
        #expect(card.raw["provenance"]?["positions"] == .array([.int(0)]))
        #expect(card.title.hasSuffix(": 1"))
        #expect(throws: TekaStore.Refused.self) { try TekaStore(folder: folder).approve(card, now: now) }
    }
}

import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// #690: a document record with a date in another form, or with no title, kept the stamp from being offered, and
/// nothing told the person which records to fix.
@Suite struct AdoptionDocumentRecordsTests {
    private func write(_ folder: URL, documents: [JSONValue]) throws {
        let file = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: file)).value.objectValue)
        catalog.set("documents", .array(documents))
        try Data(JSONWriter.compact(.object(catalog)).utf8).write(to: file)
    }

    private func doc(_ id: String, _ fields: [(String, JSONValue)]) -> JSONValue {
        .obj([("id", .str(id)), ("path", .str("notices/2026-05-01_invented-\(id).pdf"))] + fields)
    }

    private func documents(in folder: URL) -> [JSONValue] { Teka.read(folder).catalog?["documents"]?.arrayValue ?? [] }

    private func record(_ id: String, in folder: URL) -> JSONObject? {
        Teka.read(folder).catalog?["documents"]?.arrayValue?.first { $0["id"] == .str(id) }?.objectValue
    }

    @Test func recordsCodeCanSettleAreFixedInOneWriteAndTheStampIsOffered() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        var catalog = try #require(Teka.read(folder).catalog)
        catalog.set("open_items", .array([]))
        try Data(JSONWriter.compact(.object(catalog)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
        try write(folder, documents: [
            doc("fine", [("title", .str("Invented notice")), ("date", .str("2026-05-01"))]),
            doc("compact", [("title", .str("Invented bill")), ("date", .str("20260502"))]),
            doc("timed", [("title", .str("Invented letter")), ("date", .str("2026-05-03T09:30:00Z"))]),
            doc("month", [("title", .str("Invented statement")), ("date", .str("2026-05"))]),
            doc("words", [("title", .str("Invented receipt")), ("date", .str("spring of an invented year"))]),
            doc("number", [("title", .str("Invented form")), ("date", .int(2026))]),
            doc("null", [("title", .str("Invented memo")), ("date", .null)]),
            doc("empty", [("title", .str("Invented card")), ("date", .str(""))]),
            doc("untitled", [("date", .str("2026-05-04"))]),
            doc("blank", [("title", .str(""))]),
            doc("lines", [("title", .str("Invented notice\nsecond line\r\n  third "))]),
            doc("odd", [("title", .int(7))]),
        ])
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        let fixes = result.mechanical.filter { $0["op"] == .str("update_document") }
        #expect(fixes.count == 11)
        #expect(Set(fixes.compactMap { $0["batch"]?.stringValue }).count == 1)

        #expect(record("fine", in: folder)?.keys == ["id", "path", "title", "date"])
        #expect(record("compact", in: folder)?["date"] == .str("2026-05-02"))
        #expect(record("compact", in: folder)?["legacy_date"] == .str("20260502"))
        #expect(record("timed", in: folder)?["date"] == .str("2026-05-03"))
        #expect(record("timed", in: folder)?["legacy_date"] == .str("2026-05-03T09:30:00Z"))
        for (id, kept) in [("month", JSONValue.str("2026-05")), ("words", .str("spring of an invented year")), ("number", .int(2026))] {
            #expect(record(id, in: folder)?["date"] == nil)
            #expect(record(id, in: folder)?["legacy_date"] == kept)
        }
        for id in ["null", "empty"] {
            #expect(record(id, in: folder)?["date"] == nil)
            #expect(record(id, in: folder)?["legacy_date"] == nil)
        }
        #expect(record("untitled", in: folder)?["title"] == .str("2026-05-01_invented-untitled"))
        #expect(record("blank", in: folder)?["title"] == .str("2026-05-01_invented-blank"))
        #expect(record("blank", in: folder)?["legacy_title"] == nil)
        #expect(record("lines", in: folder)?["title"] == .str("Invented notice second line third"))
        #expect(record("lines", in: folder)?["legacy_title"] == .str("Invented notice\nsecond line\r\n  third "))
        #expect(record("odd", in: folder)?["title"] == .str("2026-05-01_invented-odd"))
        #expect(record("odd", in: folder)?["legacy_title"] == .int(7))

        #expect(ItemRules.check(documents: documents(in: folder)).isEmpty)
        #expect(!result.proposals.contains { $0.raw["provenance"]?["adoption"] == .str("documents") })
        #expect(result.proposals.contains { $0.raw["provenance"]?["adoption"] == .str("stamp") })
    }

    @Test func aLegacyNameAlreadyTakenIsNeverOverwritten() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder, documents: [doc("kept", [("title", .str("Invented notice")), ("date", .str("20260502")),
                                                   ("legacy_date", .str("an earlier invented value"))])])
        _ = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        let kept = try #require(record("kept", in: folder))
        #expect(kept["legacy_date"] == .str("an earlier invented value"))
        #expect(kept["legacy_date_2"] == .str("20260502"))
        #expect(kept["date"] == .str("2026-05-02"))
    }

    @Test func recordsNoOpCanNameGoOnOneCardByTheirPlace() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder, documents: [
            doc("fine", [("title", .str("Invented notice"))]),
            .obj([("title", .str("Invented record with no id")), ("path", .str("notices/invented-a.pdf")), ("date", .str("20260502"))]),
            .obj([("id", .str("no-path")), ("date", .str("2026-05"))]),
            .str("an invented line that is not a record"),
            doc("twin", [("date", .str("20260503"))]),
            doc("twin", [("title", .str("Invented twin"))]),
        ])
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        let cards = result.proposals.filter { $0.raw["provenance"]?["adoption"] == .str("documents") }
        let card = try #require(cards.first)
        #expect(cards.count == 1 && card.ops.isEmpty && card.raw["provenance"]?["manual_repair"] == .bool(true))
        #expect(card.title == "Fix the document records at these places in the list, by hand, then reject this card: "
                + "2 (id, date), 3 (title, path), 4 (the whole record), 5 (title, date, id), 6 (id)")
        // The record with a path but no usable date still got the date fix that needs no judgement.
        #expect(record("no-path", in: folder)?["legacy_date"] == .str("2026-05"))
        // A record whose id another holds is left exactly as found: an op would have changed whichever comes first.
        let twins = documents(in: folder).filter { $0["id"] == .str("twin") }
        #expect(twins.first?["date"] == .str("20260503") && twins.first?["legacy_date"] == nil)
        #expect(!result.proposals.contains { $0.raw["provenance"]?["adoption"] == .str("stamp") })
        // A second run makes no second card.
        let again = Adoption.documentCard(documents(in: folder), actor: JSONObject(), now: Date())
        #expect(again?.title == card.title)
    }

    @Test func aLongListOfPlacesIsCutWithACount() throws {
        let documents = (0..<75).map { n in JSONValue.obj([("title", .str("Invented record \(n)")), ("path", .str("notices/invented-\(n).pdf"))]) }
        let card = try #require(Adoption.documentCard(documents, actor: JSONObject(), now: Date()))
        #expect(card.title.hasSuffix("20 (id) and 55 more"))
        #expect(card.raw["provenance"]?["positions"]?.arrayValue?.count == 20 && card.raw["provenance"]?["count"] == .int(75))
    }

    @Test(.timeLimit(.minutes(1))) func aThousandHandWrittenRecordsAreFixedInBoundedTime() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        try write(folder, documents: (0..<1_000).map { n in doc("old-\(n)", [("date", .str("2026-0\(1 + n % 9)"))]) })
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        #expect(result.mechanical.filter { $0["op"] == .str("update_document") }.count == 1_000)
        #expect(ItemRules.check(documents: documents(in: folder)).isEmpty)
    }

    // Each fix costs the guard a reading and a hash of the whole catalog, so their number is held to a work budget; the
    // records past it are left as found and named on the card.
    @Test func fixesStopAtTheWorkBudgetAndTheRestGoOnTheCard() throws {
        let records = (0..<40).map { n in doc("old-\(n)", [("title", .str("Invented record \(n)")), ("date", .str("2026-05"))]) }
        let catalog = JSONObject([(key: "documents", value: .array(records))])
        let bytes = JSONWriter.compact(.object(catalog)).utf8.count
        let fixes = Adoption.documentFixes(catalog, actor: JSONObject(), work: bytes * 15)
        #expect(fixes.count == 15)
        #expect(fixes.map { $0.args["id"] } == (0..<15).map { .str("old-\($0)") })
        #expect(Adoption.documentFixes(catalog, actor: JSONObject(), work: bytes - 1).isEmpty)
        #expect(Adoption.documentFixes(catalog, actor: JSONObject()).count == 40)
        // Applied by hand here: the first fifteen fixed, the other twenty-five still break the date rule.
        let after = records.enumerated().map { n, record -> JSONValue in
            guard n < 15, var o = record.objectValue else { return record }
            o.remove("date")
            return .object(o)
        }
        let card = try #require(Adoption.documentCard(after, actor: JSONObject(), now: Date()))
        #expect(card.title.contains("16 (date)") && card.title.hasSuffix("and 5 more"))
    }

    @Test func theDayADateNamesIsReadOnlyWhenItNamesOne() {
        #expect(Adoption.oneDay("20260502")?.description == "2026-05-02")
        #expect(Adoption.oneDay("2026-05-03 09:30")?.description == "2026-05-03")
        #expect(Adoption.oneDay("2026-05-03T09:30:00+02:00")?.description == "2026-05-03")
        #expect(Adoption.oneDay("2026-05-03T09:30:00.250Z")?.description == "2026-05-03")
        // A span or a note after the date names no one day, so the date is kept aside whole and removed.
        for text in ["2026-05", "2026", "May 2026", "2026-13-01T00:00", "2026-05-03x09:30", "2026-05-03T" + String(repeating: "9", count: 60), "",
                     "2026-05-03 to 2026-05-09", "2026-05-03 2026-05-09", "2026-05-03 morning", "2026-05-03T", "2026-05-03T9:30", "2026-05-03 09h30"] {
            #expect(Adoption.oneDay(text) == nil)
        }
        #expect(Adoption.fileTitle("notices/invented.notice.pdf") == "invented.notice")
        #expect(Adoption.fileTitle(".hidden") == ".hidden")
        #expect(Adoption.fileTitle("") == "")
    }
}

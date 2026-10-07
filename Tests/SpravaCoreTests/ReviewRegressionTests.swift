import Foundation
import Testing
@testable import SpravaCore

/// One test per confirmed finding of the increment-1 hostile review.
@Suite struct ReviewRegressionTests {
    func folder(_ catalog: String, name: String = "estate-example") throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-rr-\(UUID().uuidString)")
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(catalog.utf8).write(to: folder.appendingPathComponent("catalog.json"))
        return folder
    }

    let v0Meta = #""meta": {"schema_version": 2, "name": "estate-example", "format": "teka", "format_version": "0", "disclosure": "none"}"#

    @Test func int64MinDoesNotCrash() throws {
        let (value, safety) = try JSONParser.parse(#"{"x": -9223372036854775808}"#)
        #expect(value["x"]?.numberValue?.safeInteger == nil)
        #expect(safety.unsafeNumbers == ["$.x"])
    }

    @Test func farFutureTimestampDoesNotCrash() throws {
        let entry = LogEntry(raw: try JSONParser.parse(#"{"id":"x","closed_at":"9999-12-31T23:00:00-12:00"}"#).value)
        #expect(entry.closingDate(timeZone: utc, today: today) == nil)
        #expect(CalendarDate(Date(timeIntervalSince1970: -62_200_000_000), in: utc) == nil)   // before year 1
    }

    @Test func normalizationEquivalentKeysAreDistinct() throws {
        let (value, safety) = try JSONParser.parse("{\"caf\u{E9}\":1,\"cafe\u{301}\":2}")
        #expect(safety.isSafe)
        #expect(value["caf\u{E9}"]?.numberValue?.text == "1")
        #expect(value["cafe\u{301}"]?.numberValue?.text == "2")
        #expect(JSONValue.string("caf\u{E9}") != JSONValue.string("cafe\u{301}"))
    }

    @Test func nonStringTitlesSortByCanonicalText() throws {
        let items = [#"{"id":"a","title":"Bravo","status":"open","no_deadline":true,"priority":"normal"}"#,
                     #"{"id":"b","title":7,"status":"open","no_deadline":true,"priority":"normal"}"#,
                     #"{"id":"c","title":"(zzz)","status":"open","no_deadline":true,"priority":"normal"}"#,
                     #"{"id":"d","title":"","status":"open","no_deadline":true,"priority":"normal"}"#]
            .enumerated().map { Item(raw: try! JSONParser.parse($1).value, index: $0) }
        let page = NowPage(items: items, log: [], today: today, timeZone: utc)
        #expect(ids(page, .noDeadline) == ["d", "c", "b", "a"])
    }

    @Test func nonObjectEntriesAndTypedDuplicateIDsAreFound() throws {
        let a = Teka.read(try folder("{\(v0Meta), \"documents\": [], \"open_items\": [], \"processing_log\": [1, \"two\", null]}"))
        #expect(a.state == .needsMigration)
        let b = Teka.read(try folder("{\(v0Meta), \"documents\": [{\"id\":1.5},{\"id\":1.5}], \"open_items\": [], \"processing_log\": []}"))
        #expect(b.reasons.contains { $0.contains("duplicate ids in documents") })
        let c = Teka.read(try folder("{\(v0Meta), \"documents\": [{\"id\":7},{\"id\":\"7\"}], \"open_items\": [], \"processing_log\": []}"))
        #expect(!c.reasons.contains { $0.contains("duplicate") })
    }

    @Test func stampedWithBadSchemaVersionStillGetsV0Rules() throws {
        let teka = Teka.read(try folder("""
        {"meta": {"schema_version": "2", "name": "estate-example", "format": "teka", "format_version": "0", "disclosure": "none"},
         "documents": [], "processing_log": [],
         "open_items": [{"id": "x", "title": "t", "status": "done", "priority": "normal", "due": "20261010"}]}
        """))
        #expect(teka.findings.contains { $0.code == .doneInOpenItems })
        #expect(teka.findings.contains { $0.code == .badDue })
    }

    @Test func stampedCatalogNeedsNameAndDisclosure() throws {
        let teka = Teka.read(try folder(#"{"meta":{"schema_version":2,"format":"teka","format_version":"0"},"documents":[],"open_items":[],"processing_log":[]}"#))
        #expect(teka.state == .needsAttention)
        #expect(teka.reasons.contains { $0.contains("meta.name") })
        #expect(teka.reasons.contains { $0.contains("disclosure") })
    }

    @Test func deepNestingWithLongKeysStaysCheap() throws {
        let key = String(repeating: "k", count: 2000)
        func nested(_ depth: Int) -> String {
            String(repeating: "{\"\(key)\":", count: depth) + "1" + String(repeating: "}", count: depth)
        }
        let clock = ContinuousClock()
        let elapsed = try clock.measure { _ = try JSONParser.parse(nested(120)) }
        #expect(elapsed < .seconds(2))
        #expect(throws: JSONParseError.self) { try JSONParser.parse(nested(200)) }
        #expect(throws: JSONParseError.self) { try JSONParser.parse(String(repeating: "[", count: 100_000)) }
    }

    @Test func weekDatesStayInRange() {
        #expect(CalendarDate.lenient("9999W527") == nil)
        #expect(CalendarDate.lenient("9999-W52-7") == nil)
        #expect(CalendarDate.lenient("9999-W52-5")?.description == "9999-12-31")
    }

    @Test func timestampsAreStrictRFC3339() {
        #expect(Timestamp.parse("2026-10-05t10:00:00z") != nil)
        #expect(Timestamp.parse("2026-10-05T10:00:00.250+05:30") != nil)
        for bad in ["2026-02-30T10:00:00Z", "2026-10-05T25:00:00Z", "2026-10-05T10:00:00+0530",
                    "2026-10-05T10:00:00+05", "2026-10-05T10:00:00Zjunk", "2026-10-05 10:00:00Z", "2026-10-05"] {
            #expect(Timestamp.parse(bad) == nil, "\(bad)")
        }
    }

    @Test func hugeNegativeSchemaVersionIsPreLifeproj() throws {
        let value = try JSONParser.parse(#"{"meta":{"schema_version":-99999999999999999999}}"#).value
        #expect(CatalogLevel.classify(value.objectValue!) == .preLifeproj)
    }

    @Test func unreadableShelfIsNeverOverwritten() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-rr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let store = ShelfStore(supportDirectory: support)
        try Data("{not the shape".utf8).write(to: store.file)
        #expect(throws: ShelfStore.Unreadable.self) { try store.add(support) }
        #expect(try String(contentsOf: store.file, encoding: .utf8) == "{not the shape")
    }

    @Test func duplicateItemIDsAreReportedAtV1() throws {
        let teka = Teka.read(try folder(#"{"meta":{"schema_version":1},"open_items":[{"id":"a"},{"id":"a"}]}"#))
        #expect(teka.reasons.contains { $0.contains("duplicate ids in open_items") })
    }
}

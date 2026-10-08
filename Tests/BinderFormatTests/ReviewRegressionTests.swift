@testable import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

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

    @Test func farFutureTimestampDoesNotCrash() throws {
        let entry = LogEntry(raw: try JSONParser.parse(#"{"id":"x","closed_at":"9999-12-31T23:00:00-12:00"}"#).value)
        #expect(entry.closingDate(timeZone: utc, today: today) == nil)
        #expect(CalendarDate(Date(timeIntervalSince1970: -62_200_000_000), in: utc) == nil)   // before year 1
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

    @Test func hugeNegativeSchemaVersionIsPreLifeproj() throws {
        let value = try JSONParser.parse(#"{"meta":{"schema_version":-99999999999999999999}}"#).value
        #expect(CatalogLevel.classify(value.objectValue!) == .preLifeproj)
    }

    @Test func duplicateItemIDsAreReportedAtV1() throws {
        let teka = Teka.read(try folder(#"{"meta":{"schema_version":1},"open_items":[{"id":"a"},{"id":"a"}]}"#))
        #expect(teka.reasons.contains { $0.contains("duplicate ids in open_items") })
    }
}

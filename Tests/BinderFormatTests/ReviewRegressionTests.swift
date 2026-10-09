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

/// One test per confirmed finding of the binder-format layer review: ids that leave their code span, special files
/// and unreadable op logs, ids compared by scalars, and the v0 types of `waiting_on` and `recurrence`. Invented data only.
@Suite(.serialized) struct BinderFormatReviewTests {
    func folder(_ catalog: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bf-\(UUID().uuidString)/estate-example")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        try Data(catalog.utf8).write(to: folder.appendingPathComponent("catalog.json"))
        return folder
    }

    let v0 = #"{"meta": {"schema_version": 2, "name": "estate-example", "format": "teka", "format_version": "0", "disclosure": "none"}, "documents": [], "open_items": [], "processing_log": []}"#
    let opLine = Data("{\"op\":\"import_snapshot\"}\n".utf8)

    func check(_ item: String, log: [String] = []) throws -> [RuleFinding.Code] {
        ItemRules.check(items: [try JSONParser.parse(item).value], log: try log.map { try JSONParser.parse($0).value }, v0: true).map(\.code)
    }

    // MARK: - 1. An id never leaves its code span

    @Test func idsWithLineBreaksStayOnOneLine() throws {
        let image = "x\n\n![x](https://tracker.example/p.png)\n\nx"
        #expect(Dashboard.codeSpan(image) == "`x  ![x](https://tracker.example/p.png)  x`")
        #expect(Dashboard.codeSpan("a\t\u{202E}b\r\u{07}") == "`a b `")
        #expect(Dashboard.codeSpan("a`\u{301}b") == "``a`\u{301}b``")

        let catalog = try JSONParser.parse("""
        {"meta": {"name": "estate-example"}, "documents": [], "processing_log": [],
         "open_items": [{"id": "a\\n## Notes\\nb", "title": "Call the notary", "status": "open", "priority": "normal", "no_deadline": true},
                        {"id": "x\\n\\n![x](https://tracker.example/p.png)\\n\\nx", "title": "t", "status": "open", "priority": "normal", "no_deadline": true}]}
        """).value.objectValue!
        let text = Dashboard.render(catalog: catalog, folderName: "estate-example", today: today, timeZone: utc,
                                    hasManual: false, notes: nil, impl: "sprava/test")
        #expect(text.components(separatedBy: "\n").filter { $0 == Dashboard.notesLine }.count == 1)
        #expect(!text.contains("\n![x]"))
        #expect(!Dashboard.editedOutsideNotes(text))
        #expect(Dashboard.split(text).1 == "\(Dashboard.notesLine)\n\n")
    }

    // MARK: - 2. Special files never block a read

    @Test func aFIFOOpLogNeitherBlocksNorCountsAsAbsent() throws {
        let f = try folder(v0)
        #expect(mkfifo(f.appendingPathComponent(".sprava/ops.ndjson").path, 0o600) == 0)
        let teka = Teka.read(f)
        #expect(teka.reasons.contains(".sprava/ops.ndjson is not a regular file"))
        #expect(teka.isAdopted && teka.writesBlocked)

        let fifo = f.appendingPathComponent("letter.pdf")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(DocumentPaths.sha256(of: fifo) == nil)
    }

    @Test func aFIFOCatalogIsNeverOpenedForReading() throws {
        let f = try folder(v0)
        try FileManager.default.removeItem(at: f.appendingPathComponent("catalog.json"))
        #expect(mkfifo(f.appendingPathComponent("catalog.json").path, 0o600) == 0)
        #expect(Teka.read(f).writesBlocked)
        #expect(Teka.readRegular("catalog.json", in: f) == nil)
    }

    @Test func theOpLogIsNeverReadThroughALink() throws {
        let f = try folder(v0)
        let elsewhere = f.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try opLine.write(to: elsewhere.appendingPathComponent("ops.ndjson"))

        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent(".sprava/ops.ndjson"),
                                                   withDestinationURL: elsewhere.appendingPathComponent("ops.ndjson"))
        let a = Teka.read(f)
        #expect(a.reasons.contains(".sprava/ops.ndjson is a symbolic link"))
        #expect(a.writesBlocked)

        try FileManager.default.removeItem(at: f.appendingPathComponent(".sprava"))
        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent(".sprava"), withDestinationURL: elsewhere)
        #expect(Teka.opLog(in: f) == .notRegular(symlink: true))
        let b = Teka.read(f)
        #expect(b.reasons.contains(".sprava is a symbolic link"))
        #expect(!b.reasons.contains { $0.hasPrefix(".sprava/ops.ndjson") })
        #expect(b.writesBlocked)
    }

    // MARK: - 3. An unreadable op log is not an absent one

    @Test func anUnreadableOpLogBlocksWrites() throws {
        let f = try folder(v0)
        let log = f.appendingPathComponent(".sprava/ops.ndjson")
        try opLine.write(to: log)
        #expect(Teka.opLog(in: f) == .complete)
        #expect(Teka.read(f).state == .ready)
        #expect(chmod(log.path, 0) == 0)
        defer { chmod(log.path, 0o600) }
        let teka = Teka.read(f)
        #expect(teka.reasons.contains(".sprava/ops.ndjson unreadable"))
        #expect(teka.isAdopted && teka.writesBlocked && teka.state == .needsAttention)
    }

    @Test func emptyAndTornLogsAreNotAdopted() throws {
        let f = try folder(v0)
        #expect(Teka.opLog(in: f) == .absent)
        let log = f.appendingPathComponent(".sprava/ops.ndjson")
        try Data().write(to: log)
        #expect(Teka.opLog(in: f) == .incomplete)
        try Data(repeating: 0x7B, count: 200_000).write(to: log)              // one torn line longer than a chunk
        #expect(Teka.opLog(in: f) == .incomplete)
        try (Data("{}\n".utf8) + Data(repeating: 0x7B, count: 200_000)).write(to: log)
        #expect(Teka.opLog(in: f) == .complete)
        #expect(!Teka.read(f).writesBlocked)
    }

    // MARK: - 4. Ids compare by scalars

    @Test func nfcAndNfdIdsAreDifferentIDs() throws {
        #expect(ItemID.string("caf\u{e9}") != ItemID.string("cafe\u{301}"))
        #expect(Set([ItemID.string("caf\u{e9}"), ItemID.string("cafe\u{301}")]).count == 2)
        #expect(ItemID.string("7") != ItemID.integer(7))
        let nfc = #"{"id":"café","title":"t","status":"open","priority":"normal","no_deadline":true}"#
        let nfd = #"{"id":"café","title":"t","status":"open","priority":"normal","no_deadline":true}"#
        #expect(try check(nfc, log: [#"{"id":"café","action":"done"}"#]).isEmpty)
        let both = try [nfc, nfd].map { try JSONParser.parse($0).value }
        #expect(ItemRules.check(items: both, log: [], v0: true).isEmpty)
    }

    // MARK: - 5. v0 types of waiting_on and recurrence

    @Test func waitingOnMustBeANonEmptyString() throws {
        let base = #""id":"a","title":"t","priority":"normal","due":"2026-11-01""#
        #expect(try check(#"{\#(base),"status":"waiting","waiting_on":7,"follow_up_at":"2026-10-20"}"#) == [.badWaitingOn])
        #expect(try check(#"{\#(base),"status":"open","waiting_on":""}"#) == [.badWaitingOn])
        #expect(try check(#"{\#(base),"status":"waiting","waiting_on":"","follow_up_at":"2026-10-20"}"#) == [.waitingWithoutParty])
        #expect(try check(#"{\#(base),"status":"waiting","waiting_on":"the notary","follow_up_at":"2026-10-20"}"#).isEmpty)
    }

    @Test func recurrenceHasItsShapeAndADue() throws {
        let due = #""id":"a","title":"t","status":"open","priority":"normal","due":"2026-11-14""#
        let none = #""id":"a","title":"t","status":"open","priority":"normal","no_deadline":true"#
        #expect(try check(#"{\#(due),"recurrence":{"freq":"monthly","day":14}}"#).isEmpty)
        #expect(try check(#"{\#(due),"recurrence":{"freq":"monthly","day":14.0,"note":"kept"}}"#).isEmpty)
        #expect(try check(#"{\#(due),"recurrence":{"freq":"yearly","month":7,"day":30}}"#).isEmpty)
        for bad in [#"{"freq":"monthly","day":0}"#, #"{"freq":"monthly","day":32}"#, #"{"freq":"weekly","day":1}"#,
                    #"{"freq":"monthly","day":"14"}"#, #"{"freq":"yearly","day":30}"#, #"{"freq":"yearly","month":13,"day":1}"#,
                    #"{"freq":"monthly","month":0,"day":1}"#, #"{"day":1}"#, #""monthly""#, "[]"] {
            #expect(try check(#"{\#(due),"recurrence":\#(bad)}"#) == [.badRecurrence], "\(bad)")
        }
        #expect(try check(#"{\#(none),"recurrence":{"freq":"monthly","day":0}}"#) == [.badRecurrence, .recurrenceWithoutDue])
        #expect(try check(#"{\#(none),"recurrence":{"freq":"monthly","day":1}}"#) == [.recurrenceWithoutDue])
    }

    // MARK: - 6. Second layer review: catalog size, inaccessible catalogs, document records, empty due

    @Test func anOversizedCatalogIsBlockedWithoutBeingRead() throws {
        let f = try folder(v0)
        let handle = try FileHandle(forWritingTo: f.appendingPathComponent("catalog.json"))
        try handle.truncate(atOffset: UInt64(Teka.maxCatalogBytes) + 1)      // sparse: no real disk or memory used
        try handle.close()
        let teka = Teka.read(f)
        #expect(teka.reasons == [Teka.tooLarge])
        #expect(teka.state == .needsAttention && teka.writesBlocked && teka.catalog == nil)

        let small = try folder(v0)
        try Data("0123456789A".utf8).write(to: small.appendingPathComponent("catalog.json"))
        #expect(Teka.readRegular("catalog.json", in: small, limit: 10) == nil)
        #expect(Teka.readRegular("catalog.json", in: small, limit: 11)?.count == 11)
    }

    @Test func aCatalogThatCannotBeLookedAtIsNotAbsent() throws {
        let f = try folder(v0)
        try opLine.write(to: f.appendingPathComponent(".sprava/ops.ndjson"))
        #expect(chmod(f.path, 0o600) == 0)                                   // no search permission
        defer { chmod(f.path, 0o700) }
        let teka = Teka.read(f)
        #expect(teka.state == .needsAttention && teka.writesBlocked)
        #expect(teka.reasons.contains("catalog.json unreadable"))
        #expect(teka.reasons.contains(".sprava/ops.ndjson unreadable"))
    }

    @Test func stampedDocumentRecordsHaveTheirV0Fields() throws {
        func read(_ documents: String, adopted: Bool = false) throws -> Teka {
            let f = try folder(v0.replacingOccurrences(of: #""documents": []"#, with: #""documents": "# + documents))
            if adopted { try opLine.write(to: f.appendingPathComponent(".sprava/ops.ndjson")) }
            return Teka.read(f)
        }
        let empty = try read("[{}]")
        #expect(empty.state == .needsMigration)
        #expect(empty.findings.map(\.description) == ["documents[0].id: missing-field", "documents[0].title: missing-field",
                                                      "documents[0].path: missing-field"])
        #expect(empty.reasons.contains("3 rule failure(s) in documents"))
        #expect(try read("[{}]", adopted: true).state == .needsAttention)

        let good = #"{"id": "estate-example-doc-2026-001", "title": "Notice of assessment", "path": "documents/notice.pdf", "date": "2026-08-20"}"#
        #expect(try read("[\(good), {\"id\": 7, \"title\": \"Letter\", \"path\": \"chapters/a.pdf\"}]").state == .ready)
        let bad = #"[{"id": true, "title": "a\nb", "path": 7, "date": "20260820"}]"#
        #expect(try read(bad).findings.map(\.code) == [.badID, .badTitle, .badPath, .badDate])
    }

    @Test func anEmptyDueIsAbsentOnlyInALifeprojCatalog() throws {
        let item = #"{"id":"a","title":"t","status":"open","priority":"normal","due":"","no_deadline":true}"#
        #expect(try check(item) == [.badDue])
        #expect(ItemRules.check(items: [try JSONParser.parse(item).value], log: [], v0: false).isEmpty)
    }

    // MARK: - 7. Third layer review: an interrupted expunge, null unknown fields

    @Test func anInterruptedExpungeExposesNothing() throws {
        let f = try folder(v0)
        try opLine.write(to: f.appendingPathComponent(".sprava/ops.ndjson"))
        #expect(Teka.read(f).state == .ready)
        let marker = f.appendingPathComponent(".sprava/expunge-pending")
        try Data().write(to: marker)
        let teka = Teka.read(f)
        #expect(teka.reasons == [Teka.expungeInterrupted])
        #expect(teka.catalog == nil && teka.level == nil && teka.items.isEmpty)
        #expect(teka.isAdopted && teka.writesBlocked && teka.federationBlocked)

        try FileManager.default.removeItem(at: marker)                       // a dangling link is a marker too
        try FileManager.default.createSymbolicLink(atPath: marker.path, withDestinationPath: "nowhere")
        #expect(Teka.read(f).catalog == nil)
        try FileManager.default.removeItem(at: marker)
        #expect(Teka.read(f).state == .ready)
    }

    @Test func aNullUnknownFieldIsKeptAndValid() throws {
        let base = #""id":"a","title":"t","status":"open","priority":"normal","due":"2026-11-01""#
        #expect(try check(#"{\#(base),"legacy_due":null,"x_note":null}"#).isEmpty)
        #expect(try check(#"{\#(base),"link":null,"kind":null}"#) == [.badKind, .nullValue, .nullValue])
        let f = try folder(v0.replacingOccurrences(of: #""open_items": []"#, with: #""open_items": [{\#(base),"legacy_due":null}]"#))
        #expect(Teka.read(f).state == .ready)
    }
}

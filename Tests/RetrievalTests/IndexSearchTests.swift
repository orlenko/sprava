import BinderFormat
import Foundation
import SQLite3
import Testing
@testable import Retrieval

@Suite struct IndexSearchTests {
    @Test func searchFindsThePageAndSpanOfAClause() throws {
        #expect(sqlite3_compileoption_used("ENABLE_FTS5") == 1, "the system SQLite has FTS5")
        let hit = try #require(try IndexFixture().rebuild().search("pet dog consent", limit: 3).hits.first)
        #expect(hit.passage.source == .document(bylawsID) && hit.passage.page == 2 && hit.passage.revision == "bylaws-1")
        #expect(!hit.passage.isTranslation && hit.original == nil)
        guard case .read(let page, _) = IndexFixture.bylaws.pages[1].page else { Issue.record("fixture"); return }
        #expect(String(String.UnicodeScalarView(Array(page.unicodeScalars)[hit.passage.span])) == hit.passage.text)
        #expect(hit.passage.text.contains("one cat or one dog under 15 kg"))
    }

    @Test func aTranslationIsKeptBesideItsOriginalAndPointsBack() throws {
        let index = try IndexFixture().rebuild()
        let original = try #require(try index.passages(of: letterID).first)
        let id = try index.addTranslation(of: original.id, text: "Pets are allowed with the written consent of the board.",
                                          language: "en", translator: "apple-translation")
        let translated = try #require(try index.search("pets allowed", limit: 5).hits.first { $0.passage.id == id })
        #expect(translated.passage.isTranslation && translated.passage.translator == "apple-translation")
        #expect(translated.original == original)
        #expect(translated.passage.source == .document(letterID) && translated.passage.page == 1)
        // The original stays the record, found in its own language.
        #expect(try index.search("animaux", limit: 5).hits.first?.passage == original)
        #expect(throws: BinderIndex.Failure.self) { try index.addTranslation(of: id, text: "x", language: "de", translator: "t") }
        #expect(try index.coverage().translationLanguages == ["en"])
    }

    @Test func aFailedPageShowsInCoverage() throws {
        let coverage = try IndexFixture().rebuild().coverage()
        let bylaws = try #require(coverage.documents.first { $0.document == bylawsID.description })
        #expect(bylaws.pagesRead == [1, 2] && bylaws.pagesFailed == [.init(page: 3, reason: "could not be read by OCR")])
        #expect(!bylaws.isComplete)
        let letter = try #require(coverage.documents.first { $0.document == letterID.description })
        #expect(letter.pagesFromOCR == [1] && letter.isComplete)
        #expect(coverage.gaps.map(\.document) == [bylawsID.description])
    }

    @Test func anEmptyResultReportsCoverageNotAbsence() throws {
        let f = try IndexFixture(extraDocuments: #", {"id": "condo-example-doc-2026-004", "title": "Minutes", "path": "minutes/agm.pdf"}"#)
        let index = try f.rebuild()
        try f.edit("\"minutes/agm.pdf\"}", "\"minutes/agm.pdf\"}, {\"id\": \"condo-example-doc-2026-005\", \"title\": \"Notice\", \"path\": \"n.pdf\"}")
        let result = try index.search("swimming pool hours", teka: f.teka)
        let c = result.coverage
        #expect(result.hits.isEmpty && c.documents.count == 4 && c.languages == ["en", "fr"])
        #expect(c.openItems == 1 && c.closedItems == 1 && c.logEntries == 1 && !c.conversation)
        #expect(c.gaps.map(\.document) == [bylawsID.description, "condo-example-doc-2026-004"])
        #expect(c.gaps.last?.notIndexed == "the file cannot be read now")
        #expect(c.notYetIndexed == ["condo-example-doc-2026-005"] && !c.isExhaustive)
        // Without the catalog, what is not indexed yet is unknown, so the search is never exhaustive.
        #expect(try !index.search("pets").coverage.isExhaustive)
    }

    @Test func aCompleteIndexIsExhaustive() throws {
        var f = try IndexFixture()
        f.reader.texts["governance/bylaws.pdf"]?.pages.removeLast()
        #expect(try f.rebuild().search("swimming pool", teka: f.teka).coverage.isExhaustive)
    }

    @Test func itemsAndLogEntriesAreFound() throws {
        let index = try IndexFixture().rebuild()
        #expect(try index.search("parking permit").hits.first?.passage.source == .openItem(.string("condo-example-2026-001")))
        #expect(try index.search("assessment").hits.first?.passage.source == .closedItem(.string("condo-example-2026-000")))
        #expect(try index.search("filed water").hits.contains { $0.passage.source == .log("#1") })
    }

    @Test func thePersonsLinesAreSearchedOnlyWhenAskedFor() throws {
        let f = try IndexFixture()
        let index = try f.rebuild()
        try index.index(personLine: "line-1", text: "The plumber said he would come back on Thursday.")
        #expect(try index.search("plumber").hits.isEmpty)
        #expect(try index.search("plumber", conversation: true).hits.first?.passage.source == .personLine("line-1"))
        // A refresh keeps them: no transcript reader replaces them yet.
        try index.refresh(teka: f.teka, reader: f.reader)
        #expect(try index.search("plumber", conversation: true).hits.count == 1)
    }

    @Test func queryTextIsNeverFTS5Syntax() throws {
        let index = try IndexFixture().rebuild()
        for query in ["\"NEAR(pets", "pets* OR", "text:pets", "-", "", "AND OR NOT"] { _ = try index.search(query) }
        #expect(BinderIndex.match("l'animal, NEAR(dog)") == "\"l\" OR \"animal\" OR \"NEAR\" OR \"dog\"")
        #expect(BinderIndex.match(" ;; ") == nil)
        // A huge query is read only up to its bounds.
        let huge = (0..<200_000).map { "w\($0)" }.joined(separator: " ") + String(repeating: "x", count: 100_000)
        #expect(BinderIndex.match(huge)?.components(separatedBy: " OR ").count == BinderIndex.maxQueryTerms)
    }

    @Test func passagesAreBoundedAndTheirSpansPointIntoTheText() {
        let text = (1...700).map { "word\($0)" }.joined(separator: " \n")
        let cuts = BinderIndex.cut(text, page: 4)
        #expect(cuts.count == 3)
        for cut in cuts {
            #expect(cut.page == 4 && String(String.UnicodeScalarView(Array(text.unicodeScalars)[cut.span])) == cut.text)
            #expect(cut.text.split(whereSeparator: \.isWhitespace).count <= BinderIndex.passageWords)
        }
        let long = String(repeating: "x", count: BinderIndex.maxPassageScalars * 2 + 5)
        #expect(BinderIndex.cut(long, page: nil).map(\.span.count) == [BinderIndex.maxPassageScalars, BinderIndex.maxPassageScalars, 5])
    }
}

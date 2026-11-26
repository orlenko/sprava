import Foundation
import Testing
@testable import Retrieval

@Suite struct PersonPageIndexTests {
    @Test func rebuildingAndEditingUseThePersonsWordsOnlyForTheirPageRevision() throws {
        var fixture = try IndexFixture()
        defer { try? FileManager.default.removeItem(at: fixture.binder.deletingLastPathComponent()) }
        let path = "governance/bylaws.pdf"
        let digest = String(repeating: "a", count: 64)
        fixture.reader.texts[path]?.revision = digest
        let index = try fixture.rebuild()
        let original = #""title": "Bylaws""#
        try fixture.edit(original, original + #", "person_page_readings":[{"revision":""# + digest + #"","page":3,"text":"Moonflower trays are counted at dusk."}]"#)
        try index.refresh(teka: fixture.teka, reader: fixture.reader)
        func check(_ current: BinderIndex) throws {
            let result = try current.search("moonflower")
            let passage = try #require(result.hits.first?.passage)
            #expect(passage.source == .document(bylawsID) && passage.page == 3 && passage.revision == digest)
            #expect(passage.text == "Person’s reading: Moonflower trays are counted at dusk.")
            let coverage = try #require(result.coverage.documents.first { $0.document == bylawsID.description })
            #expect(coverage.isComplete && coverage.pagesWithPersonText == [3])
        }
        try check(index)
        let rebuilt = try fixture.rebuild()
        try check(rebuilt)
        fixture.reader.texts[path]?.revision = String(repeating: "b", count: 64)
        try rebuilt.refresh(teka: fixture.teka, reader: fixture.reader)
        #expect(try rebuilt.search("moonflower").hits.isEmpty)
        fixture.reader.texts[path]?.revision = digest
        try fixture.edit("Moonflower trays are counted at dusk.", "")
        try rebuilt.refresh(teka: fixture.teka, reader: fixture.reader)
        let result = try rebuilt.search("moonflower")
        #expect(result.hits.isEmpty)
        let coverage = try #require(result.coverage.documents.first { $0.document == bylawsID.description })
        #expect(!coverage.isComplete && coverage.pagesCheckedByPerson == [3] && coverage.pagesIllegible == [3])
    }
}

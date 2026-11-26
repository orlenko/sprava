import PDFKit
import Testing
@testable import Extract

@Suite struct PageReadingsTests {
    @Test func mixedPDFKeepsPageOrderBlankPagesAndRecognitionConfidence() throws {
        let document = PDFDocument()
        for (index, page) in [
            Fixtures.pdf(["Invented greenhouse inventory"], scanned: false),
            Fixtures.pdf([], scanned: false),
            Fixtures.pdf(["WATER THE SEEDLINGS"], scanned: true)
        ].enumerated() {
            document.insert(try #require(PDFDocument(data: page)?.page(at: 0)), at: index)
        }
        let bytes = try #require(document.dataRepresentation())
        let result = Extractor.extract(bytes, name: "greenhouse.pdf")
        try #require(result.problem == nil && result.pageReadings.count == 3)
        let pages = result.pageReadings
        #expect(pages.map(\.method) == [.textLayer, .ocr, .ocr])
        #expect(pages[0].text.contains("inventory") && pages[0].confidence == nil)
        let area = try #require(pages[0].area)
        #expect(area == 484_704.0)
        #expect(pages[1].text.isEmpty && pages[1].confidence == nil)
        #expect(pages[2].text.uppercased().contains("SEEDLINGS"))
        #expect((0...1).contains(try #require(pages[2].confidence)))
        #expect(pages.compactMap { Extractor.Page(json: $0.json) } == pages)

        var limits = Extractor.Limits()
        limits.textChars = 8
        let held = Extractor.extract(bytes, name: "greenhouse.pdf", limits: limits)
        #expect(held.problem != nil && held.text.count <= 8 && held.pageReadings.isEmpty)
    }
}

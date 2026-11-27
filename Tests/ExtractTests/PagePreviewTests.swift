import CryptoKit
import Foundation
import PDFKit
import Testing
@testable import Extract

@Suite struct PagePreviewTests {
    @Test func visibleAnnotationsAreIncludedInRotatedPreviews() throws {
        let pdf = try #require(PDFDocument(data: Fixtures.pdf([], scanned: false)))
        let page = try #require(pdf.page(at: 0))
        let note = PDFAnnotation(bounds: CGRect(x: 48, y: 400, width: 300, height: 80), forType: .freeText, withProperties: nil)
        note.contents = "Invented reading note"
        note.font = .systemFont(ofSize: 22)
        note.fontColor = .black
        note.color = .white
        page.addAnnotation(note)
        page.rotation = 90
        let data = try #require(pdf.dataRepresentation())
        let image = try #require(PagePreview.render(data, name: "garden.pdf", number: 1))
        #expect(image.width == PagePreview.maxSide && image.height < image.width)
        #expect(stride(from: 0, to: image.pixels.count, by: 4).contains { image.pixels[$0] < 64 })
    }

    @Test func previewReturnsOnlyTheRequestedPageAsBoundedPixels() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("garden.pdf")
        let data = Fixtures.pdf(["Invented greenhouse notes"], scanned: false)
        try data.write(to: file)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let image = try ExtractHelper.pagePreview(file: file, under: root, number: 1, reader: .inProcess, expectedDigest: digest)
        #expect(image.height == PagePreview.maxSide && image.width < image.height)
        // The source text starts 60 points from the left edge. At full size it stays at that relative position.
        let leftInk = stride(from: 0, to: image.pixels.count, by: 4).lazy
            .filter { image.pixels[$0] < 100 }.map { ($0 / 4) % image.width }.min()
        let x = try #require(leftInk)
        #expect((110...135).contains(x))
        for name in ["private-key.pem", ".env", "token.json"] {
            let secret = root.appendingPathComponent(name)
            try data.write(to: secret)
            #expect(throws: ExtractHelper.Failure.self) {
                try ExtractHelper.pagePreview(file: secret, under: root, number: 1, reader: .inProcess, expectedDigest: digest)
            }
        }
        #expect(PagePreview(wire: image.wire)?.pixels == image.pixels)
        #expect(throws: ExtractHelper.Failure.self) {
            try ExtractHelper.pagePreview(file: file, under: root, number: 1, reader: .inProcess, expectedDigest: "old")
        }
        #expect(PagePreview(wire: Data([255, 255, 255, 255])) == nil)
        #expect(throws: ExtractHelper.Failure.self) {
            try ExtractHelper.pagePreview(file: file, under: root, number: 2, reader: .inProcess, expectedDigest: digest)
        }
    }
}

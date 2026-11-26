import AppKit
import CoreImage
import CoreText
import Testing
@testable import Extract

@Suite struct PageGradeTests {
    @Test func aSharpHeadingDoesNotCertifyABlurredBody() throws {
        let heading = Fixtures.textImage(["Garden plan"], width: 1200, height: 150)
        let lines = (1...13).map { "Water the invented garden bed number " + String($0) }
        let body = Fixtures.textImage(lines, width: 1200, height: 1020)
        let source = CIImage(cgImage: body)
        let blurred = source.clampedToExtent().applyingGaussianBlur(sigma: 12).cropped(to: source.extent)
        let bodyImage = try #require(CIContext().createCGImage(blurred, from: source.extent))
        let ctx = try #require(CGContext(data: nil, width: 1200, height: 1170, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.draw(heading, in: CGRect(x: 0, y: 1020, width: 1200, height: 150))
        ctx.draw(bodyImage, in: CGRect(x: 0, y: 0, width: 1200, height: 1020))
        let image = try #require(ctx.makeImage())
        let reading = Extractor.extract(Fixtures.png(image), name: "beds.png")
        #expect(reading.text.localizedCaseInsensitiveContains("garden"))
        #expect(reading.pageReadings.map(\.grade) == [.poor])
        let clear = Extractor.extract(Fixtures.png(body), name: "clear.png")
        #expect(clear.pageReadings.map(\.grade) == [.good])
    }

    @Test func aStampOnAScanDoesNotHideTheBody() {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(consumer: CGDataConsumer(data: bytes as CFMutableData)!, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        pdf.draw(Fixtures.textImage(["Greenhouse doors open at noon", "Water the seedlings before sunset"]),
                 in: CGRect(x: 15, y: 200, width: 580, height: 280))
        let stamp = "Invented greenhouse archive reference for the coming spring season"
        pdf.textPosition = CGPoint(x: 30, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: stamp, attributes: [.font: NSFont.systemFont(ofSize: 14)])), pdf)
        pdf.endPDFPage()
        pdf.closePDF()
        let reading = Extractor.extract(bytes as Data, name: "archive.pdf")
        #expect(reading.text.localizedCaseInsensitiveContains("seedlings"))
        #expect(reading.text.localizedCaseInsensitiveContains("archive"))
        #expect(reading.pageReadings.first?.method == .ocr)
    }

    @Test func blankAttachmentKeepsItsOwnGradeWhenStored() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let mail = root.appendingPathComponent("garden.eml")
        try Data("From: grower@example.org\r\nSubject: Seeds\r\n\r\nSee the garden plan.".utf8).write(to: mail)
        let plan = root.appendingPathComponent("plan.pdf")
        try Fixtures.pdf([], scanned: true).write(to: plan)
        let reading = IntakeReading.read(mail, in: root, attachments: [plan], channel: "email", reader: .inProcess)
        #expect(reading.pageGrades.isEmpty)
        #expect(Array(reading.attachmentPageGrades.values) == [[.unreadable]])
        #expect(reading.notes.contains { $0.contains("plan.pdf") && $0.contains("1") })
        #expect(IntakeReading(json: .object(reading.json)) == reading)
    }

    @Test func sparseLayersWeakOCRAndEmptyPagesKeepDistinctGrades() {
        typealias Page = Extractor.Page
        #expect(Page(text: "Invented title", method: .textLayer, confidence: nil, area: 480_000).grade == .poor)
        #expect(Page(text: "Invented title", method: .textLayer, confidence: nil, area: 8_000).grade == .good)
        #expect(Page(text: "Oak", method: .ocr, confidence: 0.69).grade == .poor)
        #expect(Page(text: "Oak", method: .ocr, confidence: 0.70).grade == .good)
        #expect(Page(text: "", method: .ocr, confidence: nil).grade == .unreadable)
        for method in [Page.Method.ocr, .textLayer] {
            let confidence: Double? = method == .ocr ? 1 : nil
            #expect(Page(text: String(repeating: "x", count: 39), method: method, confidence: confidence, area: 480_000).grade == .poor)
            #expect(Page(text: String(repeating: "x", count: 40), method: method, confidence: confidence, area: 480_000).grade == .good)
        }
        var reading = IntakeReading(kind: "pdf", textFrom: "ocr", pages: 3, text: "Greenhouse", channel: "other")
        reading.pageGrades = [.good, .poor, .unreadable]
        #expect(IntakeReading(json: .object(reading.json))?.pageGrades == reading.pageGrades)
    }
}

import AppKit
import CoreImage
import CoreText
import Testing
@testable import Extract

@Suite(.serialized) struct PageGradeTests {
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

    @Test func paleUnrecognizedWritingBelowDarkTextNeedsInspection() throws {
        let first = Fixtures.textImage(["Orchard notes", "Count the pears", "Record the rows"], width: 1000, height: 260)
        let second = Fixtures.textImage((1...6).map { "Count invented trees in the orchard row " + String($0) }, width: 1000, height: 440)
        let ctx = try #require(CGContext(data: nil, width: 1000, height: 700, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 1000, height: 700))
        ctx.draw(first, in: CGRect(x: 0, y: 440, width: 1000, height: 260))
        let page = CIImage(cgImage: second)
        let pale = try #require(CIContext().createCGImage(page.clampedToExtent().applyingGaussianBlur(sigma: 5), from: page.extent))
        ctx.setAlpha(0.15)
        ctx.draw(pale, in: CGRect(x: 0, y: 0, width: 1000, height: 440))
        let reading = Extractor.extract(Fixtures.png(try #require(ctx.makeImage())), name: "orchard.png")
        #expect(reading.text.localizedCaseInsensitiveContains("pears"))
        #expect(!reading.text.contains("row 6"))
        #expect(reading.pageReadings.first?.grade == .poor)
    }

    @Test func missingPaleWordsBetweenReadWordsDoNotGetAGoodGrade() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1000, height: 480)
        let columns = ["Orchard", "meadow", "willow", "garden", "maple", "lantern"]
        func layer(pale: Bool) throws -> CGImage {
            let ctx = try #require(CGContext(data: nil, width: 1000, height: 480, bitsPerComponent: 8,
                                             bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            if !pale { ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(bounds) }
            for row in 0..<8 {
                for (col, word) in columns.enumerated() where (col + row).isMultiple(of: 2) == pale {
                    ctx.textPosition = CGPoint(x: 20 + 163 * col, y: 32 + 57 * row)
                    let text = NSAttributedString(string: word, attributes: [.font: NSFont.systemFont(ofSize: 26),
                        .foregroundColor: CGColor(gray: pale ? 0.82 : 0, alpha: 1)])
                    CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
                }
            }
            return try #require(ctx.makeImage())
        }
        let ink = CIImage(cgImage: try layer(pale: true)).applyingGaussianBlur(sigma: 3)
        let combined = ink.composited(over: CIImage(cgImage: try layer(pale: false)))
        let image = try #require(CIContext().createCGImage(combined, from: bounds))
        let reading = Extractor.extract(Fixtures.png(image), name: "orchard-words.png")
        #expect(!reading.text.isEmpty)
        #expect(reading.text.split(whereSeparator: { $0.isWhitespace }).count < 40)
        #expect(reading.pageReadings.first?.grade == .poor)
    }

    @Test(arguments: [false, true]) func aStampOnAScanDoesNotHideTheBody(tiled: Bool) throws {
        let bytes = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = CGContext(consumer: CGDataConsumer(data: bytes as CFMutableData)!, mediaBox: &box, nil)!
        pdf.beginPDFPage(nil)
        let image = Fixtures.textImage(["Greenhouse doors open at noon", "Water the seedlings before sunset"])
        let frame = CGRect(x: 15, y: 200, width: 580, height: 280)
        if tiled {
            for y in stride(from: 0, to: image.height, by: 24) {
                let height = min(24, image.height - y)
                let strip = try #require(image.cropping(to: CGRect(x: 0, y: y, width: image.width, height: height)))
                let scale = frame.height / CGFloat(image.height)
                pdf.draw(strip, in: CGRect(x: frame.minX, y: frame.maxY - CGFloat(y + height) * scale,
                                           width: frame.width, height: CGFloat(height) * scale))
            }
        } else { pdf.draw(image, in: frame) }
        let stamp = String(repeating: "Invented greenhouse archive reference. ", count: tiled ? 2 : 11)
        pdf.textPosition = CGPoint(x: 30, y: 700)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: stamp, attributes: [.font: NSFont.systemFont(ofSize: 2.5)])), pdf)
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

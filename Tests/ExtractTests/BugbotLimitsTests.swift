import Darwin
@testable import Extract
import Foundation
import Testing

/// Regressions from Codex Bugbot's second pass on the Shelf and Extract layer (PR #11): every allocation an intake
/// file drives is bounded before it is made. Each fixture is small and only declares the large thing; nothing large
/// is ever allocated here. Invented data only.
@Suite(.serialized) struct BugbotLimitsTests {
    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-limits06-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Pictures: the declared size is checked before decoding

    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc ^= UInt32(b)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }

    static func be32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }

    static func chunk(_ type: String, _ body: Data) -> Data {
        let typed = Data(type.utf8) + body
        return be32(UInt32(body.count)) + typed + be32(crc32(typed))
    }

    /// A PNG of a few dozen bytes whose header declares `width` by `height` grey pixels.
    static func png(width: UInt32, height: UInt32) -> Data {
        var ihdr = be32(width) + be32(height)
        ihdr += Data([8, 0, 0, 0, 0])   // 8-bit grey, deflate, adaptive filter, no interlace
        let idat = Data([0x78, 0x9C, 0x63, 0x00, 0x00, 0x00, 0x01, 0x00, 0x01])   // one zlib-compressed zero byte
        return Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + chunk("IHDR", ihdr) + chunk("IDAT", idat) + chunk("IEND", Data())
    }

    @Test func aPictureDeclaringTooManyPixelsIsHeldBeforeDecoding() {
        let bomb = Extractor.extract(Self.png(width: 20_000, height: 20_000), name: "photo.png")
        #expect(bomb.kind == "image")
        #expect(bomb.problem?.contains("pixel limit") == true, "\(String(describing: bomb.problem))")
        // The limit is what decides: an ordinary picture is held only when the limit is set below its size.
        var tight = Extractor.Limits()
        tight.pixels = 100_000
        let photo = Fixtures.png(Fixtures.textImage(["Invented receipt"]))
        #expect(Extractor.extract(photo, name: "photo.png", limits: tight).problem?.contains("pixel limit") == true)
        #expect(Extractor.extract(photo, name: "photo.png").problem == nil)
    }

    // MARK: - PDF pages: an image the page draws is checked before drawing

    enum Route: CaseIterable { case page, form, annotation, inline, inlineInForm }

    /// A one-page PDF with no text layer whose page draws an image declared at `width` by `height`: from its own
    /// resources, through a form, or in an annotation's appearance. Offsets are computed, so it opens without repair.
    static func pdfDrawing(width: Int, height: Int, via route: Route) -> Data {
        let image = "<< /Type /XObject /Subtype /Image /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 1 >>\nstream\nx\nendstream"
        func stream(_ dict: String, _ content: String) -> String { "<< \(dict) /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream" }
        let form = stream("/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Resources << /XObject << /Im1 6 0 R >> >>", "/Im1 Do")
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>"]
        switch route {
        case .page:
            objects += ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /X1 5 0 R >> >> /Contents 4 0 R >>",
                        stream("", "q 612 0 0 792 0 0 cm /X1 Do Q"), image]
        case .form:
            objects += ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /X1 5 0 R >> >> /Contents 4 0 R >>",
                        stream("", "q 612 0 0 792 0 0 cm /X1 Do Q"), form, image]
        case .annotation:
            objects += ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [7 0 R] /Contents 4 0 R >>",
                        stream("", ""), form, image, "<< /Type /Annot /Subtype /Stamp /Rect [0 0 612 792] /AP << /N 5 0 R >> >>"]
        case .inline:
            objects += ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
                        stream("", "q 612 0 0 792 0 0 cm BI /W \(width) /H \(height) /CS /G /BPC 8 ID x EI Q")]
        case .inlineInForm:
            objects += ["<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /X1 5 0 R >> >> /Contents 4 0 R >>",
                        stream("", "q 612 0 0 792 0 0 cm /X1 Do Q"),
                        stream("/Type /XObject /Subtype /Form /BBox [0 0 1 1]", "BI /Width \(width) /Height \(height) /ColorSpace /DeviceGray /BitsPerComponent 8 ID x EI")]
        }
        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (i, body) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(body)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { pdf += String(format: "%010d 00000 n \n", o) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(pdf.utf8)
    }

    @Test func aPDFPageDrawingAHugePictureIsHeldBeforeDrawing() {
        for route in Route.allCases {
            let r = Extractor.extract(Self.pdfDrawing(width: 20_000, height: 20_000, via: route), name: "scan.pdf")
            #expect(r.pages == 1)
            #expect(r.problem?.contains("larger than the pixel limit") == true, "\(route): \(String(describing: r.problem))")
            // A picture of an ordinary size drawn the same way is drawn and read.
            let small = Extractor.extract(Self.pdfDrawing(width: 40, height: 40, via: route), name: "scan.pdf")
            #expect(small.problem == nil, "\(route): \(String(describing: small.problem))")
        }
    }

    // MARK: - Archives: one budget for everything unpacked

    @Test func anArchiveUnpackingPastTheBudgetIsHeld() {
        let row = String(repeating: "<row><c t=\"inlineStr\"><is><t>Invented levy 85.00</t></is></c></row>", count: 10)
        let sheet = "<worksheet><sheetData>\(row)</sheetData></worksheet>"
        let files = [("xl/workbook.xml", "<workbook/>")] + (1...4).map { ("xl/worksheets/sheet\($0).xml", sheet) }
        let zip = LayerReview3Tests.storedZip(files)
        var tight = Extractor.Limits()
        tight.unpacked = sheet.utf8.count * 2   // two sheets fit, four do not
        let r = Extractor.extract(zip, name: "ledger.xlsx", limits: tight)
        #expect(r.problem?.contains("unpacks to more than the size limit") == true, "\(String(describing: r.problem))")
        #expect(r.text.isEmpty)
        let whole = Extractor.extract(zip, name: "ledger.xlsx")
        #expect(whole.problem == nil)
        #expect(whole.text.contains("Invented levy 85.00"))
    }

    // MARK: - Messages: a part limit, and splitting that does not multiply the body

    @Test func aMessagePastThePartLimitIsHeld() {
        let parts = (1...5).map { "--P\nContent-Type: application/octet-stream\nContent-Disposition: attachment; filename=\"part\($0).bin\"\n\nx\n" }
        let eml = "From: office@example.com\nSubject: Invented parts\nContent-Type: multipart/mixed; boundary=\"P\"\n\n" + parts.joined() + "--P--\n"
        var tight = Extractor.Limits()
        tight.parts = 3
        let r = Extractor.extract(Data(eml.utf8), name: "parts.eml", limits: tight)
        #expect(r.problem?.contains("more than 3 parts") == true, "\(String(describing: r.problem))")
        #expect((r.email?.attachments.count ?? 0) <= 3)
        let whole = Extractor.extract(Data(eml.utf8), name: "parts.eml")
        #expect(whole.problem == nil)
        #expect(whole.email?.attachments.map(\.name) == (1...5).map { "part\($0).bin" })
    }

    @Test func separatorsAfterTheFirstStayInTheBody() {
        let md = "---\nsubject: Invented minutes\nfrom: clerk@example.com\n---\nFirst item\n---\nSecond item"
        #expect(Extractor.extract(Data(md.utf8), name: "minutes.md").text == "First item\n---\nSecond item")
        let eml = "From: clerk@example.com\nSubject: Invented minutes\n\nFirst item\n\nSecond item"
        #expect(Extractor.extract(Data(eml.utf8), name: "minutes.eml").text == "First item\n\nSecond item")
    }

    // MARK: - The text cap holds for a message and its attachments together

    @Test func aMessageWithItsAttachmentsKeepsToTheTextCap() throws {
        let dir = temp("combined")
        let message = dir.appendingPathComponent("message.eml")
        try Data("From: office@example.com\nSubject: Invented papers\n\n\(String(repeating: "m", count: 100))\n".utf8).write(to: message)
        let files = try (1...3).map { i -> URL in
            let url = dir.appendingPathComponent("note\(i).txt")
            try Data(String(repeating: "\(i)", count: 150).utf8).write(to: url)
            return url
        }
        var tight = Extractor.Limits()
        tight.textChars = 300
        let r = IntakeReading.read(message, in: dir, attachments: files, channel: "email", reader: .inProcess, limits: tight)
        #expect(r.text.unicodeScalars.count <= 300)
        #expect(r.held?.contains("text limit") == true, "\(String(describing: r.held))")
        #expect(r.notes.contains { $0.contains("note3.txt") && $0.contains("reached the text limit") }, "\(r.notes)")
        #expect(r.attachments == ["note1.txt", "note2.txt", "note3.txt"])
        let whole = IntakeReading.read(message, in: dir, attachments: files, channel: "email", reader: .inProcess)
        #expect(whole.held == nil)
        #expect(whole.text.contains(String(repeating: "3", count: 150)))
    }

    // MARK: - The reader's answer is read up to a bound

    @Test func aHelperAnsweringPastTheBoundFails() {
        // `yes` stands in for a helper that writes without end; the bound is set small so nothing large is read.
        let start = Date()
        let error = #expect(throws: ExtractHelper.Failure.self) {
            try ExtractHelper.launch(URL(fileURLWithPath: "/usr/bin/yes"), data: Data("x".utf8), name: "invented", timeout: 30, maxAnswer: 1 << 20)
        }
        #expect(error?.message.contains("larger than the limit") == true, "\(String(describing: error))")
        #expect(Date().timeIntervalSince(start) < 20)
    }
}

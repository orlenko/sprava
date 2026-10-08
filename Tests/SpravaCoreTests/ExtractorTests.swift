import AppKit
import CoreText
import Foundation
import Testing
@testable import SpravaCore

/// Fixtures made on the fly, with invented text.
enum Fixtures {
    static func textImage(_ lines: [String], width: Int = 1400, height: Int = 600) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("Helvetica" as CFString, 44, nil)
        for (i, line) in lines.enumerated() {
            let attr = NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: CGColor(gray: 0, alpha: 1)])
            ctx.textPosition = CGPoint(x: 40, y: CGFloat(height - 80 - i * 70))
            CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        }
        return ctx.makeImage()!
    }

    static func png(_ image: CGImage) -> Data {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
    }

    /// A one-page PDF: with a text layer, or holding only an image of the text (a scan).
    static func pdf(_ lines: [String], scanned: Bool) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        ctx.beginPDFPage(nil)
        if scanned {
            ctx.draw(textImage(lines), in: CGRect(x: 20, y: 400, width: 572, height: 245))
        } else {
            let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            for (i, line) in lines.enumerated() {
                ctx.textPosition = CGPoint(x: 60, y: 720 - CGFloat(i) * 22)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font])), ctx)
            }
        }
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// A zip made with the system's zip tool, from (path, contents) pairs.
    static func zip(_ files: [(String, String)]) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-zip-\(UUID().uuidString)")
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        let out = dir.appendingPathComponent("out.zip")
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        task.currentDirectoryURL = dir
        task.arguments = ["-q", "-r", out.path] + files.map(\.0)
        try task.run()
        task.waitUntilExit()
        return try Data(contentsOf: out)
    }
}

@Suite struct ExtractorTests {
    @Test func aPDFTextLayerIsReadOnEveryPage() {
        let r = Extractor.extract(Fixtures.pdf(["Notice of assessment for the invented year", "Balance owing: 1,234.56 dollars"], scanned: false), name: "notice.pdf")
        #expect(r.kind == "pdf" && r.textFrom == "text-layer" && r.pages == 1)
        #expect(r.text.contains("Notice of assessment") && r.text.contains("1,234.56"))
    }

    @Test func aScannedPDFAndAnImageAreReadByOCR() {
        let scanned = Extractor.extract(Fixtures.pdf(["INVOICE 2026-117", "Total due by October 30"], scanned: true), name: "scan.pdf")
        #expect(scanned.textFrom == "ocr")
        #expect(scanned.text.uppercased().contains("INVOICE"), "\(scanned.text)")
        let photo = Extractor.extract(Fixtures.png(Fixtures.textImage(["Pay the plumber 625 dollars"])), name: "photo.png")
        #expect(photo.kind == "image" && photo.text.lowercased().contains("plumber"), "\(photo.text)")
    }

    @Test func officeDocumentsAreReadFromTheirXML() throws {
        let docx = try Fixtures.zip([
            ("[Content_Types].xml", "<Types/>"),
            ("word/document.xml", #"<w:document><w:body><w:p><w:r><w:t>Minutes of the invented board meeting</w:t></w:r></w:p><w:p><w:r><w:t xml:space="preserve">Budget &amp; repairs </w:t></w:r><w:r><w:t>approved</w:t></w:r></w:p></w:body></w:document>"#),
        ])
        let r = Extractor.extract(docx, name: "minutes.docx")
        #expect(r.kind == "document" && r.text == "Minutes of the invented board meeting\nBudget & repairs approved", "\(r.text)")
        let xlsx = try Fixtures.zip([
            ("xl/workbook.xml", "<workbook/>"),
            ("xl/sharedStrings.xml", "<sst><si><t>Item</t></si><si><t>Amount</t></si><si><t>Roof repair</t></si></sst>"),
            ("xl/worksheets/sheet1.xml", #"<worksheet><sheetData><row><c t="s"><v>0</v></c><c t="s"><v>1</v></c></row><row><c t="s"><v>2</v></c><c><v>4200</v></c></row></sheetData></worksheet>"#),
        ])
        #expect(Extractor.extract(xlsx, name: "budget.xlsx").text == "Item\tAmount\nRoof repair\t4200")
    }

    @Test func emailsAreReadWithTheirHeadersAndAttachments() {
        let eml = """
        From: Invented Manager <manager@example.com>
        To: person@example.com
        Subject: =?utf-8?B?SGVhdGVyIHJlcGFpciDigJQgcXVvdGU=?=
        Message-ID: <abc123@example.com>
        Date: Tue, 6 Oct 2026 09:00:00 -0400
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        The repair is booked for Thursday. Please reply by Friday=2E
        --XYZ
        Content-Type: application/pdf; name="quote.pdf"
        Content-Disposition: attachment; filename="quote.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --XYZ--
        """
        let r = Extractor.extract(Data(eml.utf8), name: "message.eml")
        #expect(r.kind == "email")
        #expect(r.email?.subject == "Heater repair — quote")
        #expect(r.email?.messageID == "<abc123@example.com>")
        #expect(r.text.contains("Please reply by Friday."))
        #expect(r.email?.attachments.first?.name == "quote.pdf")
        #expect(r.email?.attachments.first?.data.prefix(4) == Data("%PDF".utf8))

        let md = "---\nsubject: \"Strata levy notice\"\nfrom: \"Invented Council <council@example.com>\"\ndate: \"2026-10-05T10:00:00-04:00\"\nto: \"person@example.com\"\n---\n\n# Strata levy notice\n\nThe levy is due on November 1."
        let m = Extractor.extract(Data(md.utf8), name: "2026-10-05_17_strata-levy-notice.md")
        #expect(m.kind == "email" && m.email?.subject == "Strata levy notice" && m.text.contains("due on November 1"))
    }

    @Test func unreadableAndMislabelledFilesAreHeld() {
        #expect(Extractor.extract(Data([0x00, 0x01, 0x02, 0x03, 0x00]), name: "x.bin").problem != nil)
        #expect(Extractor.extract(Data([0xD0, 0xCF, 0x11, 0xE0, 0, 0, 0, 0]), name: "old.doc").problem != nil)
        let mislabelled = Extractor.extract(Fixtures.png(Fixtures.textImage(["hello"])), name: "letter.pdf")
        #expect(mislabelled.mismatch)
        #expect(Extractor.normalize("a\u{202E}b\u{200B}c\r\nd", limit: 100) == "abc\nd")
        #expect(Extractor.htmlText("<p>Hi</p><script>evil()</script><img src='https://tracker.example/x.png'>there") == "Hi\nthere")
    }
}

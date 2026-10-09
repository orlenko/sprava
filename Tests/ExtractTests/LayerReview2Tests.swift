import AppKit
import CoreText
import Darwin
@testable import Extract
import Foundation
import Testing

/// Regressions from the second review of the Shelf and Extract layer: intake read through links, multipart key
/// files, unreadable PDF pages, named text parts, the MIME nesting limit, binary quoted-printable. Invented data only.
@Suite(.serialized) struct LayerReview2Tests {
    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-layer06b-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func readMessage(_ eml: String) throws -> IntakeReading {
        let url = temp("eml").appendingPathComponent("message.eml")
        try Data(eml.utf8).write(to: url)
        return IntakeReading.read(url, in: url.deletingLastPathComponent(), channel: "email", reader: .inProcess)
    }

    // MARK: - 1. A harmless name linked to a credential file, or a FIFO, is never read

    @Test func aLinkOrAFIFOIsNotRead() throws {
        let dir = temp("links")
        let secret = dir.appendingPathComponent("credentials.txt")
        try Data("user: invented password: INVENTED-SECRET-9101".utf8).write(to: secret)
        let notice = dir.appendingPathComponent("notice.txt")
        try FileManager.default.createSymbolicLink(at: notice, withDestinationURL: secret)
        let r = IntakeReading.read(notice, in: notice.deletingLastPathComponent(), channel: "other", reader: .inProcess)
        #expect(r.held?.contains("symbolic link") == true)
        #expect(!r.text.contains("INVENTED-SECRET"))

        let letter = dir.appendingPathComponent("letter.txt")
        try Data("An invented letter about the levy.".utf8).write(to: letter)
        let withLink = IntakeReading.read(letter, in: letter.deletingLastPathComponent(), attachments: [notice], channel: "email", reader: .inProcess)
        #expect(!withLink.text.contains("INVENTED-SECRET"))
        #expect(withLink.notes.contains { $0.contains("notice.txt") && $0.contains("symbolic link") })

        // A FIFO with no writer is refused at once, not waited on.
        let fifo = dir.appendingPathComponent("scan.pdf")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(IntakeReading.read(fifo, in: fifo.deletingLastPathComponent(), channel: "other", reader: .inProcess).held?.contains("not a plain file") == true)
    }

    // MARK: - 2. A multipart entity named like a key file is skipped whole

    @Test func aMultipartAttachmentNamedLikeAKeyFileIsNotTheBody() throws {
        let eml = """
        From: manager@example.com
        Subject: Invented access
        Content-Type: multipart/mixed; boundary="OUT"

        --OUT
        Content-Type: multipart/alternative; boundary="IN"
        Content-Disposition: attachment; filename="credentials.txt"

        --IN
        Content-Type: text/plain

        user: invented password: INVENTED-SECRET-9201
        --IN--
        --OUT--
        """
        let extracted = Extractor.extract(Data(eml.utf8), name: "message.eml")
        #expect(!extracted.text.contains("INVENTED-SECRET"))
        #expect(extracted.email?.attachments.map(\.name) == ["credentials.txt"])
        #expect(extracted.email?.attachments.first?.data.isEmpty == true)
        let r = try readMessage(eml)
        #expect(!r.text.contains("INVENTED-SECRET"))
        #expect(r.notes.contains { $0.contains("credentials.txt") && $0.contains("key or credential file") })
    }

    // MARK: - 3. A PDF page that cannot be read holds the file

    /// A PDF of pages of the given sizes, each with its text drawn as a text layer when it has some.
    func pdf(_ pages: [(CGSize, String?)]) -> Data {
        let data = NSMutableData()
        var first = CGRect(origin: .zero, size: pages[0].0)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &first, nil)!
        for (size, text) in pages {
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPDFPage([kCGPDFContextMediaBox as String: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            if let text {
                let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                ctx.textPosition = CGPoint(x: 60, y: size.height - 72)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), ctx)
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    @Test func aPageTooLargeToDrawHoldsThePDF() {
        let letter = CGSize(width: 612, height: 792)
        let r = Extractor.extract(pdf([(letter, "Invented statement: the balance is 120.00"), (CGSize(width: 4000, height: 4000), nil)]),
                                  name: "statement.pdf")
        #expect(r.pages == 2)
        #expect(r.problem?.contains("page 2") == true, "\(String(describing: r.problem))")
        #expect(!r.text.contains("Invented statement"))   // never passed on as if it were the whole file
        // OCR that runs and finds nothing on a blank page is a reading, not a failure.
        let blank = Extractor.extract(pdf([(letter, "Invented statement: the balance is 120.00"), (letter, nil)]), name: "statement.pdf")
        #expect(blank.problem == nil)
        #expect(blank.text.contains("Invented statement"))
        #expect(blank.textFrom == "text-layer")   // OCR added no text, so nothing was read from a scan
    }

    // MARK: - 4. A named text part is an attachment; independent parts are all kept

    @Test func aNamedTextPartAfterTheBodyIsRead() throws {
        let eml = """
        From: supplier@example.com
        Subject: Invented invoice
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain

        Please find the invoice below.
        --XYZ
        Content-Type: text/plain; name="invoice.txt"

        Invented invoice 4410: pay 85.00 by November 15, 2026.
        --XYZ--
        """
        let extracted = Extractor.extract(Data(eml.utf8), name: "message.eml")
        #expect(extracted.text == "Please find the invoice below.")
        #expect(extracted.email?.attachments.map(\.name) == ["invoice.txt"])
        let r = try readMessage(eml)
        #expect(r.attachments == ["invoice.txt"])
        #expect(r.text.contains("November 15, 2026"))
    }

    @Test func alternativesGiveOneBodyAndIndependentPartsAllCount() {
        let r = Extractor.extract(Data("""
        From: manager@example.com
        Subject: Invented meeting
        Content-Type: multipart/mixed; boundary="OUT"

        --OUT
        Content-Type: multipart/alternative; boundary="IN"

        --IN
        Content-Type: text/plain

        The invented meeting is on November 3.
        --IN
        Content-Type: text/html

        <p>The invented meeting is on <b>November 3</b>.</p>
        --IN--
        --OUT
        Content-Type: text/plain

        Second part: bring the invented minutes.
        --OUT--
        """.utf8), name: "message.eml")
        #expect(r.text == "The invented meeting is on November 3.\n\nSecond part: bring the invented minutes.")
    }

    // MARK: - 5. Parts below the nesting limit hold the message

    @Test func partsBelowTheNestingLimitHoldTheMessage() throws {
        var nested = "Content-Type: application/pdf; name=\"deep.pdf\"\n\nnot really a pdf\n"
        for level in (0..<7).reversed() {
            nested = "Content-Type: multipart/mixed; boundary=\"B\(level)\"\n\n--B\(level)\n\(nested)--B\(level)--\n"
        }
        let eml = """
        From: manager@example.com
        Subject: Invented nesting
        Content-Type: multipart/mixed; boundary="TOP"

        --TOP
        Content-Type: text/plain

        An invented outer body.
        --TOP
        \(nested)--TOP--
        """
        let extracted = Extractor.extract(Data(eml.utf8), name: "message.eml")
        #expect(extracted.problem?.contains("nest") == true)
        #expect(try readMessage(eml).held != nil)
        // A message within the limit still reads whole.
        let shallow = Extractor.extract(Data(eml.replacingOccurrences(of: "--TOP\n" + nested, with: "").utf8), name: "message.eml")
        #expect(shallow.problem == nil)
        #expect(shallow.text == "An invented outer body.")
    }

    // MARK: - 6. Quoted-printable keeps a binary attachment's bytes

    @Test func quotedPrintableKeepsBinaryBytes() {
        let r = Extractor.extract(Data("""
        From: manager@example.com
        Subject: Invented picture
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain

        The invented picture is attached.
        --XYZ
        Content-Type: image/png; name="picture.png"
        Content-Transfer-Encoding: quoted-printable

        =89PNG=0D=0A=1A=0A=FF=00
        --XYZ--
        """.utf8), name: "message.eml")
        #expect(r.email?.attachments.first?.data == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0xFF, 0x00, 0x0A]))
    }
}

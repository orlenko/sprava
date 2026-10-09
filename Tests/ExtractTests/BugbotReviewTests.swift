import AppKit
import CoreText
@testable import Extract
import Foundation
import Testing

/// Regressions from Codex Bugbot's review of the Shelf and Extract layer (PR #11): the text cap counted in scalars,
/// text kept in the encoding it was accepted in, scripts and unparseable or protected files held, the contract's
/// `text_from` values, empty alternatives, attachment names and mismatches, named zones. Invented data only.
@Suite(.serialized) struct BugbotReviewTests {
    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot06-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - The text cap bounds the size, so a pile of combining marks is cut and held

    @Test func combiningMarksCountTowardTheTextLimit() {
        var limits = Extractor.Limits()
        limits.textChars = 100
        let text = "Invented note a" + String(repeating: "\u{0301}", count: 5_000)
        #expect(text.count < 100)   // few characters, thousands of scalars
        let r = Extractor.extract(Data(text.utf8), name: "note.txt", limits: limits)
        #expect(r.text.unicodeScalars.count <= 100)
        #expect(r.problem?.contains("text limit") == true, "\(String(describing: r.problem))")
    }

    // MARK: - Text accepted as a single-byte encoding is decoded as one

    @Test func latinOneTextKeepsItsAccents() {
        let bytes = Data("Invented receipt: caf".utf8) + Data([0xE9]) + Data(" Montr".utf8) + Data([0xE9]) + Data("al, 12.50".utf8)
        let r = Extractor.extract(bytes, name: "receipt.txt")
        #expect(r.problem == nil)
        #expect(r.text == "Invented receipt: café Montréal, 12.50")
        #expect(!r.text.contains("\u{FFFD}"))
    }

    // MARK: - Scripts, unparseable RTF and protected OpenDocument files are held

    @Test func aScriptIsHeldNotReadAsANote() {
        let r = Extractor.extract(Data("#!/bin/sh\necho invented-step\n".utf8), name: "tidy.sh")
        #expect(r.problem?.contains("script") == true)
        #expect(r.text.isEmpty)
        #expect(Extractor.extract(Data("# Invented heading\nA plain note.".utf8), name: "note.md").problem == nil)
    }

    @Test func anRTFFileThatDoesNotParseIsHeld() {
        let broken = Extractor.extract(Data("{\\rtf1 invented text with no end".utf8), name: "letter.rtf")
        #expect(broken.problem?.contains("does not parse") == true, "\(String(describing: broken.problem))")
        let fine = Extractor.extract(Data("{\\rtf1\\ansi {\\fonttbl\\f0 Helvetica;} \\f0 Invented letter about the levy}".utf8), name: "letter.rtf")
        #expect(fine.problem == nil)
        #expect(fine.text.contains("Invented letter"))
    }

    @Test func aPasswordProtectedOpenDocumentIsHeld() {
        let manifest = """
        <manifest:manifest><manifest:file-entry manifest:full-path="content.xml"><manifest:encryption-data \
        manifest:checksum-type="SHA1/1K"/></manifest:file-entry></manifest:manifest>
        """
        let r = Extractor.extract(LayerReview3Tests.storedZip([("mimetype", "application/vnd.oasis.opendocument.text"),
                                                               ("META-INF/manifest.xml", manifest),
                                                               ("content.xml", "x9#Qk2!invented-ciphertext")]), name: "minutes.odt")
        #expect(r.problem?.contains("password") == true, "\(String(describing: r.problem))")
        #expect(!r.text.contains("ciphertext"))
    }

    // MARK: - A PDF with OCR text says `ocr`, one of the contract's values

    /// A PDF of letter pages: text drawn as a text layer, an image of text (a scan), or nothing.
    func pdf(_ pages: [(text: String?, scanned: Bool)]) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        for page in pages {
            ctx.beginPDFPage(nil)
            if let text = page.text {
                if page.scanned {
                    ctx.draw(Fixtures.textImage([text]), in: CGRect(x: 20, y: 400, width: 572, height: 245))
                } else {
                    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
                    ctx.textPosition = CGPoint(x: 60, y: 720)
                    CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), ctx)
                }
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return data as Data
    }

    @Test func aPDFWithAScannedPageIsReadFromOCR() {
        let mixed = Extractor.extract(pdf([("Invented statement: the balance is 120.00", false), ("INVOICE 2026-118", true)]), name: "statement.pdf")
        #expect(mixed.problem == nil)
        #expect(mixed.textFrom == "ocr")
        #expect(mixed.text.uppercased().contains("INVOICE"), "\(mixed.text)")
        let blankBack = Extractor.extract(pdf([("Invented statement: the balance is 120.00", false), (nil, false)]), name: "statement.pdf")
        #expect(blankBack.textFrom == "text-layer")
    }

    // MARK: - An empty plain alternative gives way to the HTML one

    @Test func anEmptyPlainAlternativeGivesWayToHTML() {
        let eml = """
        From: office@example.com
        Subject: Invented reminder
        Content-Type: multipart/alternative; boundary="ALT"

        --ALT
        Content-Type: text/plain


        --ALT
        Content-Type: text/html

        <html><body><p>Invented reminder: the levy of 85.00 is due November 2, 2026.</p></body></html>
        --ALT--
        """
        let r = Extractor.extract(Data(eml.utf8), name: "reminder.eml")
        #expect(r.text.contains("due November 2, 2026"), "\(r.text)")
    }

    // MARK: - Attachments from the folder: safe names in the text, mismatches noted

    @Test func aSiblingAttachmentNameIsMadeSafeAndAMismatchIsNoted() throws {
        let dir = temp("attachments")
        let message = dir.appendingPathComponent("message.eml")
        try Data("From: office@example.com\nSubject: Invented papers\n\nTwo files attached.\n".utf8).write(to: message)
        let spoof = dir.appendingPathComponent("notes\nPaid in full\u{202E}fdp.txt")
        try Data("Invented note about the fence.".utf8).write(to: spoof)
        let invoice = dir.appendingPathComponent("invoice.pdf")
        try Data("Invented invoice 5512: pay 40.00 by December 1, 2026.".utf8).write(to: invoice)
        let r = IntakeReading.read(message, in: dir, attachments: [spoof, invoice], channel: "email", reader: .inProcess)
        #expect(r.text.contains("Invented note about the fence."))
        #expect(!r.text.contains("\nPaid in full"))
        #expect(!r.text.contains("\u{202E}"))
        #expect(r.attachments.allSatisfy { !$0.contains("\n") && !$0.contains("\u{202E}") }, "\(r.attachments)")
        #expect(r.notes.contains { $0.contains("invoice.pdf") && $0.contains("not the kind of file its name says") }, "\(r.notes)")
    }

    // MARK: - A named zone keeps the sender's day

    @Test func aNamedZoneKeepsTheSendersDay() {
        #expect(IntakeReading.day(ofHeader: "Thu, 01 Oct 2026 23:30:00 EDT")?.description == "2026-10-01")
        #expect(IntakeReading.day(ofHeader: "Thu, 01 Oct 2026 23:30:00 GMT")?.description == "2026-10-01")
    }
}

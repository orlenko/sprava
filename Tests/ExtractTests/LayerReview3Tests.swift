@testable import Extract
import Foundation
import Testing

/// Regressions from the third review of the Shelf and Extract layer: a message read as HTML, a forwarded message's
/// own attachments, an archive past the entry limit, linked folders inside intake, folded MIME headers, malformed
/// worksheet cells. Invented data only.
@Suite(.serialized) struct LayerReview3Tests {
    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-layer06c-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. A message that sniffs as HTML is held when it carries MIME parts

    @Test func aMessageReadAsHTMLWithAKeyFilePartIsHeld() throws {
        let text = """
        Forwarded below.
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/html; charset=utf-8

        <html><body><p>The invented access details are attached.</p></body></html>
        --XYZ
        Content-Type: text/plain; name="credentials.txt"
        Content-Disposition: attachment; filename="credentials.txt"

        user: invented password: INVENTED-SECRET-8830
        --XYZ--
        """
        #expect(Extractor.sniff(Data(text.utf8), name: "forwarded.txt") == .html)
        let r = Extractor.extract(Data(text.utf8), name: "forwarded.txt")
        #expect(r.problem != nil)
        #expect(!r.text.contains("INVENTED-SECRET"))
        let url = temp("html").appendingPathComponent("forwarded.txt")
        try Data(text.utf8).write(to: url)
        let reading = IntakeReading.read(url, in: url.deletingLastPathComponent(), channel: "other", reader: .inProcess)
        #expect(reading.held != nil && !reading.text.contains("INVENTED-SECRET"))
        // An ordinary page still reads.
        let page = Extractor.extract(Data("<html><body><p>The invented meeting is on November 3.</p></body></html>".utf8), name: "page.html")
        #expect(page.problem == nil && page.text == "The invented meeting is on November 3.")
    }

    // MARK: - 2. A forwarded message's own attachments are noted, never dropped in silence

    @Test func aForwardedMessagesAttachmentsAreNoted() throws {
        let forwarded = """
        From: supplier@example.com
        Subject: Invented invoice
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="INNER"

        --INNER
        Content-Type: text/plain

        The invoice is attached.
        --INNER
        Content-Type: application/pdf; name="invoice.pdf"
        Content-Disposition: attachment; filename="invoice.pdf"
        Content-Transfer-Encoding: base64

        \(Data("not really a pdf".utf8).base64EncodedString())
        --INNER--
        """
        let eml = """
        From: Invented Manager <manager@example.com>
        To: person@example.com
        Subject: Fwd: Invented invoice
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="OUTER"

        --OUTER
        Content-Type: text/plain

        See the message below.
        --OUTER
        Content-Type: message/rfc822; name="forwarded.eml"
        Content-Disposition: attachment; filename="forwarded.eml"

        \(forwarded)
        --OUTER--
        """
        let url = temp("fwd").appendingPathComponent("message.eml")
        try Data(eml.utf8).write(to: url)
        let r = IntakeReading.read(url, in: url.deletingLastPathComponent(), channel: "email", reader: .inProcess)
        #expect(r.attachments == ["forwarded.eml"])
        #expect(r.text.contains("The invoice is attached."))
        #expect(r.notes.contains { $0.contains("forwarded.eml") && $0.contains("of its own that were not read") }, "\(r.notes)")
    }

    // MARK: - 3. An archive past the entry limit does not open, rather than reading in part

    /// A zip of stored entries, written by hand so it can hold more entries than the reader lists.
    static func storedZip(_ files: [(String, String)]) -> Data {
        var data = Data(), central = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        for (name, text) in files {
            let n = Data(name.utf8), body = Data(text.utf8), offset = data.count
            data += le32(0x04034b50) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            data += le32(body.count) + le32(body.count) + le16(n.count) + le16(0) + n + body
            central += le32(0x02014b50) + le16(20) + le16(20) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(body.count) + le32(body.count) + le16(n.count) + le16(0) + le16(0) + le16(0) + le16(0) + le32(0)
            central += le32(offset) + n
        }
        let start = data.count
        data += central
        data += le32(0x06054b50) + le16(0) + le16(0) + le16(files.count) + le16(files.count) + le32(central.count) + le32(start) + le16(0)
        return data
    }

    @Test func anArchivePastTheEntryLimitIsHeld() {
        let sheet = #"<worksheet><sheetData><row><c t="inlineStr"><is><t>INVENTED-ROW-%@</t></is></c></row></sheetData></worksheet>"#
        var files = [("xl/workbook.xml", "<workbook/>"), ("xl/worksheets/sheet1.xml", sheet.replacingOccurrences(of: "%@", with: "1"))]
        files += (0..<9_998).map { ("filler/\($0).txt", "") }
        files.append(("xl/worksheets/sheet2.xml", sheet.replacingOccurrences(of: "%@", with: "2")))
        #expect(files.count == 10_001)
        let r = Extractor.extract(Self.storedZip(files), name: "ledger.xlsx")
        #expect(r.problem != nil && !r.text.contains("INVENTED-ROW-1"))
        // At the limit the archive still reads, every sheet in it.
        let small = Extractor.extract(Self.storedZip(Array(files.prefix(2)) + [files.last!]), name: "ledger.xlsx")
        #expect(small.problem == nil && small.text.contains("INVENTED-ROW-1") && small.text.contains("INVENTED-ROW-2"), "\(small.text)")
    }

    // MARK: - 4. A folder inside the binder that is a link is never read through

    @Test func aLinkedFolderInsideIntakeIsNotFollowed() throws {
        let root = temp("links")
        let outside = root.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("user: invented password: INVENTED-SECRET-8840".utf8).write(to: outside.appendingPathComponent("notes.txt"))
        let binder = root.appendingPathComponent("Invented Binder")
        let intake = binder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: intake.appendingPathComponent("mail"), withDestinationURL: outside)
        let linked = IntakeReading.read(intake.appendingPathComponent("mail/notes.txt"), in: binder, channel: "email", reader: .inProcess)
        #expect(linked.held?.contains("symbolic link") == true, "\(linked.held ?? "read")")
        #expect(!linked.text.contains("INVENTED-SECRET"))
        // An attachments folder that is a link is refused the same way.
        try FileManager.default.createDirectory(at: binder.appendingPathComponent("intake/real"), withIntermediateDirectories: true)
        let message = intake.appendingPathComponent("real/message.txt")
        try Data("The invented notice is attached.".utf8).write(to: message)
        try FileManager.default.createSymbolicLink(at: intake.appendingPathComponent("real/message attachments"), withDestinationURL: outside)
        let r = IntakeReading.read(message, in: binder, attachments: [intake.appendingPathComponent("real/message attachments/notes.txt")],
                                   channel: "email", reader: .inProcess)
        #expect(!r.text.contains("INVENTED-SECRET") && r.text.contains("The invented notice"))
        #expect(r.notes.contains { $0.contains("symbolic link") }, "\(r.notes)")
        // intake itself linked elsewhere is refused too.
        let other = root.appendingPathComponent("Other Binder")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: other.appendingPathComponent("intake"), withDestinationURL: outside)
        #expect(IntakeReading.read(other.appendingPathComponent("intake/notes.txt"), in: other, channel: "other", reader: .inProcess).held != nil)
        // A binder reached through a link above it still reads: the binder is the folder the caller trusts.
        #expect(IntakeReading.read(message, in: binder, channel: "other", reader: .inProcess).held == nil)
        let via = root.appendingPathComponent("via")
        try FileManager.default.createSymbolicLink(at: via, withDestinationURL: root)
        let throughLink = via.appendingPathComponent("Invented Binder")
        #expect(IntakeReading.read(throughLink.appendingPathComponent("intake/real/message.txt"), in: throughLink, channel: "other",
                                   reader: .inProcess).text.contains("The invented notice"))
        // A file outside the binder it is read for is refused.
        #expect(IntakeReading.read(outside.appendingPathComponent("notes.txt"), in: binder, channel: "other", reader: .inProcess).held?
            .contains("outside") == true)
    }

    /// A link inside one binder's intake to another binder, read through that binder's own `intake`: the path holds a
    /// folder named `intake` below the link, which must not become the folder the read starts from.
    @Test func aNestedIntakeBehindALinkIsNotFollowed() throws {
        let root = temp("nested")
        let a = root.appendingPathComponent("Binder A"), b = root.appendingPathComponent("Binder B")
        try FileManager.default.createDirectory(at: a.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("An invented notice for binder B only: INVENTED-SECRET-8860".utf8).write(to: b.appendingPathComponent("intake/notice.txt"))
        try FileManager.default.createSymbolicLink(at: a.appendingPathComponent("intake/link"), withDestinationURL: b)
        let r = IntakeReading.read(a.appendingPathComponent("intake/link/intake/notice.txt"), in: a, channel: "other", reader: .inProcess)
        #expect(r.held?.contains("symbolic link") == true, "\(r.held ?? "read")")
        #expect(!r.text.contains("INVENTED-SECRET"))
        // The same file read for its own binder reads.
        #expect(IntakeReading.read(b.appendingPathComponent("intake/notice.txt"), in: b, channel: "other", reader: .inProcess).text.contains("INVENTED-SECRET"))
    }

    // MARK: - 5. Folded MIME headers are unfolded before the parts check

    @Test func foldedPartHeadersAreHeld() {
        let text = """
        Forwarded below.
        MIME-Version: 1.0
        Content-Type:
         multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain

        The invented access details are attached.
        --XYZ
        Content-Type: text/plain
        Content-Disposition: attachment;
         filename="credentials.txt"

        user: invented password: INVENTED-SECRET-8850
        --XYZ--
        """
        let r = Extractor.extract(Data(text.utf8), name: "forwarded.txt")
        #expect(r.problem != nil && !r.text.contains("INVENTED-SECRET"))
        let crlf = Extractor.extract(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8), name: "forwarded.txt")
        #expect(crlf.problem != nil && !crlf.text.contains("INVENTED-SECRET"))
    }

    // MARK: - 6. A malformed worksheet cell holds the document instead of crashing

    @Test func aMalformedWorksheetCellIsHeld() {
        for cell in ["<c></v><v>1</c>", #"<c t="inlineStr"><is></t><t>INVENTED</is></c>"#, "<c><v>1</c>"] {
            let sheet = "<worksheet><sheetData><row>\(cell)</row></sheetData></worksheet>"
            let r = Extractor.extract(Self.storedZip([("xl/workbook.xml", "<workbook/>"), ("xl/worksheets/sheet1.xml", sheet)]), name: "ledger.xlsx")
            #expect(r.problem?.contains("sheet1.xml") == true, "\(cell): \(r.problem ?? "read")")
        }
    }
}

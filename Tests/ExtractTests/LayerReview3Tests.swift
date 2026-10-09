@testable import Extract
import Foundation
import Testing

/// Regressions from the third review of the Shelf and Extract layer: a message read as HTML, a forwarded message's
/// own attachments, an archive past the entry limit. Invented data only.
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
        let reading = IntakeReading.read(url, channel: "other", reader: .inProcess)
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
        let r = IntakeReading.read(url, channel: "email", reader: .inProcess)
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
}

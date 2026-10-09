import Darwin
@testable import Extract
import Foundation
import Testing

/// Regressions from the fifth adversarial review of increment 1 (key files named by an inline MIME part, numbers in
/// untrusted text that overflowed, withdrawals a failing binder check held back, unreadable backup settings).
/// Invented data only.
@Suite(.serialized) struct AstraReview5Tests {
    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra5-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 1. A part named like a key file is never the body

    func readMessage(_ eml: String) throws -> IntakeReading {
        let url = temp("eml").appendingPathComponent("message.eml")
        try Data(eml.utf8).write(to: url)
        return IntakeReading.read(url, in: url.deletingLastPathComponent(), channel: "email", reader: .inProcess)
    }

    @Test func aKeyFileNamedInlinePartIsSkippedWithANote() throws {
        let eml = """
        From: Invented Manager <manager@example.com>
        To: person@example.com
        Subject: Invented access details
        Date: Tue, 6 Oct 2026 09:00:00 -0400
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain; charset=utf-8; name="credentials.txt"
        Content-Disposition: inline

        user: invented password: INVENTED-SECRET-7710
        --XYZ
        Content-Type: text/plain; charset=utf-8

        Invented notice: the levy is due on November 1, 2026.
        --XYZ
        Content-Type: text/html; charset=utf-8
        Content-Disposition: inline; filename*=utf-8''%2Enetrc

        <p>machine example.com password INVENTED-SECRET-7711</p>
        --XYZ
        Content-Type: text/plain
        Content-Disposition: inline; filename*0="id_"; filename*1="ed25519"

        INVENTED-SECRET-7712
        --XYZ--
        """
        let extracted = Extractor.extract(Data(eml.utf8), name: "message.eml")
        #expect(extracted.text.contains("Invented notice"))
        #expect(!extracted.text.contains("INVENTED-SECRET"))
        let attachments = extracted.email?.attachments ?? []
        #expect(attachments.map(\.name) == ["credentials.txt", "netrc", "id_ed25519"])
        #expect(attachments.allSatisfy { $0.data.isEmpty })   // the secret never leaves the extractor

        let r = try readMessage(eml)
        #expect(r.held == nil)
        #expect(r.text.contains("Invented notice") && !r.text.contains("INVENTED-SECRET"))
        #expect(r.notes.filter { $0.contains("key or credential file") }.count == 3, "\(r.notes)")
    }

    @Test func aSinglePartMessageNamedLikeAKeyFileHasNoBody() throws {
        let r = try readMessage("""
        From: manager@example.com
        Subject: Invented token
        Content-Type: text/plain; name="token-api.json"

        {"token": "INVENTED-SECRET-7720"}
        """)
        #expect(!r.text.contains("INVENTED-SECRET"))
        #expect(r.notes.contains { $0.contains("token-api.json") && $0.contains("key or credential file") })
    }

    @Test func unnamedTextAndHTMLBodiesStillRead() {
        let html = Extractor.extract(Data("""
        From: manager@example.com
        Subject: Invented notice
        Content-Type: text/html; charset=utf-8

        <p>The invented meeting is on <b>November 3</b>.</p>
        """.utf8), name: "message.eml")
        #expect(html.text.contains("The invented meeting is on"))
        #expect(html.email?.attachments.isEmpty == true)
        // A named part that is no key file keeps its old place: a named document is an attachment, read later.
        let named = Extractor.extract(Data("""
        From: manager@example.com
        Subject: Invented quote
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain

        The quote is attached.
        --XYZ
        Content-Type: application/pdf; name*=utf-8''quote%20October.pdf
        Content-Transfer-Encoding: base64

        \(Data("not really a pdf".utf8).base64EncodedString())
        --XYZ--
        """.utf8), name: "message.eml")
        #expect(named.text == "The quote is attached.")
        #expect(named.email?.attachments.map(\.name) == ["quote October.pdf"])
        #expect(named.email?.attachments.first?.data.isEmpty == false)
    }
}

import CryptoKit
import Darwin
@testable import Extract
import Foundation
import Testing

/// Regressions from the fourth adversarial review of increment 1 (key and credential files in intake, hub
/// withdrawal while the outbox fails, private corrections that close items, correction cards that could not be
/// kept, unreadable op logs, exhausted id sequences) and the MCP socket's modes. Invented data only.
@Suite(.serialized) struct AstraReview4Tests {
    @Test func aKeyFileInsideAnEmailIsSkippedWithANote() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra4-eml-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        func part(_ name: String, _ text: String) -> String {
            """
            --XYZ
            Content-Type: application/octet-stream; name="\(name)"
            Content-Disposition: attachment; filename="\(name)"
            Content-Transfer-Encoding: base64

            \(Data(text.utf8).base64EncodedString())
            """
        }
        let eml = """
        From: Invented Manager <manager@example.com>
        To: person@example.com
        Subject: Invented access details
        Date: Tue, 6 Oct 2026 09:00:00 -0400
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="XYZ"

        --XYZ
        Content-Type: text/plain; charset=utf-8

        The notice is attached.
        \(part("token-api.json", "INVENTED-SECRET-6630"))
        \(part(".netrc", "machine example.com password INVENTED-SECRET-6631"))
        \(part("notice.txt", "Invented notice text"))
        --XYZ--
        """
        let url = folder.appendingPathComponent("message.eml")
        try Data(eml.utf8).write(to: url)
        let r = IntakeReading.read(url, channel: "email", reader: .inProcess)
        #expect(r.held == nil)
        #expect(!r.text.contains("INVENTED-SECRET"))
        #expect(r.text.contains("Invented notice text"))
        #expect(r.notes.filter { $0.contains("key or credential file") }.count == 2, "\(r.notes)")
    }
}

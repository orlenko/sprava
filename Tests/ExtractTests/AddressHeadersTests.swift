@testable import Extract
import Foundation
import SpravaKit
import Testing

/// From and To are kept as the message wrote them, for telling whose mail it is (issue #598). Addresses are invented.
struct AddressHeadersTests {
    private let crafted = "=?utf-8?q?you@example.com=2C?= <sender@example.net>"

    @Test func aMessageKeepsItsFromAndToAsWritten() throws {
        let message = "From: \(crafted)\r\nTo: =?utf-8?q?Friend?= <friend@example.org>\r\nSubject: Hi\r\n\r\nBody.\r\n"
        let email = try #require(Extractor.eml(Data(message.utf8)).email)
        #expect(email.from == "you@example.com, <sender@example.net>")
        #expect(email.fromHeader == crafted)
        #expect(email.toHeader == "=?utf-8?q?Friend?= <friend@example.org>")
        // A header too long to keep whole is kept empty, never cut: cut, it could end in part of an address.
        let long = "From: (" + String(repeating: "x", count: 4_100) + ") <me@example.invalid.other.invalid>\r\n\r\nx\r\n"
        #expect(Extractor.eml(Data(long.utf8)).email?.fromHeader == "")
    }

    /// The importer writes each front-matter value as a JSON string; reading it back gives the same text, backslashes
    /// and quotes included.
    @Test func theImportersFrontMatterReadsBackAsWritten() throws {
        let name = #""Doe \"J\" \\ x" <jane@example.net>"#
        var front = "---\n"
        for (k, v) in [("subject", "A \\ subject"), ("from", name), ("to", "b@example.org"), ("from_header", crafted), ("to_header", "b@example.org")] {
            front += k + ": " + JSONWriter.compact(.str(v)) + "\n"
        }
        let email = try #require(Extractor.markdownEmail(front + "---\n\nThe body.\n").email)
        #expect(email.from == name && email.subject == "A \\ subject")
        #expect(email.fromHeader == crafted && email.toHeader == "b@example.org")
        // A file written before these keys existed has none.
        #expect(Extractor.markdownEmail("---\nfrom: \"a@example.net\"\n---\n\nx\n").email?.fromHeader == nil)
    }

    @Test func aReadingKeepsTheHeadersThroughItsRecord() throws {
        var reading = IntakeReading(kind: "email", textFrom: "parsed", text: "x", channel: "email")
        reading.from = "you@example.com, <sender@example.net>"; reading.fromHeader = crafted; reading.toHeader = "b@example.org"
        let back = try #require(IntakeReading(json: .object(reading.json)))
        #expect(back == reading)
    }
}

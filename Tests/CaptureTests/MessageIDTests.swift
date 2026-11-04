@testable import Capture
import Foundation
import Testing

/// Reading what makes a message the same email from its header and body, which are untrusted. Invented mail only.
@Suite struct MessageIDTests {
    func id(_ header: String) -> String? { IntakeWatcher.messageID(inHeader: Data(header.utf8)).map { String(decoding: $0, as: UTF8.self) } }

    @Test func anIDIsReadWithoutItsBrackets() {
        #expect(id("Subject: Gate\nMessage-ID: <gate.1@mail.example.invalid>\n") == "gate.1@mail.example.invalid")
        #expect(id("message-id:gate.1@mail.example.invalid") == "gate.1@mail.example.invalid")
        #expect(id("Message-ID: <gate.1@mail.example.invalid> (an invented comment)\r\n") == "gate.1@mail.example.invalid")
        // Folded onto the next line, with CRLF endings.
        #expect(id("Subject: Gate\r\nMessage-ID:\r\n\t<gate.1@mail.example.invalid>\r\nTo: a@example.invalid\r\n") == "gate.1@mail.example.invalid")
        // Only the message's own id: not one it was resent with, nor one in a reference.
        #expect(id("Resent-Message-ID: <gate.2@mail.example.invalid>\nIn-Reply-To: <gate.3@mail.example.invalid>\n") == nil)
    }

    @Test func aHostileIDIsNoID() {
        let long = String(repeating: "a", count: 1_000) + "@example.invalid"
        #expect(id("Message-ID: <\(long)>\n") == nil)
        #expect(id("Message-ID: <gate\u{07}1@mail.example.invalid>\n") == nil)
        #expect(id("Message-ID: <gate\u{202E}1@mail.example.invalid>\n") == nil)
        #expect(id("Message-ID: <gate\u{A0}1@mail.example.invalid>\n") == nil)
        #expect(id("Message-ID: <gate 1@mail.example.invalid>\n") == nil)
        #expect(id("Message-ID: <gate.1@mail.example.invalid\n") == nil)
        // Folded inside the id, it holds a space.
        #expect(id("Message-ID: <gate.1@mail.\n example.invalid>\n") == nil)
        #expect(id("Message-ID: <>\n") == nil)
        #expect(id("Message-ID: <@example.invalid>\n") == nil)
        #expect(id("Message-ID: <gate.1@>\n") == nil)
        // A lone CR is not a line break: it stays in the id, which it spoils.
        #expect(id("Message-ID: <gate.1@mail.example.invalid\r>\n") == nil)
        // Two ids say nothing about which email this is.
        #expect(id("Message-ID: <gate.1@mail.example.invalid>\nMessage-ID: <gate.2@mail.example.invalid>\n") == nil)
    }

    let header = "Message-ID: <gate.1@mail.example.invalid>\nFrom: Invented Gatekeeper <gate@example.invalid>\nDate: Mon, 6 Apr 2026 08:00:00 +0000"
    func key(_ header: String, _ body: String = "The invented gate is fixed.\n", crlf: Bool = false) -> String? {
        let message = header + "\n\n" + body
        return IntakeWatcher.messageKey(message: Data((crlf ? message.replacingOccurrences(of: "\n", with: "\r\n") : message).utf8))
    }

    /// The id alone does not make the same email: its sender, date and body must be there too, and the same.
    @Test func theKeyNeedsTheIDTheSenderTheDateAndTheBody() throws {
        let gate = try #require(key(header))
        #expect(key("Message-ID: <gate.1@mail.example.invalid>\n") == nil)
        #expect(key("Message-ID: <gate.1@mail.example.invalid>\nFrom: Invented Gatekeeper <gate@example.invalid>\n") == nil)
        #expect(key("Message-ID: <gate.1@mail.example.invalid>\nDate: Mon, 6 Apr 2026 08:00:00 +0000\n") == nil)
        // Another body, as a forgery copying the header would have, is another email.
        #expect(key(header, "The invented gate is fixed. Pay to an invented account.\n") != gate)
        #expect(key(header.replacingOccurrences(of: "Apr", with: "May")) != gate)
        // Saved again, its line endings may change, and nothing else: the space at a line's end is data.
        #expect(key(header, crlf: true) == gate)
        #expect(key(header, "The invented gate is fixed.  \n") != gate)
        #expect(key(header, "The invented gate is fixed.\n\n") != gate)
        #expect(key(header, "The invented gate\nis fixed.\n") != gate)
        // Folded with a tab, a sender keeps the tab of its fold.
        #expect(key("Message-ID: <gate.1@mail.example.invalid>\nFrom: Invented Gatekeeper\n\t<gate@example.invalid>\nDate: Mon, 6 Apr 2026 08:00:00 +0000\n") != nil)
        // Hostile values are none.
        #expect(key(header + "\nDate: Tue, 7 Apr 2026 08:00:00 +0000\n") == nil)
        let rest = "\nDate: Mon, 6 Apr 2026 08:00:00 +0000\nMessage-ID: <gate.1@mail.example.invalid>\n"
        #expect(key("From: Invented\u{07}Gatekeeper" + rest) == nil)
        #expect(key("From: Invented\u{202E}Gatekeeper" + rest) == nil)
        #expect(key("From: Invented\rGatekeeper" + rest) == nil)
        #expect(key("From: \(String(repeating: "g", count: 1_000))" + rest) == nil)
        #expect(key("From:   " + rest) == nil)
    }

    /// The same raw body read another way is another email: the fields that say how it reads must match too, a field
    /// missing from both counting as equal, and a missing one never equal to an empty one.
    @Test func theFieldsSayingHowItReadsMustMatch() throws {
        let mime = "\nSubject: Gate\nMIME-Version: 1.0\nContent-Type: text/plain; charset=us-ascii\nContent-Transfer-Encoding: 7bit"
        let body = "=4F=70=65=6E\n"
        let gate = try #require(key(header + mime, body))
        #expect(key(header + mime, body) == gate)
        #expect(key(header + mime.replacingOccurrences(of: "Subject: Gate", with: "Subject: Gate closed"), body) != gate)
        #expect(key(header + mime.replacingOccurrences(of: "7bit", with: "quoted-printable"), body) != gate)
        #expect(key(header + mime.replacingOccurrences(of: "us-ascii", with: "utf-8"), body) != gate)
        #expect(key(header + mime.replacingOccurrences(of: "\nMIME-Version: 1.0", with: ""), body) != gate)
        #expect(key(header + "\nSubject:", body) != key(header, body))
        #expect(key(header + "\nSubject: Gate\nSubject: Gate", body) == nil)
        #expect(key(header + "\nContent-Type: text/plain\u{07}", body) == nil)
    }

    /// Line endings are evened out only where they carry no data: never with a lone CR anywhere in the message, nor
    /// when any header, a part's included, declares the binary transfer encoding.
    @Test func lineEndingsAreEvenedOnlyWhereTheyCarryNoData() throws {
        // Under binary, CR and LF are data.
        let binary = header + "\nContent-Transfer-Encoding: binary"
        #expect(try #require(key(binary, "ABC\nDEF")) != key(binary, "ABC\rDEF"))
        #expect(key(binary, "ABC\r\nDEF") != key(binary, "ABC\nDEF"))
        // A lone CR in a 7bit body is not an LF.
        let sevenBit = header + "\nContent-Transfer-Encoding: 7bit"
        #expect(try #require(key(sevenBit, "ABC\nDEF\n")) != key(sevenBit, "ABC\rDEF\n"))
        // A part declaring binary, in any case and spacing, folded or not, keeps the whole body exact.
        let multipart = header + "\nMIME-Version: 1.0\nContent-Type: multipart/mixed; boundary=\"b\""
        for declared in ["Content-Transfer-Encoding: binary", "content-transfer-encoding :\tBINARY", "Content-Transfer-Encoding:\n binary"] {
            let parts = "--b\nContent-Type: text/plain\n\(declared)\n\nABC\nDEF\n--b--\n"
            #expect(try #require(key(multipart, parts)) != key(multipart, parts, crlf: true))
        }
        // Under 7bit, quoted-printable and base64, the same email saved with CRLF or LF is the same.
        let parts = "--b\nContent-Type: text/plain\nContent-Transfer-Encoding: 7bit\n\nABC\nDEF\n"
            + "--b\nContent-Type: text/plain\nContent-Transfer-Encoding: quoted-printable\n\nGate=0D=0Aclosed=\n\n"
            + "--b\nContent-Type: application/pdf\nContent-Transfer-Encoding: base64\n\nSW52ZW50ZWQ=\n--b--\n"
        #expect(try #require(key(multipart, parts)) == key(multipart, parts, crlf: true))
        #expect(IntakeWatcher.lineEndingsCarryNoData(Data("A: b\r\n\r\nc\r\n".utf8)))
        #expect(!IntakeWatcher.lineEndingsCarryNoData(Data("A: b\r\n\r\nc\r".utf8)))
    }

    /// Raw 8-bit bytes in a header are compared as they are: two that differ in one byte are two emails.
    @Test func eightBitHeadersAreComparedByTheirBytes() throws {
        func raw(_ byte: UInt8) -> Data {
            Data("Message-ID: <gate.1@mail.example.invalid>\nDate: Mon, 6 Apr 2026 08:00:00 +0000\nFrom: Invented G".utf8)
                + Data([byte]) + Data("tekeeper <gate@example.invalid>\n\nThe invented gate is fixed.\n".utf8)
        }
        let first = try #require(IntakeWatcher.messageKey(message: raw(0xE1)))
        #expect(IntakeWatcher.messageKey(message: raw(0xE1)) == first)
        #expect(IntakeWatcher.messageKey(message: raw(0xE2)) != first)
    }

    @Test func aFileIsReadSafelyAndOnlyWithinItsLimits() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-msgid-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ text: String) throws -> URL {
            let url = dir.appendingPathComponent(name)
            try Data(text.utf8).write(to: url)
            return url
        }
        func fileKey(_ url: URL) -> String? { IntakeWatcher.messageKey(of: url) }
        let gate = try #require(key(header))
        // Fields in the body are not the message's.
        #expect(fileKey(try write("body.eml", "Subject: Gate\n\n\(header)\n")) == nil)
        let crlf = (header + "\n\nThe invented gate is fixed.\n").replacingOccurrences(of: "\n", with: "\r\n")
        #expect(fileKey(try write("crlf.eml", crlf)) == gate)
        // A header with no end within the limit is not read further.
        let huge = "X-Invented: " + String(repeating: "b", count: IntakeWatcher.headerLimit) + "\n\(header)\n\nThe invented gate is fixed.\n"
        #expect(fileKey(try write("huge.eml", huge)) == nil)
        // A link is never followed.
        let target = try write("target.eml", "\(header)\n\nThe invented gate is fixed.\n")
        let link = dir.appendingPathComponent("link.eml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(fileKey(link) == nil)
        #expect(fileKey(target) == gate)
    }
}

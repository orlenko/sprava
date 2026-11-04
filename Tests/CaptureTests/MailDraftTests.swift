@testable import Capture
@testable import Extract
import Foundation
import Testing

/// The MIME writer for email drafts (issue #592). Invented people and addresses only.
struct MailDraftTests {
    static let me = MailDraft.Mailbox(name: "Ann Example", address: "ann@example.com")
    static let you = MailDraft.Mailbox(name: "Bo Sample", address: "bo@example.invalid")
    static let day = Date(timeIntervalSince1970: 1_793_786_400)   // 2026-11-04 10:00 UTC

    static func draft(from: MailDraft.Mailbox = me, to: [MailDraft.Mailbox] = [you], cc: [MailDraft.Mailbox] = [],
                      subject: String = "Lease renewal", body: String = "Hello,\nthe form is attached.",
                      attachments: [MailDraft.Attachment] = [], inReplyTo: String? = nil, references: [String] = [],
                      messageID: String = "<draft-1@sprava.example.com>", unsent: Bool = false, limits: MailDraft.Limits = .init(),
                      boundary: () -> String = { "Fixed0" }) throws -> MailDraft {
        try MailDraft(from: from, to: to, cc: cc, subject: subject, body: body, attachments: attachments, inReplyTo: inReplyTo,
                      references: references, messageID: messageID, date: day, timeZone: TimeZone(identifier: "UTC")!,
                      unsent: unsent, limits: limits, boundary: boundary)
    }

    static func text(_ d: MailDraft) -> String { String(decoding: d.rfc822, as: UTF8.self) }
    static func headers(_ d: MailDraft) -> String { text(d).components(separatedBy: "\r\n\r\n")[0] }
    static func read(_ d: MailDraft) -> Extractor.Email { Extractor.extract(d.rfc822, name: "draft.eml").email! }

    @Test func asciiDraftHasItsHeadersAndBodyAndReadsBack() throws {
        let d = try Self.draft(unsent: true)
        let head = Self.headers(d)
        #expect(head.hasPrefix("Date: Wed, 04 Nov 2026 10:00:00 +0000\r\n"))
        #expect(head.contains("\r\nFrom: \"Ann Example\" <ann@example.com>\r\n"))
        #expect(head.contains("\r\nSubject: Lease renewal\r\n"))
        #expect(head.contains("\r\nMessage-ID: <draft-1@sprava.example.com>\r\nMIME-Version: 1.0\r\nX-Unsent: 1\r\n"))
        #expect(head.contains("Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: quoted-printable"))
        #expect(!head.contains("In-Reply-To") && !head.contains("References") && !head.contains("Cc:"))
        #expect(!Self.text(d).replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let mail = Self.read(d)
        #expect(mail.subject == "Lease renewal")
        #expect(mail.from == "\"Ann Example\" <ann@example.com>")
        #expect(mail.to == "\"Bo Sample\" <bo@example.invalid>")
        #expect(Extractor.extract(d.rfc822, name: "draft.eml").text.contains("the form is attached."))
        #expect(!Self.text(try Self.draft()).contains("X-Unsent"))
    }

    @Test func nonASCIITextIsEncodedWordsFoldedAndReadsBack() throws {
        let d = try Self.draft(from: .init(name: "Óscar Ñandú", address: "oscar@example.com"),
                               subject: "Ürgent: Überweisung 🧾", body: "Grüße — ünd ein langer Satz, " + String(repeating: "ä", count: 80))
        let head = Self.headers(d)
        #expect(head.allSatisfy { $0.isASCII })
        #expect(head.components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        #expect(head.contains("Subject: =?UTF-8?B?"))
        let mail = Self.read(d)
        #expect(mail.subject == "Ürgent: Überweisung 🧾")
        #expect(mail.from == "Óscar Ñandú <oscar@example.com>")
        #expect(Self.text(d).components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        #expect(Extractor.extract(d.rfc822, name: "draft.eml").text.contains("Grüße — ünd ein langer Satz, " + String(repeating: "ä", count: 80)))
    }

    @Test func longSubjectsAndRecipientListsFoldWithoutLosingText() throws {
        let words = (1...30).map { "word\($0)" }.joined(separator: " ")
        let many = (1...8).map { MailDraft.Mailbox(name: "Person \($0)", address: "p\($0)@example.com") }
        let d = try Self.draft(to: many, cc: [.init(address: "cc@example.com")], subject: words)
        #expect(Self.headers(d).components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        #expect(Self.read(d).subject == words)
        #expect(Self.read(d).to == many.map { "\"\($0.name)\" <\($0.address)>" }.joined(separator: ", "))
        #expect(Self.headers(d).contains("\r\nCc: cc@example.com\r\n"))
        // A long non-ASCII subject is split into encoded words of whole characters, each decoding on its own.
        let long = String(repeating: "Ж€🧾", count: 40)
        let parts = MailDraft.encodedWords(long)
        #expect(parts.count > 1 && parts.allSatisfy { $0.count <= 75 })
        let decoded = parts.map { String(data: Data(base64Encoded: String($0.dropFirst(10).dropLast(2)))!, encoding: .utf8)! }
        #expect(decoded.joined() == long)
    }

    @Test func threadingHeadersAreWrittenAndChecked() throws {
        let refs = (1...6).map { "<thread-\($0)@mail.example.com>" }
        let d = try Self.draft(inReplyTo: "<thread-6@mail.example.com>", references: refs)
        let head = Self.headers(d)
        #expect(head.contains("\r\nIn-Reply-To: <thread-6@mail.example.com>\r\n"))
        #expect(head.contains("\r\nReferences: " + refs[0] + " " + refs[1] + "\r\n " + refs[2]))
        for bad in ["thread@example.com", "<thread@example.com", "<a b@example.com>", "<@example.com>", "<a@>", "<a@b@c>", "<a@x..y>", "<ä@example.com>"] {
            #expect(throws: MailDraft.Failure.messageID(field: "In-Reply-To")) { try Self.draft(inReplyTo: bad) }
            #expect(throws: MailDraft.Failure.messageID(field: "References")) { try Self.draft(references: [refs[0], bad]) }
            #expect(throws: MailDraft.Failure.messageID(field: "Message-ID")) { try Self.draft(messageID: bad) }
        }
    }

    @Test func headerInjectionIsRefused() throws {
        for evil in ["\r\nBcc: x@example.com", "\nBcc: x@example.com", "\rx", "a\u{0}b", "tab\there", "a\u{2028}b", "a\u{85}b"] {
            #expect(throws: MailDraft.Failure.headerText(field: "Subject")) { try Self.draft(subject: "Hi" + evil) }
            #expect(throws: MailDraft.Failure.headerText(field: "From")) { try Self.draft(from: .init(name: "Ann" + evil, address: "ann@example.com")) }
            #expect(throws: MailDraft.Failure.address(field: "To")) { try Self.draft(to: [.init(address: "bo@example.com" + evil)]) }
            #expect(throws: MailDraft.Failure.messageID(field: "Message-ID")) { try Self.draft(messageID: "<a@example.com>" + evil) }
            #expect(throws: MailDraft.Failure.filename(index: 0)) { try Self.draft(attachments: [.init(filename: "a" + evil + ".pdf", data: Data())]) }
        }
        #expect(throws: MailDraft.Failure.headerText(field: "To")) { try Self.draft(to: [.init(name: "Bo \u{202E}fdp.exe", address: "bo@example.com")]) }
        // A name cannot pose as an address.
        for name in ["landlord@real.example", "Landlord (landlord@real.example)", "landlord\u{FF20}real.example"] {
            #expect(throws: MailDraft.Failure.headerText(field: "To")) { try Self.draft(to: [.init(name: name, address: "bo@example.com")]) }
            #expect(throws: MailDraft.Failure.headerText(field: "From")) { try Self.draft(from: .init(name: name, address: "ann@example.com")) }
        }
        for bad in ["", "bo", "bo@", "a@b, c@d", "Bo <bo@example.com>", "a b@example.com", "bø@example.com", "a@x..com",
                    "=?UTF-8?B?Ym9AZXZpbC5leGFtcGxl?=@example.com", "bo%evil.example@example.com", "evil.example!bo@example.com"] {
            #expect(throws: MailDraft.Failure.address(field: "Cc")) { try Self.draft(cc: [.init(address: bad)]) }
        }
        // Quotes and backslashes in a plain name stay inside its quoted string; "=?" is never left to be decoded.
        let d = try Self.draft(from: .init(name: "Ann \"A\\B\" Example", address: "ann@example.com"), subject: "=?UTF-8?B?SGk=?=")
        #expect(Self.headers(d).contains("From: \"Ann \\\"A\\\\B\\\" Example\" <ann@example.com>"))
        #expect(Self.headers(d).contains("\r\nSubject: =?UTF-8?B?PT9VVEYtOD9CP1NHaz0/PQ==?=\r\n"))
    }

    @Test func attachmentsRoundTripWithTypesAndEncodedNames() throws {
        let pdf = Data((0..<5000).map { UInt8($0 % 251) })
        let note = Data("plain note\n".utf8)
        let long = String(repeating: "довгий файл ", count: 8) + ".txt"
        let d = try Self.draft(attachments: [.init(filename: "folder/../Rechnung März.pdf", data: pdf),
                                             .init(filename: "C:\\docs\\notes.txt", data: note),
                                             .init(filename: long, data: Data([0, 1, 2])),
                                             .init(filename: "blob.weird", data: Data())])
        let all = Self.text(d)
        #expect(all.components(separatedBy: "\r\n").allSatisfy { $0.count <= 78 })
        #expect(all.contains("Content-Type: application/pdf; name=\"Rechnung M_rz.pdf\""))
        #expect(all.contains("filename*=UTF-8''Rechnung%20M%C3%A4rz.pdf"))
        #expect(all.contains("Content-Type: text/plain; name=\"notes.txt\""))
        #expect(all.contains("Content-Type: application/octet-stream; name=\"blob.weird\""))
        #expect(all.contains("filename*0*=UTF-8''"))
        let mail = Self.read(d)
        #expect(mail.subject == "Lease renewal")
        #expect(mail.attachments.map(\.name) == ["Rechnung März.pdf", "notes.txt", long, "blob.weird"])
        #expect(mail.attachments.map(\.data) == [pdf, note, Data([0, 1, 2]), Data()])
        #expect(Extractor.extract(d.rfc822, name: "draft.eml").text.contains("the form is attached."))
        // The base64 itself, decoded by hand, is the same bytes, at 76 columns.
        let body = all.components(separatedBy: "\r\n\r\n")[3]
        #expect(body.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        #expect(Data(base64Encoded: body.components(separatedBy: "\r\n--")[0].replacingOccurrences(of: "\r\n", with: "")) == pdf)
        for bad in ["", "/", "..", "a/..", "x\u{202E}fdp.exe", String(repeating: "a", count: 256)] {
            #expect(throws: MailDraft.Failure.filename(index: 1)) { try Self.draft(attachments: [.init(filename: "ok.txt", data: note), .init(filename: bad, data: note)]) }
        }
    }

    @Test func limitsAreNamedNeverTruncated() throws {
        var limits = MailDraft.Limits()
        limits.attachmentBytes = 10
        #expect(throws: MailDraft.Failure.overLimit(.attachmentBytes)) {
            try Self.draft(attachments: [.init(filename: "a.txt", data: Data(count: 6)), .init(filename: "b.txt", data: Data(count: 5))], limits: limits)
        }
        _ = try Self.draft(attachments: [.init(filename: "a.txt", data: Data(count: 10))], limits: limits)
        limits.attachments = 1
        #expect(throws: MailDraft.Failure.overLimit(.attachments)) {
            try Self.draft(attachments: [.init(filename: "a.txt", data: Data()), .init(filename: "b.txt", data: Data())], limits: limits)
        }
        #expect(MailDraft.Limits().attachmentBytes == 18 * 1024 * 1024)
    }

    @Test func theBoundaryNeverOccursInsideAPart() throws {
        // Body text that spells the boundary is quoted-printable, so "=" becomes "=3D" and cannot match it.
        let body = "--=_Fixed0\n--=_Fixed0--\n"
        let d = try Self.draft(body: body, attachments: [.init(filename: "a.txt", data: Data(body.utf8))])
        #expect(d.boundary == "=_Fixed0")
        #expect(Self.text(d).components(separatedBy: "\r\n").filter { $0.hasPrefix("--=_Fixed0") } == ["--=_Fixed0", "--=_Fixed0", "--=_Fixed0--"])
        #expect(Self.read(d).attachments.first?.data == Data(body.utf8))
        // A file name holding the first token makes the writer take the next one.
        var tokens = ["Taken1", "Free2"]
        let named = try Self.draft(attachments: [.init(filename: "=_Taken1.txt", data: Data())], boundary: { tokens.removeFirst() })
        #expect(named.boundary == "=_Free2")
        #expect(throws: MailDraft.Failure.boundary) {
            try Self.draft(attachments: [.init(filename: "=_Taken1.txt", data: Data())], boundary: { "Taken1" })
        }
        #expect(throws: MailDraft.Failure.boundary) { try Self.draft(attachments: [.init(filename: "a.txt", data: Data())], boundary: { "a b" }) }
        // Without attachments there is no multipart and no boundary; by default the token is random.
        #expect(try Self.draft().boundary == nil)
        let random = try MailDraft(from: Self.me, to: [Self.you], subject: "s", body: "b", attachments: [.init(filename: "a.txt", data: Data())],
                                   messageID: "<r@example.com>", date: Self.day)
        #expect(random.boundary?.count == 34)
    }

    @Test func quotedPrintableKeepsLinesShortAndTrailingSpaceVisible() {
        let qp = MailDraft.quotedPrintable("a = b \r\n" + String(repeating: "x", count: 200) + "\rend\t")
        let lines = qp.components(separatedBy: "\r\n")
        #expect(lines.first == "a =3D b=20")
        #expect(lines.allSatisfy { $0.count <= 76 })
        #expect(lines.last == "end=09")
        #expect(Extractor.quotedPrintable(qp.replacingOccurrences(of: "\r\n", with: "\n")) == "a = b \n" + String(repeating: "x", count: 200) + "\nend\t")
    }
}

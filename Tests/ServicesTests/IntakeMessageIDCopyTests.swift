import BinderFormat
import BinderStore
import Capture
import Foundation
import Testing

/// The same email filed before, known by its Message-ID, From, Date and body however its bytes differ (D39). Invented
/// mail only.
extension IntakeCommandTests {
    /// A message as a mail monitor writes it: its text as `.md`, and the message itself as its original beside it.
    func importMail(_ s: Setup, _ base: String, id: String?, front: String = "", text: String = "Invented roof estimate.",
                    body: String = "Invented roof estimate.", received: String = "", crlf: Bool = false) throws {
        let mail = s.folder.appendingPathComponent("intake/mail")
        let attachments = mail.appendingPathComponent(base + " attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("---\nsubject: \"Roof estimate\"\n\(front)---\n\n\(text)\n".utf8).write(to: mail.appendingPathComponent(base + ".md"))
        try Data(rawMessage(id: id, body: body, received: received, crlf: crlf).utf8)
            .write(to: attachments.appendingPathComponent(IntakeWatcher.mailOriginalName))
    }

    func rawMessage(id: String?, body: String = "Invented roof estimate.", received: String = "", crlf: Bool = false,
                    from: String = "Invented Roofer <roofer@example.invalid>", date: String = "Thu, 2 Apr 2026 09:15:00 -0400",
                    subject: String = "Roof estimate", mime: String = "") -> String {
        let raw = received + "From: \(from)\nDate: \(date)\nSubject: \(subject)\n\(mime)"
            + (id.map { "Message-ID: \($0)\n" } ?? "") + "\n\(body)\n"
        return crlf ? raw.replacingOccurrences(of: "\n", with: "\r\n") : raw
    }

    /// Imports a message and files it under `documents/`, returning where its original went.
    func fileMail(_ s: Setup, _ base: String, id: String?, body: String = "Invented roof estimate.") throws -> URL {
        try importMail(s, base, id: id, body: body)
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        let paths = (Teka.read(s.folder).catalog?["documents"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }
        return s.folder.appendingPathComponent(try #require(paths.first { $0.hasPrefix("documents/") && $0.hasSuffix(".eml") }))
    }

    /// Fetched again, the same email has another text, other front matter, another trace header and other line
    /// endings: still a copy.
    @Test func theSameEmailImportedTwiceIsACopy() throws {
        let s = try setup()
        _ = try fileMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>")
        try importMail(s, "2026-04-09_7_roof", id: "<roof.1@mail.example.invalid>", front: "from: \"roofer@example.invalid\"\n",
                       text: "Invented roof estimate, rendered another way.", received: "Received: from relay.example.invalid\n", crlf: true)
        try card(s)
        #expect(open(s).isEmpty)
        #expect(try copies(s) == ["intake/mail/2026-04-09_7_roof.md"])
        #expect(exists(s, "intake/mail/2026-04-09_7_roof.md"))
    }

    /// An email saved by hand is filed as itself: its header is read from the file, its id folded and spelled another
    /// way, other headers around it.
    @Test func aDroppedEmailWhoseIDIsFiledIsACopy() throws {
        let s = try setup()
        _ = try fileMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>")
        try drop(s, "saved roof.eml", "X-Saved-By: an invented mail program\nMessage-Id:\n  <roof.1@mail.example.invalid>\n"
            + "Date: Thu, 2 Apr 2026 09:15:00 -0400\nSubject: Roof estimate\nFrom: Invented Roofer <roofer@example.invalid>\n\nInvented roof estimate.\n")
        try drop(s, "other roof.eml", rawMessage(id: "<roof.2@mail.example.invalid>"))
        try card(s)
        #expect(try copies(s) == ["intake/saved roof.eml"])
        // A different id is a different email, however alike the rest.
        #expect(open(s).count == 1)
    }

    /// Anyone who received an email knows its id, sender and date, and the sender proves nothing: a message that copies
    /// them with another date, sender or body gets its card. The same with CRLF line endings is the same email.
    @Test func theSameIDWithAnotherDateSenderOrBodyIsANewEmail() throws {
        let s = try setup()
        _ = try fileMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>")
        try drop(s, "later.eml", rawMessage(id: "<roof.1@mail.example.invalid>", date: "Fri, 3 Apr 2026 10:00:00 -0400"))
        try drop(s, "other sender.eml", rawMessage(id: "<roof.1@mail.example.invalid>", from: "Someone Else <else@example.invalid>"))
        try drop(s, "other body.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: "Invented roof estimate. Pay to an invented account."))
        try drop(s, "saved again.eml", rawMessage(id: "<roof.1@mail.example.invalid>", crlf: true))
        try card(s)
        #expect(try copies(s) == ["intake/saved again.eml"])
        #expect(open(s).count == 3)
    }

    /// Imports a message whose original is `raw` and files it under `documents/`.
    func fileOriginal(_ s: Setup, _ raw: String) throws {
        try importMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>")
        let original = s.folder.appendingPathComponent("intake/mail/2026-04-02_1_roof attachments/" + IntakeWatcher.mailOriginalName)
        try Data(raw.utf8).write(to: original)
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
    }

    /// Where a CR is data, under the binary transfer encoding or standing alone, it is never taken for an LF.
    @Test func aCRThatIsDataIsNeverEvenedOut() throws {
        let s = try setup()
        let binary = "MIME-Version: 1.0\nContent-Type: application/octet-stream\nContent-Transfer-Encoding: binary\n"
        try fileOriginal(s, rawMessage(id: "<roof.1@mail.example.invalid>", body: "ABC\nDEF", mime: binary))
        try drop(s, "binary cr.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: "ABC\rDEF", mime: binary))
        try drop(s, "binary crlf.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: "ABC\nDEF", crlf: true, mime: binary))
        try drop(s, "binary same.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: "ABC\nDEF", mime: binary))
        try card(s)
        #expect(try copies(s) == ["intake/binary same.eml"])
        #expect(open(s).count == 2)
    }

    /// A lone CR in a 7bit body is not a line break either.
    @Test func aLoneCRIn7bitIsNotAnLF() throws {
        let s = try setup()
        let sevenBit = "MIME-Version: 1.0\nContent-Type: text/plain\nContent-Transfer-Encoding: 7bit\n"
        try fileOriginal(s, rawMessage(id: "<roof.1@mail.example.invalid>", body: "ABC\nDEF", mime: sevenBit))
        try drop(s, "lone cr.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: "ABC\rDEF", mime: sevenBit))
        try drop(s, "crlf.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: "ABC\nDEF", crlf: true, mime: sevenBit))
        try card(s)
        #expect(try copies(s) == ["intake/crlf.eml"])
        #expect(open(s).count == 1)
    }

    /// The same raw body under another subject, or read in another transfer encoding, is another email.
    @Test func anotherSubjectOrEncodingIsANewEmail() throws {
        let s = try setup()
        let mime = "MIME-Version: 1.0\nContent-Type: text/plain; charset=us-ascii\nContent-Transfer-Encoding: 7bit\n"
        let body = "=4F=70=65=6E"
        try fileOriginal(s, rawMessage(id: "<roof.1@mail.example.invalid>", body: body, mime: mime))
        try drop(s, "other subject.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: body, subject: "Roof estimate, revised", mime: mime))
        try drop(s, "other encoding.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: body,
                                                    mime: mime.replacingOccurrences(of: "7bit", with: "quoted-printable")))
        try drop(s, "same.eml", rawMessage(id: "<roof.1@mail.example.invalid>", body: body, crlf: true, mime: mime))
        try card(s)
        #expect(try copies(s) == ["intake/same.eml"])
        #expect(open(s).count == 2)
    }

    /// A forgery that came first and was filed never hides the real email arriving after it.
    @Test func aFiledForgeryNeverHidesTheRealEmail() throws {
        let s = try setup()
        _ = try fileMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>", body: "Pay to an invented account.")
        try importMail(s, "2026-04-02_2_roof", id: "<roof.1@mail.example.invalid>")
        try card(s)
        #expect(try copies(s).isEmpty)
        #expect(open(s).count == 1)
    }

    /// The filed original as it is now decides, as its bytes do for an exact copy: an edit to its body gives the copy
    /// its card.
    @Test func aFiledOriginalWithAnotherBodyNoLongerMatches() throws {
        let s = try setup()
        let filed = try fileMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>")
        try drop(s, "saved roof.eml", rawMessage(id: "<roof.1@mail.example.invalid>", crlf: true))
        try card(s)
        #expect(try copies(s) == ["intake/saved roof.eml"])
        try Data(rawMessage(id: "<roof.1@mail.example.invalid>", body: "Edited after filing.").utf8).write(to: filed)
        try card(s)
        #expect(try copies(s).isEmpty)
        #expect(open(s).count == 1)
    }

    /// And so does an edit to its id.
    @Test func aFiledOriginalWithAnotherIDNoLongerMatches() throws {
        let s = try setup()
        let filed = try fileMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>")
        try drop(s, "saved roof.eml", rawMessage(id: "<roof.1@mail.example.invalid>", crlf: true))
        try card(s)
        #expect(try copies(s) == ["intake/saved roof.eml"])
        try Data(rawMessage(id: "<roof.9@mail.example.invalid>").utf8).write(to: filed)
        try card(s)
        #expect(try copies(s).isEmpty)
        #expect(open(s).count == 1)
    }

    /// Without a Message-ID only the bytes count, as before: another rendering gets a card, the same bytes do not.
    @Test func aMessageWithNoIDIsJudgedByItsBytes() throws {
        let s = try setup()
        _ = try fileMail(s, "2026-04-02_1_roof", id: nil)
        try drop(s, "other bytes.eml", rawMessage(id: nil, crlf: true))
        try drop(s, "same bytes.eml", rawMessage(id: nil))
        try card(s)
        #expect(try copies(s) == ["intake/same bytes.eml"])
        #expect(open(s).count == 1)
        // A filed message with no id matches no id in intake either.
        try drop(s, "with id.eml", rawMessage(id: "<roof.1@mail.example.invalid>", crlf: true))
        try card(s)
        #expect(open(s).count == 2)
    }

    /// A card already waiting goes once the same email is filed through another card, saying why.
    @Test func aWaitingCardGoesOnceTheSameEmailIsFiled() throws {
        let s = try setup()
        try importMail(s, "2026-04-02_1_roof", id: "<roof.1@mail.example.invalid>")
        try drop(s, "saved roof.eml", rawMessage(id: "<roof.1@mail.example.invalid>", crlf: true))
        try card(s)
        let cards = open(s)
        #expect(cards.count == 2)
        let message = try #require(cards.first { $0.ops.contains { $0["args"]?["from"]?.stringValue?.hasSuffix(".md") == true } })
        #expect(try approve(s, message, folder: "documents")["ok"] == .bool(true))
        try card(s)
        #expect(open(s).isEmpty)
        #expect(try copies(s) == ["intake/saved roof.eml"])
        let other = ProposalStore.list(in: s.folder).map(\.0).first { $0.id != message.id && cards.map(\.id).contains($0.id) }
        #expect(other?.state == "rejected")
    }
}

@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// Mail the person wrote asks things of others: it is read and filed, but proposes none of their to-dos (issue #594).
/// Scripted models only; invented addresses and text only.
@Suite struct OwnMailTests {
    /// Noon UTC on 2026-10-08: the same calendar day in every time zone the tests run in.
    let now = Date(timeIntervalSince1970: 1_791_460_800)
    let mine: Set<String> = ["me@example.invalid"]

    // MARK: - The address parser

    @Test func bareAddressesComeOutOfDisplayNamesAndAngleBrackets() {
        #expect(MailAddress.bare(in: "Invented Person <Me@Example.Invalid>") == ["me@example.invalid"])
        #expect(MailAddress.bare(in: "me@example.invalid") == ["me@example.invalid"])
        #expect(MailAddress.bare(in: "\"Doe, Jane\" <jane@example.com>, b@example.com") == ["jane@example.com", "b@example.com"])
        #expect(MailAddress.bare(in: "\"Quoted <x@example.com>\" <real@example.com>") == ["real@example.com"])
        #expect(MailAddress.bare(in: "c@example.com (Invented Supplier), C@EXAMPLE.COM") == ["c@example.com"])
        #expect(MailAddress.bare(in: "Invented Team: a@example.com, b@example.com;") == ["a@example.com", "b@example.com"])
    }

    /// A header cut short could end inside an address, and an unclosed angle bracket holds none.
    @Test func aCutOrUnclosedHeaderGivesNoAddress() {
        #expect(MailAddress.bare(in: "(" + String(repeating: "x", count: 16_362) + ") <me@example.invalid.other.invalid>").isEmpty)
        #expect(MailAddress.bare(in: "Someone <me@example.invalid").isEmpty)
        #expect(MailAddress.bare(inRaw: "=?utf-8?q?a,b@example.com?= <c@example.com>, d@example.com") == ["c@example.com", "d@example.com"])
        // An encoded word is never part of an address, so one inside or against an address leaves no address.
        #expect(MailAddress.bare(inRaw: "<=?utf-8?q?stranger?=me@example.invalid>").isEmpty)
        #expect(MailAddress.bare(inRaw: "=?utf-8?q?stranger?=me@example.invalid").isEmpty)
        #expect(MailAddress.bare(inRaw: "\"Jane =?utf-8?q?D?= Doe\" <jane@example.com>") == ["jane@example.com"])
    }

    @Test func junkGivesNoAddress() {
        for junk in ["", "Invented Person", "undisclosed-recipients:;", "<>", "a@", "@example.com", "a@@example.com",
                     "a b@example.com <", "a@example..com", "<a@.example.com>", "\u{0}a@example.com",
                     String(repeating: "a", count: 65) + "@example.com", "a@" + String(repeating: "b", count: 260) + ".com"] {
            #expect(MailAddress.bare(in: junk).isEmpty, "\(junk.debugDescription)")
        }
        #expect(MailAddress.single("me@example.invalid, other@example.com") == nil)
        #expect(MailAddress.single(" Me@Example.Invalid ") == "me@example.invalid")
        // One address and nothing else: a second word or a display name is refused, never cut down to the first address.
        #expect(MailAddress.single("first@example.com second@example.com") == nil)
        #expect(MailAddress.single("Invented Person <me@example.invalid>") == nil)
        // Lengths are those of the address as kept, lower case: one that grows past them when lowered is refused, so
        // nothing stored can fail its own check later.
        let growing = String(repeating: "a", count: 40) + String(repeating: "\u{130}", count: 12) + "@example.com"
        #expect(MailAddress.single(growing) == nil)
        for kept in ["me@example.invalid", "\u{130}x@example.com"] {
            let stored = MailAddress.single(kept)
            #expect(stored != nil && MailAddress.single(stored!) == stored)
        }
    }

    // MARK: - The reading

    func read(from: String, to: String?, text: String, reply: Bool = true, fromHeader: String? = nil, toHeader: String? = nil) async
        -> (DocumentReading, ScriptedModel) {
        let ask = JSONValue.obj([("quote", .str("Could you please send the invoice")), ("title", .str("Send the invoice")),
                                 ("action", .str("send")), ("when_text", .str("this week"))])
        let model = ScriptedModel(extractions: [.obj([("items", .array([ask]))])])
        model.document = .obj([("class", .str("action")), ("title", .str("")), ("date_text", .str("")),
                               ("summary", .str("An email asking for an invoice.")), ("reply_needed", .bool(reply))])
        var reading = IntakeReading(kind: "email", textFrom: "parsed", text: text, channel: "email")
        reading.from = from
        reading.to = to
        reading.fromHeader = fromHeader
        reading.toHeader = toHeader
        reading.subject = "Invoice"
        let doc = await Clerk(model: model).readDocument(reading, name: "mail/invoice.eml", binder: nil, locale: "en",
                                                         ownAddresses: mine, now: now)
        return (doc, model)
    }

    let text = "Could you please send the invoice this week? Let me know if anything is missing."

    @Test func mailFromThePersonProposesNoToDosAndSaysToWhom() async {
        let (doc, model) = await read(from: "Invented Person <ME@example.invalid>", to: "Invented Supplier <supplier@example.com>", text: text)
        #expect(doc.items.isEmpty)
        #expect(!doc.replyNeeded)
        #expect(doc.escalate.isEmpty)
        #expect(doc.fromPerson)
        #expect(doc.wroteTo == ["supplier@example.com"])
        #expect(doc.summary == "You wrote this to supplier@example.com, so no to-dos are proposed from it. An email asking for an invoice.")
        #expect(doc.json["from_person"] == .bool(true))
        #expect(doc.json["reply_needed"] == .bool(false))
        // Only the reading of what it is: no call looks for items in it.
        #expect(model.prompts.count == 1)
        #expect(doc.calls == 1)
    }

    @Test func manyRecipientsAreCountedAndNoneIsSaidPlainly() async {
        let (many, _) = await read(from: "me@example.invalid", to: "a@example.com, b@example.com, c@example.com, d@example.com, e@example.com", text: text)
        #expect(many.summary?.hasPrefix("You wrote this to a@example.com, b@example.com, c@example.com and 2 more, so no to-dos") == true)
    }

    /// A note the person mailed only to themselves, or to no one named, holds their own to-dos: it is read as before.
    @Test func aNoteToSelfIsReadAsBefore() async {
        let (toSelf, _) = await read(from: "me@example.invalid", to: "Invented Person <ME@example.invalid>", text: text)
        #expect(!toSelf.fromPerson && toSelf.items.map(\.action) == ["send"])
        let (none, _) = await read(from: "me@example.invalid", to: nil, text: text)
        #expect(!none.fromPerson && none.items.map(\.action) == ["send"])
    }

    @Test func mailFromSomeoneElseIsReadAsBefore() async {
        let (doc, _) = await read(from: "Invented Supplier <supplier@example.com>", to: "me@example.invalid", text: text)
        #expect(!doc.fromPerson)
        #expect(doc.json["from_person"] == nil)
        #expect(doc.summary == "An email asking for an invoice.")
        #expect(doc.items.map(\.action) == ["send"])
        #expect(doc.replyNeeded)
        #expect(doc.escalate.contains("a reply may be needed"))
    }

    /// A stranger can encode a display name that decodes to "me@example.invalid,": decoded first, From read as the
    /// person's address and then the stranger's. Read as written, as a mail program reads it, it is the stranger's.
    @Test func whoseMailItIsIsReadFromTheHeadersAsWritten() async {
        // To names someone else too, so the decoded From alone would have made it the person's mail to them.
        let to = "me@example.invalid, colleague@example.net"
        for header in ["=?utf-8?q?me@example.invalid=2C?= <supplier@example.com>",
                       "=?utf-8?Q?=22,me@example.invalid,=22?= <supplier@example.com>"] {
            let (forged, _) = await read(from: "me@example.invalid, <supplier@example.com>", to: to, text: text, fromHeader: header, toHeader: to)
            #expect(!forged.fromPerson && forged.items.map(\.action) == ["send"], "\(header)")
        }
        // The person's own mail, with an encoded name, is still theirs.
        let (own, _) = await read(from: "Me <me@example.invalid>", to: "Supplier <supplier@example.com>", text: text,
                                  fromHeader: "=?utf-8?q?Me?= <me@example.invalid>", toHeader: "=?utf-8?q?Supplier?= <supplier@example.com>")
        #expect(own.fromPerson && own.wroteTo == ["supplier@example.com"])
    }

    @Test func withNoOwnAddressesNothingChanges() async {
        let model = ScriptedModel(extractions: [])
        model.document = .obj([("class", .str("action")), ("title", .str("")), ("date_text", .str("")),
                               ("summary", .str("An email.")), ("reply_needed", .bool(true))])
        var reading = IntakeReading(kind: "email", textFrom: "parsed", text: text, channel: "email")
        reading.from = "me@example.invalid"
        let doc = await Clerk(model: model).readDocument(reading, name: "mail/a.eml", binder: nil, locale: "en", now: now)
        #expect(!doc.fromPerson)
        // The reply item code adds when the mail asks for one.
        #expect(doc.items.contains { $0.flags.contains("added by code: the document asks for a reply") })
    }
}

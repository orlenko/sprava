import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// The conversation proposes an email draft only on a card the person approves; nothing is sent (decisions.md D41).
/// A real adopted binder and op log; invented mail only.
@Suite struct ProposeDraftToolTests {
    typealias Turn = ClaudeTodoToolsTests.Turn

    func connect(_ s: PSetup) throws {
        let account = try #require(IMAPAccount(host: "mail.example.invalid", port: 993, security: .tls, user: "me@example.invalid"))
        _ = try BinderIMAPConnections(support: s.support, hash: { "fixture" }).configure(folder: s.folder, account: account, mailbox: "INBOX")
    }

    let fields: [(String, JSONValue)] = [("to", .array([.str("supplier@example.com")])), ("subject", .str("Invoice for October")),
                                         ("body", .str("Hello,\n\nCould you send the invoice?\n"))]

    @Test func aDraftIsACardSpravaWroteAndNothingElseChanges() throws {
        let s = try pSetup(); try connect(s)
        let turn = try Turn(s)
        let before = turn.ops.count
        let answer = turn.call("propose_email_draft", fields)
        #expect(!answer.refused, "\(answer.content)")
        let id = try #require(answer.content["card"]?.stringValue)
        let card = try #require(ProposalStore.list(in: s.folder).first { $0.0.id == id }?.0)
        #expect(card.state == "proposed" && DraftCard(card)?.subject == "Invoice for October")
        // Recorded as a draft Sprava wrote, so the person can approve it; nothing applied, nothing queued.
        #expect(DraftCardRecord(support: s.support).contains(s.commands.key(s.folder, id)))
        #expect(turn.ops.count == before)
        #expect(DraftRequests(support: s.support).all().isEmpty)
    }

    @Test func whatCannotBeAnEmailOrHasNowhereToGoIsRefused() throws {
        let s = try pSetup()
        let turn = try Turn(s)
        // No email connection: nowhere to go.
        let none = turn.call("propose_email_draft", fields)
        #expect(none.refused && none.content["message"]?.stringValue?.contains("no email connection") == true)
        try connect(s)
        for (bad, words) in [([("to", JSONValue.array([.str("not an address")])), ("subject", .str("x")), ("body", .str("x"))], "cannot be written"),
                             ([("to", .array([.str("a@example.com")])), ("subject", .str("x")), ("body", .str("x")), ("attachments", .array([.str("../outside.txt")]))], "not a document filed"),
                             ([("to", .array([.str("a@example.com")])), ("body", .str("x"))], "subject and body")] {
            let answer = turn.call("propose_email_draft", bad)
            #expect(answer.refused && answer.content["message"]?.stringValue?.contains(words) == true, "\(answer.content)")
        }
        #expect(ProposalStore.list(in: s.folder).allSatisfy { DraftCard($0.0) == nil })
        // At most five a turn.
        for _ in 0..<ClaudeTodoTools.maximumDrafts { #expect(!turn.call("propose_email_draft", fields).refused) }
        #expect(turn.call("propose_email_draft", fields).refused)
    }
}

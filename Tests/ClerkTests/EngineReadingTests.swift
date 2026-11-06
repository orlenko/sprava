@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// An engine reads a whole intake document in one call, in the clerk's place, and code checks what it says
/// (decisions.md D40). Scripted engines only; invented addresses and text only.
@Suite struct EngineReadingTests {
    /// Noon UTC on 2026-10-08: the same calendar day in every time zone the tests run in.
    let now = Date(timeIntervalSince1970: 1_791_460_800)
    let mine: Set<String> = ["me@example.invalid"]
    let text = "Invoice request\nCould you please send the invoice this week? I will call you on Friday about the delivery. Let me know if anything is missing."

    final class ScriptedEngine: DocumentEngine, @unchecked Sendable {
        let name = "Claude"
        var reply: Result<JSONValue, any Error>
        var instructions: [String] = []
        var prompts: [String] = []
        init(_ reply: Result<JSONValue, any Error>) { self.reply = reply }
        func answer(instructions: String, prompt: String) async throws -> JSONValue {
            self.instructions.append(instructions)
            prompts.append(prompt)
            return try reply.get()
        }
    }

    struct Leaky: Error, CustomStringConvertible { var description: String { "the invoice text" } }

    static func item(_ quote: String, _ title: String, _ action: String, when: String = "") -> JSONValue {
        .obj([("quote", .str(quote)), ("title", .str(title)), ("action", .str(action)), ("when_text", .str(when))])
    }

    static func answer(summary: String = "A supplier asks for an invoice this week.", reply: Bool = false, items: [JSONValue]) -> JSONValue {
        .obj([("class", .str("action")), ("title", .str("Invoice request")), ("date_text", .str("")), ("summary", .str(summary)),
              ("reply_needed", .bool(reply)), ("items", .array(items))])
    }

    func read(_ engine: ScriptedEngine, from: String = "Invented Supplier <supplier@example.com>", to: String? = "me@example.invalid",
              text: String? = nil) async -> (DocumentReading, ScriptedModel) {
        let model = ScriptedModel(extractions: [])
        model.document = .obj([("class", .str("action")), ("title", .str("")), ("date_text", .str("")),
                               ("summary", .str("The clerk's summary.")), ("reply_needed", .bool(false))])
        var reading = IntakeReading(kind: "email", textFrom: "parsed", text: text ?? self.text, channel: "email")
        reading.from = from
        reading.to = to
        reading.subject = "Invoice"
        let doc = await Clerk(model: model).readDocument(reading, name: "mail/invoice.eml", binder: nil, locale: "en",
                                                         ownAddresses: mine, engine: engine, now: now)
        return (doc, model)
    }

    @Test func theEnginesCheckedReadingIsTheCardsAndTheClerkIsNotAsked() async {
        let engine = ScriptedEngine(.success(Self.answer(items: [Self.item("Could you please send the invoice", "Send the invoice", "send", when: "this week")])))
        let (doc, model) = await read(engine)
        #expect(doc.readBy == "Claude" && doc.model == "Claude")
        #expect(doc.summary == "A supplier asks for an invoice this week.")
        #expect(doc.title == "Invoice request")
        #expect(doc.items.map(\.action) == ["send"])
        #expect(doc.items.first?.title.lowercased().contains("send the invoice") == true)
        #expect(doc.outcome == "complete" && doc.escalate.isEmpty)
        #expect(doc.json["read_by"] == .string("Claude"))
        #expect(model.prompts.isEmpty)
        #expect(engine.prompts.count == 1 && doc.calls == 1)
        #expect(engine.instructions[0].contains("The person received this document."))
    }

    /// An item whose quote is not in the document is dropped, as for the clerk, and the reading says it is partial.
    @Test func anItemCodeCannotFindIsDropped() async {
        let engine = ScriptedEngine(.success(Self.answer(items: [
            Self.item("Could you please send the invoice", "Send the invoice", "send"),
            Self.item("Wire the full balance to account", "Wire the balance", "pay"),
        ])))
        let (doc, _) = await read(engine)
        #expect(doc.items.map(\.action) == ["send"])
        #expect(doc.dropped == 1 && doc.outcome == "partial")
    }

    @Test func aFailedCallFallsBackToTheClerkAndNamesOnlyTheKind() async {
        for (error, kind) in [(ClerkModelError.unavailable("x") as any Error, "unavailable(\"x\")"), (Leaky(), "Leaky")] {
            let (doc, model) = await read(ScriptedEngine(.failure(error)))
            #expect(doc.readBy == nil && doc.model == "scripted")
            #expect(doc.engineFailure == kind)
            #expect(doc.summary == "The clerk's summary.")
            #expect(!model.prompts.isEmpty)
            #expect(doc.json["engine_failure"] == .string(kind))
        }
    }

    /// An answer with no summary, or without its list of items, is no reading: the clerk reads the document.
    @Test func anAnswerWithNoSummaryOrItemsFallsBack() async {
        let noItems = JSONValue.obj([("class", .str("action")), ("summary", .str("A supplier asks for an invoice."))])
        let notAList = JSONValue.obj([("class", .str("action")), ("summary", .str("A supplier asks for an invoice.")), ("items", .str("none"))])
        for bad in [JSONValue.array([]), .obj([("class", .str("action"))]), Self.answer(summary: "   ", items: []), noItems, notAList] {
            let (doc, _) = await read(ScriptedEngine(.success(bad)))
            #expect(doc.readBy == nil && doc.engineFailure == "badAnswer")
        }
    }

    /// Mail the person wrote: the engine is told so and gets none of their addresses, and what it finds they promised
    /// is proposed.
    @Test func ownMailIsReadForWhatThePersonPromised() async {
        let engine = ScriptedEngine(.success(Self.answer(summary: "The person asks a supplier for an invoice and will call on Friday.", reply: true,
                                                         items: [Self.item("I will call you on Friday", "Call about the delivery", "call", when: "Friday")])))
        let (doc, _) = await read(engine, from: "Invented Person <ME@example.invalid>", to: "supplier@example.com")
        #expect(doc.fromPerson && doc.wroteTo == ["supplier@example.com"])
        #expect(doc.summary == "You wrote this to supplier@example.com. The person asks a supplier for an invoice and will call on Friday.")
        #expect(doc.items.map(\.action) == ["call"])
        #expect(!doc.replyNeeded)
        #expect(engine.instructions[0].contains("Code found that the person wrote this message to others."))
        #expect(!engine.prompts[0].lowercased().contains("me@example.invalid"))
        #expect(!engine.instructions[0].lowercased().contains("me@example.invalid"))
    }

    /// A reply the document asks for is added by code when the engine lists none.
    @Test func aReplyItemIsAddedByCode() async {
        let (doc, _) = await read(ScriptedEngine(.success(Self.answer(reply: true, items: []))))
        #expect(doc.items.contains { $0.flags.contains("added by code: the document asks for a reply") })
    }

    /// A dated request the engine left out is named on the card and makes the reading partial, as for the clerk.
    @Test func aDatedRequestTheEngineLeftOutIsNamed() async {
        let note = "Notes for the week.\nPlease return the signed form by December 1, 2026."
        let (doc, _) = await read(ScriptedEngine(.success(Self.answer(items: []))), from: "me@example.invalid", to: "me@example.invalid", text: note)
        #expect(doc.items.isEmpty)
        #expect(doc.notCovered.map(\.text) == ["Please return the signed form by December 1, 2026."])
        #expect(doc.outcome == "partial")
        // In mail the person wrote to others, it is a request of them.
        let (sent, _) = await read(ScriptedEngine(.success(Self.answer(items: []))), from: "me@example.invalid", to: "supplier@example.com", text: note)
        #expect(sent.notCovered.isEmpty && sent.outcome == "complete")
    }

    /// The document's own words asking for a reply add the reply item even when the engine says none is needed.
    @Test func aReplyTheDocumentAsksForIsAddedWhateverTheEngineSays() async {
        let (doc, _) = await read(ScriptedEngine(.success(Self.answer(reply: false, items: []))), text: "Please reply to confirm the date.")
        #expect(doc.items.contains { $0.flags.contains("added by code: the document asks for a reply") })
    }

    /// Items listed past those read make the reading partial, whatever was kept from the rest.
    @Test func itemsListedPastThoseReadMakeItPartial() async {
        let notes = (0..<Clerk.engineItems).map { _ in Self.item("Could you please send the invoice", "Send the invoice", "note") }
        let (doc, _) = await read(ScriptedEngine(.success(Self.answer(items: notes + [Self.item("I will call you on Friday", "Call", "call")]))))
        #expect(!doc.items.contains { $0.action == "call" } && doc.dropped == 0)
        #expect(doc.outcome == "partial")
    }

    @Test func aLongDocumentIsSentInPartAndSaysSo() async {
        let long = text + " " + String(repeating: "Background words of the minutes. ", count: 5_000)
        let engine = ScriptedEngine(.success(Self.answer(items: [])))
        let (doc, _) = await read(engine, text: long)
        #expect(engine.prompts[0].count < Clerk.engineCharacters + 1_000)
        #expect(doc.unread == 1 && doc.outcome == "partial")
    }

    @Test func atMostTheCardsItemsAreKept() async {
        let many = (0..<12).map { i in "Please sign form \(i) by Friday." }.joined(separator: " ")
        let items = (0..<12).map { i in Self.item("Please sign form \(i) by Friday", "Sign form \(i)", "other", when: "Friday") }
        let (doc, _) = await read(ScriptedEngine(.success(Self.answer(items: items))), text: many)
        #expect(doc.items.count == Clerk.documentItems)
        #expect(doc.outcome == "partial")
    }
}

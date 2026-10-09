@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// Regressions for text the model answers with its six-item ceiling and that cannot be read again in halves: the
/// items read from it carry "the clerk may have missed items here", so a seventh action in the same sentence is
/// never lost without a word. Scripted models only; invented data only.
@Suite(.serialized) struct ClerkCappedTests {
    let today = CalendarDate(year: 2026, month: 10, day: 8)!
    /// Noon UTC on 2026-10-08: the same calendar day in every time zone the tests run in.
    let now = Date(timeIntervalSince1970: 1_791_460_800)
    let long = "Call the invented bank, pay the invented fee, send the invented form, meet the invented agent, "
        + "file the invented claim, decide on the invented offer and email the invented notary."

    func item(_ quote: String, _ title: String, _ action: String) -> JSONValue {
        .obj([("quote", .string(quote)), ("title", .string(title)), ("action", .string(action))])
    }

    /// Six of the seven actions, each quoting the one long sentence.
    var six: [JSONValue] {
        [("Call the bank", "call"), ("Pay the fee", "pay"), ("Send the form", "send"), ("Meet the agent", "meet"),
         ("File the claim", "file"), ("Decide on the offer", "decide")].map { item("Call the invented bank", $0.0, $0.1) }
    }

    func input(_ text: String) -> ClerkInput {
        ClerkInput(id: "evt-capped", text: text, locale: "en", captureDay: today, estimated: false, isPrivate: false, sourceKind: nil, app: "test")
    }

    @Test func anUnsplittableFullWindowFlagsItsItems() async {
        let model = ScriptedModel(extractions: [.obj([("items", .array(six))])])
        let interp = await Clerk(model: model).read(input(long), filing: [], hint: nil, now: now)
        #expect(interp.items.count == 6)
        #expect(interp.unfiled.isEmpty)   // the sentence is covered, so coverage alone would say nothing
        #expect(interp.outcome == "partial")
        #expect(interp.items.allSatisfy { $0.flags.contains(Clerk.cappedFlag) })
        // The flag reaches the card the person reviews.
        let cards = Clerk.proposals(interp, event: input(long), today: today, client: "test", now: now)
        #expect(cards.count == 1)
        #expect(cards.first?.1.ops.allSatisfy { $0["card"]?["flags"]?.arrayValue?.contains(.string(Clerk.cappedFlag)) == true } == true)
    }

    @Test func aWindowUnderTheCeilingIsNotFlagged() async {
        let model = ScriptedModel(extractions: [.obj([("items", .array(Array(six.prefix(5))))])])
        let interp = await Clerk(model: model).read(input(long), filing: [], hint: nil, now: now)
        #expect(interp.items.count == 5)
        #expect(interp.items.allSatisfy { !$0.flags.contains(Clerk.cappedFlag) })
    }

    @Test func aFullSecondReadingFlagsItsItems() async {
        // The first reading covers only the first sentence; the second reading of the rest returns six items.
        let text = "Call the invented bank. Pay the invented fee. Send the invented form. Meet the invented agent. "
            + "File the invented claim. Decide on the invented offer. Email the invented notary."
        let rest = [("Pay the invented fee", "Pay the fee", "pay"), ("Send the invented form", "Send the form", "send"),
                    ("Meet the invented agent", "Meet the agent", "meet"), ("File the invented claim", "File the claim", "file"),
                    ("Decide on the invented offer", "Decide on the offer", "decide"), ("Email the invented notary", "Email the notary", "send")]
        let model = ScriptedModel(extractions: [.obj([("items", .array([item("Call the invented bank", "Call the bank", "call")]))]),
                                                .obj([("items", .array(rest.map { item($0.0, $0.1, $0.2) }))])])
        let interp = await Clerk(model: model).read(input(text), filing: [], hint: nil, now: now)
        #expect(interp.items.count == 7)
        #expect(interp.outcome == "partial")
        #expect(interp.items.first?.flags.contains(Clerk.cappedFlag) == false)
        #expect(interp.items.dropFirst().allSatisfy { $0.flags.contains(Clerk.cappedFlag) })
    }

    @Test func aDocumentWithAnUnsplittableFullWindowIsPartialAndEscalated() async {
        let model = ScriptedModel(extractions: [.obj([("items", .array(six))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Invented notice")), ("date_text", .str("")),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: long, channel: "other")
        let doc = await Clerk(model: model).readDocument(reading, name: "notice.txt", binder: nil, locale: "en", now: now)
        #expect(doc.items.count == 6)
        #expect(doc.outcome == "partial")
        #expect(doc.escalate.contains("the clerk may have missed items in it"))
        #expect(doc.items.allSatisfy { $0.flags.contains(Clerk.cappedFlag) })
    }
}

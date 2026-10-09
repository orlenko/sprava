import BinderStore
@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// Regressions from the second review of the clerk's layer (distinct payments merged, a waiting item's reminder
/// overwritten, recurring completions without a card, repeated completions, uncovered document obligations, US dollars
/// read as Canadian). Scripted models only; invented data only.
@Suite(.serialized) struct ClerkLayerReview2Tests {
    let today = CalendarDate(year: 2026, month: 10, day: 8)!
    /// Noon UTC on 2026-10-08: the same calendar day in every time zone the tests run in.
    let now = Date(timeIntervalSince1970: 1_791_460_800)
    let nov1 = CalendarDate(year: 2026, month: 11, day: 1)

    func item(_ quote: String, _ title: String, _ action: String, when: String? = nil, amount: String? = nil) -> JSONValue {
        var fields: [(String, JSONValue)] = [("quote", .string(quote)), ("title", .string(title)), ("action", .string(action))]
        if let when { fields.append(("when_text", .string(when))) }
        if let amount { fields.append(("amount_text", .string(amount))) }
        return .obj(fields)
    }

    func read(_ text: String, items: [JSONValue]) async -> DocumentReading {
        let model = ScriptedModel(extractions: [.obj([("items", .array(items))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Invented notice")), ("date_text", .str("")),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        return await Clerk(model: model).readDocument(reading, name: "notice.txt", binder: nil, locale: "en", now: now)
    }

    func input(_ text: String, id: String = "evt-review2") -> ClerkInput {
        ClerkInput(id: id, text: text, locale: "en", captureDay: today, estimated: false, isPrivate: false, sourceKind: nil, app: "test")
    }

    func matched(_ title: String, _ action: String, _ sentence: TextSpan, _ candidate: FilingBinder.Candidate, _ relation: String,
                 people: [String] = []) -> ClerkItem {
        var it = ClerkItem(title: title, action: action, sentence: sentence, people: people)
        it.binder = "estate-example"
        it.band = "high"
        it.match = ClerkItem.Match(candidate: candidate, relation: relation)
        return it
    }

    // MARK: - 1. The same action is no evidence of the same obligation

    @Test func twoPaymentsKeepTheirOwnDatesAndBothStay() async {
        let doc = await read("Pay the inspection fee. Pay the insurance premium by November 1.", items: [
            item("Pay the inspection fee", "Pay the inspection fee", "pay"),
            item("Pay the insurance premium", "Pay the insurance premium", "pay", when: "by November 1"),
        ])
        #expect(doc.items.map(\.title) == ["Pay the inspection fee", "Pay the insurance premium"])
        #expect(doc.items.map(\.whenResolved) == [nil, nov1])

        let unasked = await read("Pay the inspection fee. The insurance premium is due November 1.", items: [
            item("Pay the inspection fee", "Pay the inspection fee", "pay"),
            item("The insurance premium is due", "Pay the insurance premium", "pay", when: "November 1"),
        ])
        #expect(unasked.items.map(\.title) == ["Pay the inspection fee", "Pay the insurance premium"])
        #expect(unasked.items.first?.whenResolved == nil)
    }

    @Test func aSentenceThatOnlySaysWhenStillDatesThePayment() async {
        let doc = await read("Your share is $1,240. Please remit payment by November 1.", items: [
            item("Your share is $1,240", "Pay the special assessment", "pay", amount: "$1,240"),
        ])
        #expect(doc.items.count == 1)
        #expect(doc.items.first?.whenResolved == nov1)
        #expect(doc.items.first?.flags.contains("date taken from the next sentence") == true)
        #expect(doc.outcome == "complete")
        #expect(doc.notCovered.isEmpty)
    }

    // MARK: - 2. An update writes what the sentence changes

    @Test func aNewPartyKeepsTheWaitingItemsOwnReminder() {
        let text = "Now waiting on the Example Surveyor instead."
        let s = CaptureText.sentences(text)
        let waiting = FilingBinder.Candidate(id: .str("estate-example-2026-007"), title: "Wait for the plan", waitingOn: "Example Notary",
                                             words: [], status: "waiting")
        let change = matched("Wait for the plan", "wait", s[0], waiting, "update", people: ["Example Surveyor"])
        let interp = Interpretation(id: "interp-review2-1", event: "evt-review2", model: "scripted", items: [change])
        let built = Clerk.itemOps([change], event: input(text), today: today, actor: JSONObject(), interp: interp, now: now)
        #expect(built.ops.count == 1)
        #expect(built.ops.first?["op"] == .str("update_item"))
        #expect(built.ops.first?["args"]?["set"] == .obj([("waiting_on", .str("Example Surveyor"))]))

        // A wait that starts here still gets its default follow-up, marked derived.
        var open = waiting
        open.status = "open"
        let start = matched("Wait for the plan", "wait", s[0], open, "update", people: ["Example Surveyor"])
        let started = Clerk.itemOps([start], event: input(text), today: today, actor: JSONObject(), interp: interp, now: now)
        #expect(started.ops.first?["op"] == .str("set_status"))
        #expect(started.ops.first?["args"]?["follow_up_at"] == .str("2026-10-15"))
        #expect(started.ops.first?["args"]?["derived"] == .array([.str("follow_up_at")]))
    }

    // MARK: - 3. A recurring completion keeps its card

    @Test func aRecurringCompletionAloneStillGetsACard() {
        let text = "Paid building fees."
        let s = CaptureText.sentences(text)
        let fees = FilingBinder.Candidate(id: .str("estate-example-2026-004"), title: "Pay building fees", words: [], recurring: true)
        let done = matched("Pay building fees", "pay", s[0], fees, "done")
        let interp = Interpretation(id: "interp-review2-2", event: "evt-review2", model: "scripted", items: [done])
        let cards = Clerk.proposals(interp, event: input(text), today: today, client: "test", now: now)
        #expect(cards.count == 1)
        #expect(cards.first?.0 == "estate-example")
        #expect(cards.first?.1.ops.isEmpty == true)
        #expect(cards.first?.1.raw["provenance"]?["left_out"] == .array([.str("Pay building fees")]))
        #expect(cards.first?.1.raw["title"] == .str("To do by hand, from a note"))

        // An item already in the binder alone still makes no card: the caller notes it on the code-built one.
        let same = matched("Pay building fees", "pay", s[0], fees, "same")
        let already = Interpretation(id: "interp-review2-3", event: "evt-review2", model: "scripted", items: [same])
        #expect(Clerk.proposals(already, event: input(text), today: today, client: "test", now: now).isEmpty)
    }

    // MARK: - 4. One existing item, one change

    @Test func twoSentencesThatCompleteOneItemMakeOneCompletion() {
        let text = "Paid the permit fee. The permit fee is paid."
        let s = CaptureText.sentences(text)
        let fee = FilingBinder.Candidate(id: .str("estate-example-2026-009"), title: "Pay the permit fee", words: [])
        let items = [matched("Pay the permit fee", "pay", s[0], fee, "done"), matched("The permit fee is paid", "pay", s[1], fee, "done")]
        let interp = Interpretation(id: "interp-review2-4", event: "evt-review2", model: "scripted", items: items)
        let built = Clerk.itemOps(items, event: input(text), today: today, actor: JSONObject(), interp: interp, now: now)
        #expect(built.ops.count == 1)
        #expect(built.ops.first?["op"] == .str("complete"))
        #expect(built.ops.first?["spans"]?.arrayValue?.compactMap { $0["start"] } == [.int(s[0].start), .int(s[1].start)])
        #expect(built.ops.first?["card"]?["flags"]?.arrayValue?.contains(.str("another sentence speaks of the same item")) == true)

        // A completion after an update still follows it; an update after the completion joins it.
        var dated = matched("Pay the permit fee", "pay", s[0], fee, "update")
        dated.whenResolved = nov1
        dated.whenText = "November 1"
        let mixed = Clerk.itemOps([dated, items[1], dated], event: input(text), today: today, actor: JSONObject(), interp: interp, now: now)
        #expect(mixed.ops.compactMap { $0["op"]?.stringValue } == ["update_item", "complete"])
        #expect(mixed.ops.last?["spans"]?.arrayValue?.count == 2)
    }

    // MARK: - 5. An obligation no item covers makes the reading partial

    @Test func anUncoveredObligationIsKeptAndEscalated() async {
        let text = "Please pay the inspection fee by November 1."
        let doc = await read(text, items: [])
        #expect(doc.items.isEmpty)
        #expect(doc.outcome == "partial")
        #expect(doc.notCovered.map(\.start) == [0])
        #expect(doc.escalate.contains("parts of it ask for something the clerk did not list"))
        #expect(doc.json["not_covered"] == .array([.obj([("start", .int(0)), ("end", .int(CaptureText.sentences(text)[0].end))])]))

        let covered = await read(text, items: [item("Please pay the inspection fee", "Pay the inspection fee", "pay", when: "by November 1")])
        #expect(covered.outcome == "complete")
        #expect(covered.notCovered.isEmpty)
    }

    // MARK: - 6. A written currency code wins over the symbol

    @Test func usDollarsStayUSDollars() {
        #expect(Amounts.parse("USD $625") == Amounts.Parsed(value: 625, currency: "USD"))
        #expect(Amounts.parse("$625 USD") == Amounts.Parsed(value: 625, currency: "USD"))
        #expect(Amounts.parse("$625") == Amounts.Parsed(value: 625, currency: "CAD"))
        #expect(Amounts.scan("Pay USD $625 by Friday.") == Amounts.Parsed(value: 625, currency: "USD"))
        #expect(Amounts.scan("Pay $625 USD by Friday.") == Amounts.Parsed(value: 625, currency: "USD"))
        #expect(Amounts.scan("Pay 625 $ USD by Friday.") == Amounts.Parsed(value: 625, currency: "USD"))
        #expect(Amounts.scan("Invoice 2026 $625 is due.") == Amounts.Parsed(value: 625, currency: "CAD"))
    }
}

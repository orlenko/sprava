@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// Regressions from the third review of the clerk's layer (an amount taken as evidence of one obligation, a longer
/// title dropped as a repeat of a shorter one, a capped document reading that claimed to be complete, teen cents,
/// "ce soir"). Scripted models only; invented data only.
@Suite(.serialized) struct ClerkLayerReview3Tests {
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

    func read(_ text: String, answers: [[JSONValue]]) async -> DocumentReading {
        let model = ScriptedModel(extractions: answers.map { .obj([("items", .array($0))]) })
        model.document = .obj([("class", .str("action")), ("title", .str("Invented notice")), ("date_text", .str("")),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        return await Clerk(model: model).readDocument(reading, name: "notice.txt", binder: nil, locale: "en", now: now)
    }

    // MARK: - 1. An amount alone is no evidence of the same obligation

    @Test func aPaymentWithAnAmountKeepsTheNextSentencesOtherPayment() async {
        let doc = await read("Pay the inspection fee of $100. The insurance premium is due November 1.", answers: [[
            item("Pay the inspection fee of $100", "Pay the inspection fee", "pay", amount: "$100"),
            item("The insurance premium is due", "Pay the insurance premium", "pay", when: "November 1"),
        ]])
        #expect(doc.items.map(\.title) == ["Pay the inspection fee", "Pay the insurance premium"])
        #expect(doc.items.first?.whenResolved == nil)
        #expect(doc.items.last?.whenResolved == nov1)
    }

    @Test func aSharedDateAndActionNeverRemoveAnotherPayment() async {
        // The shared word "inspection" lends the date, but the premium is a payment of its own and stays.
        let doc = await read("Pay the inspection fee of $100. The inspection report and the insurance premium are due November 1.", answers: [[
            item("Pay the inspection fee of $100", "Pay the inspection fee", "pay", amount: "$100"),
            item("The inspection report and the insurance premium", "Pay the insurance premium", "pay", when: "November 1"),
        ]])
        #expect(doc.items.map(\.title) == ["Pay the inspection fee", "Pay the insurance premium"])
    }

    // MARK: - 2. A longer title is another task, not a repeat

    @Test func aTitleWithAnotherObjectIsKept() async {
        #expect(!Clerk.similar("Pay rent", "Pay rent deposit"))
        #expect(!Clerk.similar("Pay rent deposit", "Pay rent"))
        #expect(Clerk.similar("Call the notary", "Call the Notary"))
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("Pay rent and pay the rent deposit", "Pay rent", "pay"),
            item("Pay rent and pay the rent deposit", "Pay rent deposit", "pay"),
        ]))])])
        let input = ClerkInput(id: "evt-review3", text: "Pay rent and pay the rent deposit.", locale: "en", captureDay: today,
                               estimated: false, isPrivate: false, sourceKind: nil, app: "test")
        let interp = await Clerk(model: model).read(input, filing: [], hint: nil, now: now)
        #expect(interp.items.map(\.title) == ["Pay rent", "Pay rent deposit"])
    }

    // MARK: - 5. Items past the cap make the reading partial and are named

    @Test func itemsPastTheCapAreNotCoveredAndTheReadingIsPartial() async {
        let names = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf", "hotel", "india"]
        let sentences = names.enumerated().map { "Pay the \($1) permit fee by November \($0 + 1)." }
        let items = names.enumerated().map { item("Pay the \($1) permit fee", "Pay the \($1) permit fee", "pay", when: "by November \($0 + 1)") }
        // Five in the first reading (six would split the window), four more in the second.
        let doc = await read(sentences.joined(separator: " "), answers: [Array(items.prefix(5)), Array(items.dropFirst(5))])
        #expect(doc.items.count == Clerk.documentItems)
        #expect(doc.notCovered.map(\.text) == [sentences[8]])
        #expect(doc.outcome == "partial")
        #expect(doc.json["not_covered"] != nil)
        #expect(doc.escalate.contains("it asks for more than the clerk lists"))
    }

    // MARK: - 8. Two changes to one item both reach the card

    func change(_ title: String, _ action: String, _ sentence: TextSpan, _ candidate: FilingBinder.Candidate, people: [String] = [],
                due: CalendarDate? = nil) -> ClerkItem {
        var it = ClerkItem(title: title, action: action, sentence: sentence, people: people)
        it.binder = "estate-example"
        it.band = "high"
        it.match = ClerkItem.Match(candidate: candidate, relation: "update")
        if let due { it.whenResolved = due; it.whenText = "November 1"; it.whenRole = .due }
        return it
    }

    func ops(_ items: [ClerkItem], _ text: String) -> [JSONObject] {
        let input = ClerkInput(id: "evt-review3", text: text, locale: "en", captureDay: today, estimated: false, isPrivate: false,
                               sourceKind: nil, app: "test")
        let interp = Interpretation(id: "interp-review3", event: "evt-review3", model: "scripted", items: items)
        return Clerk.itemOps(items, event: input, today: today, actor: JSONObject(), interp: interp, now: now).ops
    }

    @Test func twoDifferentChangesToOneItemAreMerged() {
        let text = "The permit report is due November 1. Now wait for the permit report from Example Inspector."
        let s = CaptureText.sentences(text)
        let report = FilingBinder.Candidate(id: .str("estate-example-2026-011"), title: "Get the permit report", waitingOn: "Example Office",
                                            words: [], status: "waiting")
        let items = [change("Get the permit report", "other", s[0], report, due: nov1),
                     change("Wait for the permit report", "wait", s[1], report, people: ["Example Inspector"])]
        let built = ops(items, text)
        #expect(built.count == 1)
        #expect(built.first?["op"] == .str("update_item"))
        #expect(built.first?["args"]?["set"] == .obj([("due", .str("2026-11-01")), ("waiting_on", .str("Example Inspector"))]))
        #expect(built.first?["spans"]?.arrayValue?.count == 2)

        // A wait that starts on an open item after a date change follows it as its own op.
        var open = report
        open.status = "open"
        open.waitingOn = nil
        let started = ops([change("Get the permit report", "other", s[0], open, due: nov1),
                           change("Wait for the permit report", "wait", s[1], open, people: ["Example Inspector"])], text)
        #expect(started.compactMap { $0["op"]?.stringValue } == ["update_item", "set_status"])
        #expect(started.last?["args"]?["waiting_on"] == .str("Example Inspector"))

        // The same change twice is still one change.
        let twice = ops([change("Get the permit report", "other", s[0], report, due: nov1),
                         change("Get the permit report", "other", s[0], report, due: nov1)], text)
        #expect(twice.count == 1)
    }

    @Test func twoConflictingChangesToOneItemAreBothShown() {
        let text = "Now wait for Example Inspector. Now wait for Example Surveyor."
        let s = CaptureText.sentences(text)
        let report = FilingBinder.Candidate(id: .str("estate-example-2026-012"), title: "Get the permit report", waitingOn: "Example Office",
                                            words: [], status: "waiting")
        let built = ops([change("Wait for the report", "wait", s[0], report, people: ["Example Inspector"]),
                         change("Wait for the report", "wait", s[1], report, people: ["Example Surveyor"])], text)
        #expect(built.compactMap { $0["args"]?["set"]?["waiting_on"]?.stringValue } == ["Example Inspector", "Example Surveyor"])
        for o in built {
            #expect(o["card"]?["flags"]?.arrayValue?.contains(.str("another sentence changes the same item differently")) == true)
        }
    }

    // MARK: - 6 and 7. Teen cents; "ce soir"

    @Test func teenCentsAreCents() {
        for (word, n) in [("eleven", 11), ("twelve", 12), ("thirteen", 13), ("fourteen", 14), ("fifteen", 15), ("sixteen", 16),
                          ("seventeen", 17), ("eighteen", 18), ("nineteen", 19)] {
            #expect(Amounts.parse("\(word) cents")?.value == Double(n) / 100)
        }
        #expect(Amounts.parse("deux cents dollars")?.value == 200)
    }

    @Test func ceSoirIsToday() {
        #expect(DateGrammar.resolve("ce soir", anchor: today, locale: "fr")?.date == today)
        #expect(DateGrammar.scan("Payer la facture ce soir.", anchor: today, locale: "fr")?.date == today)
        #expect(DateGrammar.resolve("soir", anchor: today, locale: "fr") == nil)
    }
}

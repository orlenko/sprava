@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// Regressions from the review of the clerk's layer (dates moved between independent tasks, repeated quotes,
/// day-first document dates, completions of recurring items, invoice numbers read as money). Scripted models only;
/// invented data only.
@Suite(.serialized) struct ClerkLayerReviewTests {
    let today = CalendarDate(year: 2026, month: 10, day: 8)!
    /// Noon UTC on 2026-10-08: the same calendar day in every time zone the tests run in.
    let now = Date(timeIntervalSince1970: 1_791_460_800)

    func item(_ quote: String, _ title: String, _ action: String, when: String? = nil, amount: String? = nil) -> JSONValue {
        var fields: [(String, JSONValue)] = [("quote", .string(quote)), ("title", .string(title)), ("action", .string(action))]
        if let when { fields.append(("when_text", .string(when))) }
        if let amount { fields.append(("amount_text", .string(amount))) }
        return .obj(fields)
    }

    func read(_ text: String, items: [JSONValue], date: String = "", locale: String = "en") async -> DocumentReading {
        let model = ScriptedModel(extractions: [.obj([("items", .array(items))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Invented notice")), ("date_text", .string(date)),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        return await Clerk(model: model).readDocument(reading, name: "notice.txt", binder: nil, locale: locale, now: now)
    }

    @Test func theFixedNoonIsTheEighth() {
        #expect(CalendarDate.today(now: now) == today)
    }

    // MARK: - 1. A date in the next sentence belongs to that sentence's own task

    @Test func aNextSentenceWithItsOwnTaskKeepsItsDateAndItsItem() async {
        let doc = await read("Pay the inspection fee. Submit the permit application by November 1.", items: [
            item("Pay the inspection fee", "Pay the inspection fee", "pay"),
            item("Submit the permit application", "Submit the permit application", "file", when: "by November 1"),
        ])
        #expect(doc.items.map(\.title) == ["Pay the inspection fee", "Submit the permit application"])
        #expect(doc.items.first?.whenResolved == nil)
        #expect(doc.items.last?.whenResolved == CalendarDate(year: 2026, month: 11, day: 1))
    }

    @Test func aNextSentenceThatOnlyDatesThePaymentIsStillOneTask() async {
        let doc = await read("Your share is $1,240. The levy is due November 1.", items: [
            item("Your share is $1,240", "Pay the special assessment", "pay", amount: "$1,240"),
            item("The levy is due", "Pay the levy", "pay", when: "November 1"),
        ])
        #expect(doc.items.count == 1)
        #expect(doc.items.first?.title == "Pay the special assessment")
        #expect(doc.items.first?.whenResolved == CalendarDate(year: 2026, month: 11, day: 1))
        #expect(doc.items.first?.flags.contains("date taken from the next sentence") == true)
    }

    // MARK: - 2. A quote that opens several sentences

    @Test func anchorsAreFoundInTheirScopeOnly() {
        let text = "Renew the invented plan now. Renew the invented plan later."
        let s = CaptureText.sentences(text)
        #expect(CaptureText.anchors("renew the invented plan", in: text, sentences: s) == s)
        #expect(CaptureText.anchors("renew the invented plan", in: text, sentences: s, scope: [s[1]]) == [s[1]])
        #expect(CaptureText.anchor("renew the invented plan", in: text, sentences: s) == s[0])
    }

    @Test func eachWindowAnchorsInItsOwnParagraph() async {
        let opening = "The renewal notice for the invented home plan from Example Mutual says"
        let text = "\(opening) to choose the basic plan by October 20.\n\n\(opening) to choose the premium plan by November 15."
        let model = ScriptedModel(extractions: [
            .obj([("items", .array([item(opening, "Choose the basic plan", "decide", when: "by October 20")]))]),
            // No time words copied: only the window tells which paragraph the quote opens.
            .obj([("items", .array([item(opening, "Choose the premium plan", "decide")]))]),
        ])
        var clerk = Clerk(model: model)
        clerk.windowWords = 20   // one window per paragraph
        #expect(CaptureText.windows(text, words: 20).count == 2)
        let input = ClerkInput(id: "evt-review-1", text: text, locale: "en", captureDay: today, estimated: false, isPrivate: false,
                               sourceKind: nil, app: "test")
        let interp = await clerk.read(input, filing: [], hint: nil, now: now)
        let sentences = CaptureText.sentences(text)
        #expect(interp.items.map(\.sentence) == sentences)
        #expect(interp.items.map(\.whenResolved) == [CalendarDate(year: 2026, month: 10, day: 20), CalendarDate(year: 2026, month: 11, day: 15)])
        #expect(interp.items.map(\.flags) == [[], ["date taken from the sentence"]])
    }

    @Test func aRepeatedQuoteInOneWindowIsPlacedByItsWordsThenOnAFreeSentence() async {
        let opening = "Renew the invented parking permit for the lot"
        let text = "\(opening) on the north side by October 20. \(opening) on the south side by November 15."
        let byDate = await read(text, items: [
            item(opening, "Renew the south lot permit", "file", when: "by November 15"),
            item(opening, "Renew the north lot permit", "file", when: "by October 20"),
        ])
        let placed = byDate.items.sorted { $0.sentence.start < $1.sentence.start }
        #expect(placed.map(\.title) == ["Renew the north lot permit", "Renew the south lot permit"])
        #expect(placed.map(\.whenResolved) == [CalendarDate(year: 2026, month: 10, day: 20), CalendarDate(year: 2026, month: 11, day: 15)])

        // The same title twice, with nothing else to tell them apart: one item per sentence, never one dropped as a duplicate.
        let same = await read("Pay the invented parking fee for the north lot. Pay the invented parking fee for the south lot.", items: [
            item("Pay the invented parking fee", "Pay the parking fee", "pay"),
            item("Pay the invented parking fee", "Pay the parking fee", "pay"),
        ])
        #expect(same.items.count == 2)
        #expect(Set(same.items.map(\.sentence.start)).count == 2)
    }

    // MARK: - 3. A day-first date dates the document in fr-FR

    @Test func fullDatesAreReadAsResolveReadsThem() {
        #expect(DateGrammar.isFullDate("01/10/2026", locale: "fr-FR"))
        #expect(!DateGrammar.isFullDate("01/10/2026", locale: "fr-CA"))
        #expect(!DateGrammar.isFullDate("01/10/2026"))
        #expect(DateGrammar.isFullDate("le 01/10/2026", locale: "fr-FR"))
        #expect(DateGrammar.isFullDate("by 2026-10-15"))
        #expect(DateGrammar.isFullDate("le 1 octobre 2026"))
        #expect(DateGrammar.isFullDate("October 15, 2026"))
        #expect(!DateGrammar.isFullDate("Friday"))
        #expect(!DateGrammar.isFullDate("the 15th"))
    }

    @Test func aDayFirstPrintedDateAnchorsRelativeDeadlines() async {
        let doc = await read("Paris, le 01/10/2026\n\nVeuillez payer la cotisation dans deux semaines.", items: [
            item("Veuillez payer la cotisation", "Payer la cotisation", "pay", when: "dans deux semaines"),
        ], date: "01/10/2026", locale: "fr-FR")
        #expect(doc.date == CalendarDate(year: 2026, month: 10, day: 1))
        #expect(doc.items.first?.whenResolved == CalendarDate(year: 2026, month: 10, day: 15))
    }

    // MARK: - 4. A completion of a recurring item is left to the person

    @Test func aRecurringItemIsNeverCompletedByTheClerk() {
        let catalog = JSONValue.obj([("open_items", .array([
            .obj([("id", .str("estate-example-2026-004")), ("title", .str("Pay building fees")), ("due", .str("2026-11-01")),
                  ("recurrence", .obj([("freq", .str("monthly")), ("day", .int(1))]))]),
            .obj([("id", .str("estate-example-2026-005")), ("title", .str("Pay the invented locksmith")), ("due", .str("2026-11-01"))]),
        ]))]).objectValue
        let candidates = FilingBinder.candidates(catalog: catalog)
        #expect(candidates.map(\.recurring) == [true, false])

        let text = "Paid building fees. Paid the invented locksmith."
        let s = CaptureText.sentences(text)
        var fees = ClerkItem(title: "Pay building fees", action: "pay", sentence: s[0], people: [])
        fees.match = ClerkItem.Match(candidate: candidates[0], relation: "done")
        var locksmith = ClerkItem(title: "Pay the invented locksmith", action: "pay", sentence: s[1], people: [])
        locksmith.match = ClerkItem.Match(candidate: candidates[1], relation: "done")
        let input = ClerkInput(id: "evt-review-2", text: text, locale: "en", captureDay: today, estimated: false, isPrivate: false,
                               sourceKind: nil, app: "test")
        let interp = Interpretation(id: "interp-review-2", event: input.id, model: "scripted", items: [fees, locksmith])
        let built = Clerk.itemOps([fees, locksmith], event: input, today: today, actor: JSONObject(), interp: interp, now: now)
        #expect(built.ops.count == 1)
        #expect(built.ops.first?["op"] == .str("complete"))
        #expect(built.ops.first?["args"]?["id"] == .str("estate-example-2026-005"))
        #expect(built.rejected == ["Pay building fees"])
    }

    // MARK: - 5. Only digits by their currency are money

    @Test func invoiceNumbersAndDatesAreNoAmount() {
        #expect(Amounts.scan("Invoice 2026-014 totals $625.") == Amounts.Parsed(value: 625, currency: "CAD"))
        #expect(Amounts.scan("Invoice 2026 $625 is due.")?.value == 625)
        #expect(Amounts.scan("Facture 2026-014 : 4 200,75 € avant le 15 octobre 2026.") == Amounts.Parsed(value: 4200.75, currency: "EUR"))
        #expect(Amounts.scan("Pay twelve hundred dollars for invoice 2026-014.")?.value == 1200)
        #expect(Amounts.scan("Invoice 2026-014 is in dollars.") == nil)
        #expect(Amounts.scan("Pay the plumber 625 dollars by the 15th.")?.value == 625)
        #expect(Amounts.scan("The grant is $1.5 million.")?.value == 1_500_000)

        let text = "Invoice 2026-014 totals $625."
        let facts = IntakeFacts.of(IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other"), anchor: today)
        #expect(facts.amounts == ["CAD 625"])
        let checked = Clerk(model: ScriptedModel(extractions: [])).check(item("Invoice 2026-014 totals", "Pay invoice 2026-014", "pay", amount: "$625"),
                                                                       text: text, sentences: CaptureText.sentences(text), today: today, locale: "en")
        #expect(checked?.amount?.value == 625)
        #expect(checked?.flags.contains("amount in the note not found in the item") == false)
    }
}

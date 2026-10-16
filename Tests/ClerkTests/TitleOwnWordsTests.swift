@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// An item's title is the person's own words, never a model's paraphrase (capture-event-v0 §6.4 check 1): a
/// title with a word the source does not hold is replaced by one code builds from the sentence. Scripted models
/// only; invented data only.
@Suite struct TitleOwnWordsTests {
    let today = CalendarDate(year: 2026, month: 10, day: 8)!
    /// Noon UTC on 2026-10-08: the same calendar day in every time zone the tests run in.
    let now = Date(timeIntervalSince1970: 1_791_460_800)

    func item(_ quote: String, _ title: String, _ action: String, when: String = "", amount: String = "") -> JSONValue {
        .obj([("quote", .string(quote)), ("title", .string(title)), ("action", .string(action)), ("when_text", .string(when)),
              ("people", .array([])), ("amount_text", .string(amount))])
    }

    func read(_ text: String, _ items: [JSONValue], locale: String = "en") async -> (Interpretation, ClerkInput) {
        let model = ScriptedModel(extractions: [.obj([("items", .array(items))])])
        let input = ClerkInput(id: "evt-title", text: text, locale: locale, captureDay: today, estimated: false, isPrivate: false,
                               sourceKind: nil, app: "test")
        return (await Clerk(model: model).read(input, filing: [], hint: nil, now: now), input)
    }

    @Test func aModelVerbNeverReachesTheTitle() async {
        for when in ["today", ""] {
            let (interp, input) = await read("Bill Acme today", [item("Bill Acme today", "Call Bill Acme", "call", when: when)])
            #expect(interp.items.map(\.title) == ["Bill Acme"], "when_text \(when)")
            #expect(interp.items.first?.whenResolved == today)
            #expect(interp.items.first?.whenRole == .due)
            let card = Clerk.proposals(interp, event: input, today: today, client: "test", now: now).first?.1
            #expect(card?.title == "Add \u{201C}Bill Acme\u{201D}")
            #expect(card?.ops.first?["args"]?["item"]?["title"]?.stringValue == "Bill Acme")
        }
    }

    @Test func aDeadlineLeavesRepeatedWordsInTheTaskName() async {
        for (source, proposed, expected) in [
            ("Review Friday Lanterns on Friday", "Review Friday Lanterns on Friday", "Review Friday Lanterns"),
            ("Review Friday Lanterns on Friday", "Review Friday Lanterns", "Review Friday Lanterns"),
            ("On Friday review Friday Lanterns", "On Friday review Friday Lanterns", "Review Friday Lanterns"),
            ("Review Friday Lanterns by Friday", "Summarize Friday Lanterns", "Review Friday Lanterns"),
            // Without one identifiable date context, keep the words instead of guessing which one to remove.
            ("Review Friday Lanterns Friday", "Review Friday Lanterns Friday", "Review Friday Lanterns Friday"),
            ("Review On Friday on Friday", "Review On Friday on Friday", "Review On Friday on Friday"),
        ] {
            let (interp, input) = await read(source, [item(source, proposed, "review", when: "Friday")])
            #expect(interp.items.map(\.title) == [expected], "source: \(source), proposed: \(proposed)")
            #expect(interp.items.first?.whenResolved == today.adding(days: 1))
            let card = Clerk.proposals(interp, event: input, today: today, client: "test", now: now).first?.1
            #expect(card?.ops.first?["args"]?["item"]?["title"]?.stringValue == expected)
        }
    }

    @Test func aTitleOfTheNotesOwnWordsIsKept() async {
        let (interp, _) = await read("Pay rent and send the lease to the landlord by Friday.", [
            item("Pay rent and send the lease", "Pay rent", "pay"),
            item("Pay rent and send the lease", "send the lease to the landlord by Friday", "send", when: "by Friday"),
        ])
        // Kept, with the time words taken out and the first letter capitalized.
        #expect(interp.items.map(\.title) == ["Pay rent", "Send the lease to the landlord"])
    }

    @Test func twoTasksThatDifferOnlyInTheirTimeBothStay() async {
        let (interp, _) = await read("Call the plumber on Monday and call the plumber on Friday.", [
            item("Call the plumber on Monday", "Call the plumber on Monday", "call", when: "on Monday"),
            item("Call the plumber on Monday", "Call the plumber on Friday", "call", when: "on Friday"),
        ])
        #expect(interp.items.map(\.title) == ["Call the plumber", "Call the plumber"])
        #expect(interp.items.compactMap { $0.whenResolved?.description }.sorted() == ["2026-10-09", "2026-10-12"])
        // The same task listed twice is still one.
        let (once, _) = await read("Call the plumber by Friday.", [
            item("Call the plumber by Friday", "Call the plumber", "call", when: "by Friday"),
            item("Call the plumber by Friday", "Call the Plumber", "call", when: "Friday"),
        ])
        #expect(once.items.count == 1)
        // The same day in other words.
        let (sameDay, _) = await read("Call the plumber today and call the plumber tonight.", [
            item("Call the plumber today", "Call the plumber today", "call", when: "today"),
            item("Call the plumber today", "Call the plumber tonight", "call", when: "tonight"),
        ])
        #expect(sameDay.items.count == 2)
    }

    /// The duplicate check tells two tasks with one shown title apart: by what the model called each, and its date.
    @Test func theDuplicateCheckTellsTasksWithOneTitleApart() async {
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("Call the plumber on Monday", "Call the plumber on Monday", "call", when: "on Monday"),
            item("Call the plumber on Monday", "Call the plumber on Friday", "call", when: "on Friday"),
        ]))])])
        let open = FilingBinder.Candidate(id: .str("home-example-2026-001"), title: "Call the plumber", due: "2026-10-12",
                                          words: FilingBinder.significantWords("Call the plumber"))
        let folder = URL(fileURLWithPath: "/tmp/sprava-invented/home-example", isDirectory: true)
        let binder = FilingBinder(name: "home-example", description: "An invented home", folder: folder, openItems: [open])
        model.duplicates = ["new item: call the plumber on monday, due 2026-10-12": ("home-example-2026-001", "same")]
        let input = ClerkInput(id: "evt-title", text: "Call the plumber on Monday and call the plumber on Friday.", locale: "en",
                               captureDay: today, estimated: false, isPrivate: false, sourceKind: nil, app: "test")
        let interp = await Clerk(model: model).read(input, filing: [binder], hint: "home-example", now: now)
        #expect(interp.items.map(\.title) == ["Call the plumber", "Call the plumber"])
        #expect(interp.items.filter { $0.match?.relation == "same" }.map { $0.whenResolved?.description } == ["2026-10-12"])
        #expect(interp.items.filter { $0.match == nil }.map { $0.whenResolved?.description } == ["2026-10-09"])
    }

    /// Two tasks of one sentence can share the title code builds from it; they stay two, each with its amount.
    @Test func tasksThatShareABuiltTitleBothStay() async {
        let (interp, _) = await read("The rent is $800 and the deposit is $200, both due Friday.", [
            item("The rent is $800 and the deposit is $200", "Pay rent", "pay", when: "Friday", amount: "$800"),
            item("The rent is $800 and the deposit is $200", "Pay deposit", "pay", when: "Friday", amount: "$200"),
        ])
        #expect(interp.items.count == 2)
        #expect(interp.items.compactMap { $0.amount?.value }.sorted() == [200, 800])
        #expect(interp.items.allSatisfy { Clerk.hasOnlyWords(of: $0.sentence.text, $0.title) })
    }

    @Test func eachLineOfAListKeepsItsWords() async {
        let text = "To do:\n- Bill Acme today\n- order toner by Friday\n- Dentist on Monday"
        let (interp, _) = await read(text, [
            item("Bill Acme today", "Call Bill Acme", "call", when: "today"),
            item("order toner by Friday", "Buy printer toner", "pay", when: "Friday"),
            item("Dentist on Monday", "Visit the dentist", "meet", when: "on Monday"),
        ])
        #expect(interp.items.map(\.title) == ["Bill Acme", "Order toner", "Dentist"])
    }

    @Test func aFrenchNoteKeepsItsFrenchWords() async {
        let (interp, _) = await read("Facturer Acme demain.", [item("Facturer Acme demain", "Bill Acme tomorrow", "send", when: "demain")],
                                     locale: "fr-CA")
        #expect(interp.items.map(\.title) == ["Facturer Acme"])
        #expect(interp.items.first?.whenResolved == today.adding(days: 1))
        let (kept, _) = await read("Payer le loyer et appeler le notaire avant vendredi.", [
            item("Payer le loyer et appeler le notaire", "Appeler le notaire", "call", when: "avant vendredi"),
        ], locale: "fr-CA")
        #expect(kept.items.map(\.title) == ["Appeler le notaire"])
    }

    @Test func aTitleIsNeverAcceptedWithWordsAbsentFromTheSource() {
        let sentences = ["Bill Acme today", "order toner by Friday", "Rappeler la banque d'ici lundi", "Renew the permit, $40, by the 15th."]
        let proposed = ["Call Bill Acme", "Buy toner", "Call the bank", "Renew the parking permit", "", "  ", "—", "Toner order Friday ok"]
        for sentence in sentences {
            let when = DateGrammar.scan(sentence, anchor: today, locale: "en")?.text
            for title in proposed + [sentence] {
                let kept = Clerk.ownTitle(title, quote: sentence, sentence: sentence, whenText: when)
                #expect(Clerk.hasOnlyWords(of: sentence, kept), "\(title) -> \(kept)")
            }
        }
        #expect(Clerk.ownTitle("Call Bill Acme", quote: "Bill", sentence: "Bill Acme today", whenText: "today") == "Bill Acme")
        #expect(Clerk.ownTitle("Pay", quote: "Renew", sentence: "Renew the permit, $40, by the 15th.", whenText: "by the 15th")
            == "Renew the permit, $40")
        // A sentence that is only its time words keeps them, rather than an empty title.
        #expect(Clerk.ownTitle("Do it", quote: "Tomorrow", sentence: "Tomorrow!", whenText: "Tomorrow") == "Tomorrow")
    }

    @Test func aDocumentKeepsItsOwnWordsForItemsAndItsTitle() async {
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("The special levy of $1,240 is payable", "Pay the special assessment", "pay", when: "by November 1"),
        ]))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Notice of special assessment")), ("date_text", .str("")),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let text = "Notice of special levy. The special levy of $1,240 is payable by November 1."
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        let doc = await Clerk(model: model).readDocument(reading, name: "notice.txt", binder: nil, locale: "en", now: now)
        #expect(doc.title == nil)
        #expect(doc.items.map(\.title) == ["The special levy of $1,240 is payable"])
        #expect(doc.items.first?.whenResolved == CalendarDate(year: 2026, month: 11, day: 1))
    }
}

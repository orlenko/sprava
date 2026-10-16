@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// Item titles preserve the whole source sentence; document headings copy a complete source sentence or line
/// (capture-event-v0 §6.4 check 1). Scripted models and invented data only.
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
            #expect(interp.items.map(\.title) == ["Bill Acme today"], "when_text \(when)")
            #expect(interp.items.first?.whenResolved == today)
            #expect(interp.items.first?.whenRole == .due)
            let card = Clerk.proposals(interp, event: input, today: today, client: "test", now: now).first?.1
            #expect(card?.title == "Add \u{201C}Bill Acme today\u{201D}")
            #expect(card?.ops.first?["args"]?["item"]?["title"]?.stringValue == "Bill Acme today")
        }
    }

    @Test func modelTitlesCannotOmitOrReorderSourceContext() async {
        for (source, proposed) in [
            ("Do not call Acme.", "Call Acme"),
            ("If the estimate is approved, call Acme.", "Call Acme"),
            ("Call Acme only after the estimate is approved.", "Call Acme"),
            ("Send Acme the revised estimate, not the draft.", "Send Acme the draft"),
            ("Pay the rent, not the deposit.", "Pay the deposit"),
            ("Acme should call Beta.", "Beta should call Acme"),
        ] {
            let expected = String(source.dropLast())
            let (interp, input) = await read(source, [item(source, proposed, "call")])
            #expect(interp.items.map(\.title) == [expected])
            let card = Clerk.proposals(interp, event: input, today: today, client: "test", now: now).first?.1
            #expect(card?.ops.first?["args"]?["item"]?["title"]?.stringValue == expected)
        }
    }

    @Test func aDocumentHeadingCannotBeRecomposedFromSourceWords() async {
        for (source, proposed) in [
            ("Do not approve the estimate.", "Approve the estimate"),
            ("Acme should call Beta.", "Beta should call Acme"),
        ] {
            let model = ScriptedModel(extractions: [])
            model.document = .obj([("class", .str("information")), ("title", .str(proposed)),
                                   ("date_text", .str("")), ("summary", .str("An invented notice.")),
                                   ("reply_needed", .bool(false))])
            let reading = IntakeReading(kind: "text", textFrom: "parsed", text: source, channel: "other")
            let doc = await Clerk(model: model).readDocument(reading, name: "notice.txt", binder: nil, now: now)
            #expect(doc.title == nil)
        }
    }

    @Test func aFallbackTitleKeepsTheSentenceBeforeAnInteriorQuote() async {
        for (source, quote) in [
            ("If the estimate is approved, call Acme.", "call Acme"),
            ("Only after the deposit arrives, call Acme.", "call Acme"),
            ("Do not call Acme until the estimate is approved.", "call Acme"),
            ("If Acme agrees, call Acme; otherwise wait.", "call Acme"),
        ] {
            let expected = String(source.dropLast())
            let (interp, input) = await read(source, [item(quote, "Contact Acme", "call")])
            #expect(interp.items.map(\.title) == [expected])
            let card = Clerk.proposals(interp, event: input, today: today, client: "test", now: now).first?.1
            #expect(card?.ops.first?["args"]?["item"]?["title"]?.stringValue == expected)
        }
    }

    @Test func dateShapedNamesKeepTheirWholeWords() async {
        for name in ["Friday’s", "Friday's", "Friday-night", "Friday.txt", "Friday_report", "Friday/notes", "Friday\u{301}s"] {
            let source = "Meet at \(name)"
            let (interp, input) = await read(source, [item(source, source, "meet", when: "Friday")])
            #expect(interp.items.map(\.title) == [source])
            let card = Clerk.proposals(interp, event: input, today: today, client: "test", now: now).first?.1
            #expect(card?.ops.first?["args"]?["item"]?["title"]?.stringValue == source)
        }
    }

    @Test func aBareDateWordIsPreservedInTheTitle() async {
        for (source, proposed, when) in [
            ("Review Friday Lanterns", "Review Friday Lanterns", ""),
            ("Review Friday", "Review Friday", "Friday"),
            ("Read Tomorrow", "Read Tomorrow", "Tomorrow"),
            ("Bill Acme today", "Call Bill Acme", "today"),
        ] {
            let (interp, input) = await read(source, [item(source, proposed, "review", when: when)])
            #expect(interp.items.map(\.title) == [source])
            let card = Clerk.proposals(interp, event: input, today: today, client: "test", now: now).first?.1
            #expect(card?.ops.first?["args"]?["item"]?["title"]?.stringValue == source)
        }
    }

    @Test func aDeadlineLeavesRepeatedWordsInTheTaskName() async {
        for (source, proposed, expected) in [
            ("Review Friday Lanterns on Friday", "Review Friday Lanterns on Friday", "Review Friday Lanterns on Friday"),
            ("Review Friday Lanterns on Friday", "Review Friday Lanterns", "Review Friday Lanterns on Friday"),
            ("On Friday review Friday Lanterns", "On Friday review Friday Lanterns", "On Friday review Friday Lanterns"),
            ("Review Friday Lanterns by Friday", "Summarize Friday Lanterns", "Review Friday Lanterns by Friday"),
            // Repeated or date-shaped source words remain intact in the displayed title.
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

    @Test func evenCopiedModelFragmentsKeepTheWholeSentence() async {
        let (interp, _) = await read("Pay rent and send the lease to the landlord by Friday.", [
            item("Pay rent and send the lease", "Pay rent", "pay"),
            item("Pay rent and send the lease", "send the lease to the landlord by Friday", "send", when: "by Friday"),
        ])
        // Distinct tasks retain their source context, even when model fragments contain only source words.
        #expect(interp.items.map(\.title) == Array(repeating: "Pay rent and send the lease to the landlord by Friday", count: 2))
    }

    @Test func twoTasksThatDifferOnlyInTheirTimeBothStay() async {
        let (interp, _) = await read("Call the plumber on Monday and call the plumber on Friday.", [
            item("Call the plumber on Monday", "Call the plumber on Monday", "call", when: "on Monday"),
            item("Call the plumber on Monday", "Call the plumber on Friday", "call", when: "on Friday"),
        ])
        #expect(interp.items.map(\.title) == Array(repeating: "Call the plumber on Monday and call the plumber on Friday", count: 2))
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
            item("Call the plumber on Monday", "Book the plumber on Monday", "call", when: "on Monday"),
            item("Call the plumber on Monday", "Schedule the plumber on Friday", "call", when: "on Friday"),
        ]))])])
        let open = FilingBinder.Candidate(id: .str("home-example-2026-001"), title: "Call the plumber", due: "2026-10-12",
                                          words: FilingBinder.significantWords("Call the plumber"))
        let folder = URL(fileURLWithPath: "/tmp/sprava-invented/home-example", isDirectory: true)
        let binder = FilingBinder(name: "home-example", description: "An invented home", folder: folder, openItems: [open])
        model.duplicates = ["new item: book the plumber on monday, due 2026-10-12": ("home-example-2026-001", "same")]
        let input = ClerkInput(id: "evt-title", text: "Call the plumber on Monday and call the plumber on Friday.", locale: "en",
                               captureDay: today, estimated: false, isPrivate: false, sourceKind: nil, app: "test")
        let interp = await Clerk(model: model).read(input, filing: [binder], hint: "home-example", now: now)
        #expect(interp.items.map(\.title) == Array(repeating: "Call the plumber on Monday and call the plumber on Friday", count: 2))
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
        #expect(interp.items.map(\.title) == Array(repeating: "The rent is $800 and the deposit is $200, both due Friday", count: 2))
    }

    @Test func eachLineOfAListKeepsItsWords() async {
        let text = "To do:\n- Bill Acme today\n- order toner by Friday\n- Dentist on Monday"
        let (interp, _) = await read(text, [
            item("Bill Acme today", "Call Bill Acme", "call", when: "today"),
            item("order toner by Friday", "Buy printer toner", "pay", when: "Friday"),
            item("Dentist on Monday", "Visit the dentist", "meet", when: "on Monday"),
        ])
        #expect(interp.items.map(\.title) == ["Bill Acme today", "Order toner by Friday", "Dentist on Monday"])
    }

    @Test func aFrenchNoteKeepsItsFrenchWords() async {
        let (interp, _) = await read("Facturer Acme demain.", [item("Facturer Acme demain", "Bill Acme tomorrow", "send", when: "demain")],
                                     locale: "fr-CA")
        #expect(interp.items.map(\.title) == ["Facturer Acme demain"])
        #expect(interp.items.first?.whenResolved == today.adding(days: 1))
        let (kept, _) = await read("Payer le loyer et appeler le notaire avant vendredi.", [
            item("Payer le loyer et appeler le notaire", "Appeler le notaire", "call", when: "avant vendredi"),
        ], locale: "fr-CA")
        #expect(kept.items.map(\.title) == ["Payer le loyer et appeler le notaire avant vendredi"])
    }

    @Test func aDocumentHeadingCopiesACompleteSourceLine() {
        #expect(Clerk.copiedHeading("Notice of special levy", in: "Notice of special levy.\nPlease keep this notice.") == "Notice of special levy")
        #expect(Clerk.copiedHeading("notice   of special levy", in: "Notice of special levy\nPlease keep this notice.") == "Notice of special levy")
        #expect(Clerk.copiedHeading("", in: "Notice of special levy") == nil)
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
        #expect(doc.items.map(\.title) == ["The special levy of $1,240 is payable by November 1"])
        #expect(doc.items.first?.whenResolved == CalendarDate(year: 2026, month: 11, day: 1))
    }
}

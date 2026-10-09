import BinderStore
@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import Testing

/// Regressions from Bugbot's review of the clerk's layer (a window too long to read, items code dropped from a
/// document, a binder hint outside the filing list, a reply missed by coverage, ids that differ only by type, and a
/// few small extraction fixes). Scripted models only; invented data only.
@Suite(.serialized) struct ClerkBugbotTests {
    let today = CalendarDate(year: 2026, month: 10, day: 8)!
    /// Noon UTC on 2026-10-08: the same calendar day in every time zone the tests run in.
    let now = Date(timeIntervalSince1970: 1_791_460_800)
    let folder = URL(fileURLWithPath: "/tmp/sprava-invented/home-example", isDirectory: true)

    func item(_ quote: String, _ title: String, _ action: String, when: String? = nil) -> JSONValue {
        var fields: [(String, JSONValue)] = [("quote", .string(quote)), ("title", .string(title)), ("action", .string(action))]
        if let when { fields.append(("when_text", .string(when))) }
        return .obj(fields)
    }

    func input(_ text: String, isPrivate: Bool = false) -> ClerkInput {
        ClerkInput(id: "evt-bugbot", text: text, locale: "en", captureDay: today, estimated: false, isPrivate: isPrivate,
                   sourceKind: nil, app: "test")
    }

    // MARK: - A window too long to read makes the reading partial

    @Test func aWindowTooLongToReadIsPartial() async {
        // A context smaller than the answer's reserve: the one-sentence window cannot be split, so it is not read.
        let model = ScriptedModel(extractions: [], contextSize: 100)
        let interp = await Clerk(model: model).read(input("It was a quiet invented morning."), filing: [], hint: nil, now: now)
        #expect(interp.unfiled.map(\.reason) == ["too_long"])
        #expect(interp.outcome == "partial")
    }

    // MARK: - A document with items code dropped is partial and escalated

    @Test func aDocumentWithDroppedItemsIsPartial() async {
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("Words that are not in the notice", "Pay the invented fee", "pay"),
        ]))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Invented notice")), ("date_text", .str("")),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: "Pay the invented fee.", channel: "other")
        let doc = await Clerk(model: model).readDocument(reading, name: "notice.txt", binder: nil, locale: "en", now: now)
        #expect(doc.dropped == 1)
        #expect(doc.outcome == "partial")
        #expect(doc.escalate.contains("the clerk listed things code could not find in it"))
    }

    // MARK: - A binder hint files only into a binder on the filing list

    @Test func aHintOutsideTheFilingListIsOnlyAGuess() async {
        let text = "Call the invented plumber."
        let filing = [FilingBinder(name: "home-example", description: "An invented home", folder: folder)]
        func read(hint: String) async -> Interpretation {
            let model = ScriptedModel(extractions: [.obj([("items", .array([item("Call the invented plumber", "Call the plumber", "call")]))])])
            return await Clerk(model: model).read(input(text), filing: filing, hint: hint, now: now)
        }
        let outside = await read(hint: "somewhere-else")
        #expect(outside.items.count == 1)
        #expect(outside.items.first?.binder == nil)
        #expect(outside.items.first?.guess == "somewhere-else")
        #expect(outside.items.first?.band == "low")
        let cards = Clerk.proposals(outside, event: input(text), today: today, client: "test", now: now)
        #expect(cards.map(\.0) == [nil])

        let listed = await read(hint: "home-example")
        #expect(listed.items.first?.binder == "home-example")
        #expect(listed.items.first?.signals == ["hint"])
        #expect(listed.items.first?.band == "high")
    }

    // MARK: - A reply the model missed is listed as not filed yet

    @Test func aMissedReplyIsNotCovered() async {
        let text = "Pay the invented fee by Friday. Please reply."
        let model = ScriptedModel(extractions: [.obj([("items", .array([item("Pay the invented fee by Friday", "Pay the fee", "pay", when: "by Friday")]))])])
        let interp = await Clerk(model: model).read(input(text), filing: [], hint: nil, now: now)
        #expect(interp.items.map(\.title) == ["Pay the fee"])
        #expect(interp.unfiled.map(\.span.text) == ["Please reply."])
        #expect(interp.unfiled.map(\.reason) == ["not_covered"])
        #expect(interp.outcome == "partial")
    }

    // MARK: - Ids that differ only by JSON type are never offered to the duplicate check

    @Test func idsThatLookAlikeAreNeverMatched() async {
        let text = "Renewed the invented permit, done."
        let s = CaptureText.sentences(text)
        let words = FilingBinder.significantWords("Renew the invented permit")
        let number = FilingBinder.Candidate(id: .number(JSONNumber(text: "7")), title: "Renew the invented permit", words: words)
        let string = FilingBinder.Candidate(id: .str("7"), title: "Renew the invented permit sticker", words: words)
        let binder = FilingBinder(name: "home-example", description: "An invented home", folder: folder, openItems: [number, string])
        let model = ScriptedModel(extractions: [])
        model.duplicates = ["permit": ("7", "done")]
        var it = ClerkItem(title: "Renew the invented permit", action: "other", sentence: s[0], people: [])
        it.binder = "home-example"
        var interp = Interpretation(id: "interp-bugbot-1", event: "evt-bugbot", model: "scripted", items: [it])
        await Clerk(model: model).checkDuplicates(&interp, filing: [binder], today: today, locale: "en")
        #expect(interp.items.first?.match == nil)

        // One of them alone is still matched.
        let single = FilingBinder(name: "home-example", description: "An invented home", folder: folder, openItems: [number])
        var again = Interpretation(id: "interp-bugbot-2", event: "evt-bugbot", model: "scripted", items: [it])
        await Clerk(model: model).checkDuplicates(&again, filing: [single], today: today, locale: "en")
        #expect(again.items.first?.match?.candidate.id == .number(JSONNumber(text: "7")))
        #expect(again.items.first?.match?.relation == "done")
    }

    // MARK: - Small extraction fixes

    @Test func completedIsACompletionWord() async {
        let s = CaptureText.sentences("Completed the invented permit renewal.")
        let renewal = FilingBinder.Candidate(id: .str("home-example-2026-003"), title: "Invented permit renewal",
                                             words: FilingBinder.significantWords("Invented permit renewal"))
        let binder = FilingBinder(name: "home-example", description: "An invented home", folder: folder, openItems: [renewal])
        let model = ScriptedModel(extractions: [])
        model.duplicates = ["permit": ("home-example-2026-003", "done")]
        var it = ClerkItem(title: "Complete the permit renewal", action: "other", sentence: s[0], people: [])
        it.binder = "home-example"
        var interp = Interpretation(id: "interp-bugbot-3", event: "evt-bugbot", model: "scripted", items: [it])
        await Clerk(model: model).checkDuplicates(&interp, filing: [binder], today: today, locale: "en")
        #expect(interp.items.first?.match?.relation == "done")
    }

    @Test func aTypographicApostropheKeepsTheDueRole() {
        #expect(DateGrammar.role(sentence: "Attendre le rapport de Example Notaire d’ici vendredi.", whenText: "d’ici vendredi", waiting: true) == .due)
    }

    @Test func itemsAreInTextOrder() async {
        let text = "Call the invented plumber. Pay the invented fee."
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("Pay the invented fee", "Pay the fee", "pay"),
            item("Call the invented plumber", "Call the plumber", "call"),
        ]))])])
        let interp = await Clerk(model: model).read(input(text), filing: [], hint: nil, now: now)
        #expect(interp.items.map(\.title) == ["Call the plumber", "Pay the fee"])
    }

    @Test func aPrivateUpdateKeepsTheActionsKind() {
        let text = "Pay the invented fee by November 1."
        let s = CaptureText.sentences(text)
        let fee = FilingBinder.Candidate(id: .str("home-example-2026-004"), title: "Pay the invented fee", words: [], noDeadline: true)
        var it = ClerkItem(title: "Pay the invented fee", action: "pay", sentence: s[0], people: [])
        it.binder = "home-example"
        it.band = "high"
        it.whenText = "by November 1"
        it.whenRole = .due
        it.whenResolved = CalendarDate(year: 2026, month: 11, day: 1)
        it.match = ClerkItem.Match(candidate: fee, relation: "update")
        let interp = Interpretation(id: "interp-bugbot-4", event: "evt-bugbot", model: "scripted", items: [it])
        let built = Clerk.itemOps([it], event: input(text, isPrivate: true), today: today, actor: JSONObject(), interp: interp, now: now)
        #expect(built.ops.first?["op"] == .str("update_item"))
        #expect(built.ops.first?["args"]?["set"]?["kind"] == .str("payment"))
        #expect(built.ops.first?["args"]?["set"]?["redact"] == .bool(true))
    }
}

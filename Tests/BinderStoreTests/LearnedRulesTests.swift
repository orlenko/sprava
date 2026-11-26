@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import Testing

/// Learned rules as text (decisions.md D46; docs/binder-instructions.md §4.4): where a rule's line goes in the person's
/// part of `AGENTS.md`, what a rule may hold, and the card that proposes one. Invented text only.
@Suite struct LearnedRulesTests {
    let day = CalendarDate.strict("2026-11-26")!
    let rule = "Notices from the building manager go in notices/."

    @Test func theFirstRuleStartsTheSectionAtTheEnd() {
        #expect(LearnedRules.adding(rule, on: day, to: "") == "## Learned rules\n\n- 2026-11-26: \(rule)\n")
        #expect(LearnedRules.adding(rule, on: day, to: "Bills go in bills.\n")
                == "Bills go in bills.\n\n## Learned rules\n\n- 2026-11-26: \(rule)\n")
        #expect(LearnedRules.adding(rule, on: day, to: "Bills go in bills.\n\n\n")
                == "Bills go in bills.\n\n## Learned rules\n\n- 2026-11-26: \(rule)\n")
        #expect(LearnedRules.adding(rule, on: day, to: "No break at the end")
                == "No break at the end\n\n## Learned rules\n\n- 2026-11-26: \(rule)\n")
    }

    @Test func aLaterRuleGoesLastUnderTheHeadingAndTheRestKeepsItsBytes() {
        let text = "Bills go in bills.\r\n\n## Learned rules\n\n- 2026-10-01: Keep receipts for a year.\n\n## People\n\nAn invented neighbour.\n"
        #expect(LearnedRules.adding(rule, on: day, to: text)
                == "Bills go in bills.\r\n\n## Learned rules\n\n- 2026-10-01: Keep receipts for a year.\n- 2026-11-26: \(rule)\n\n## People\n\nAn invented neighbour.\n")
        // A heading with nothing under it yet, and one at the end of the text.
        #expect(LearnedRules.adding(rule, on: day, to: "## Learned rules\n## People\n")
                == "## Learned rules\n\n- 2026-11-26: \(rule)\n\n## People\n")
        #expect(LearnedRules.adding(rule, on: day, to: "Text.\n\n## Learned rules")
                == "Text.\n\n## Learned rules\n\n- 2026-11-26: \(rule)\n")
        // A smaller heading belongs to the section; a heading inside a fenced block is text.
        let nested = "## Learned rules\n\n### Filing\n\n- 2026-10-01: Keep receipts.\n\n```\n## Learned rules\n```\n"
        #expect(LearnedRules.adding(rule, on: day, to: nested) == nested + "- 2026-11-26: \(rule)\n")
    }

    @Test func aFenceOfAnotherMarkOrAShorterOneDoesNotCloseABlock() {
        // The heading shown inside a four-mark block that itself holds a three-mark fence, and inside a tilde block that
        // holds backticks, is text: the rule goes under a new heading at the end.
        for block in ["````\n```\n## Learned rules\n```\n````\n", "~~~\n```\n## Learned rules\n~~~\n", "```text\n## Learned rules\n``` not a close\n```\n"] {
            #expect(LearnedRules.adding(rule, on: day, to: block) == block + "\n## Learned rules\n\n- 2026-11-26: \(rule)\n", "\(block.debugDescription)")
        }
        // After a block that closed, a heading is a heading again.
        let after = "```\nexample\n```\n\n## Learned rules\n\n- 2026-10-01: Keep receipts.\n"
        #expect(LearnedRules.adding(rule, on: day, to: after) == after + "- 2026-11-26: \(rule)\n")
    }

    @Test func aRuleAlreadyThereIsNotAddedAgain() {
        let once = LearnedRules.adding(rule, on: day, to: "Bills go in bills.\n")
        #expect(LearnedRules.adding(rule, on: day, to: once) == once)
        // Tried again the next day, after the first try saved it.
        #expect(LearnedRules.adding(rule, on: CalendarDate.strict("2026-11-27")!, to: once) == once)
        // The same words elsewhere in the text are not the rule.
        let elsewhere = "- 2026-11-26: \(rule)\n"
        #expect(LearnedRules.adding(rule, on: day, to: elsewhere) == elsewhere + "\n## Learned rules\n\n- 2026-11-26: \(rule)\n")
    }

    @Test func whatIsAddedReadsBackAsThePersonsPart() throws {
        // Nothing a rule may hold makes Sprava's own section or breaks the file's markers.
        let text = LearnedRules.adding(rule, on: day, to: "Bills go in bills.\n")
        let parsed = try BinderInstructions.parse(text).get()
        #expect(parsed.section.isEmpty && parsed.text == text)
    }

    @Test func aRuleIsOnePlainLine() {
        #expect(LearnedRules.problem(rule) == nil)
        #expect(LearnedRules.problem(String(repeating: "r", count: 500)) == nil)
        let bad = ["", "   ", " leading space", "trailing space ", String(repeating: "r", count: 501), "two\nlines", "a\ttab", "a\u{0}nul",
                   "a line\u{2028}separator", "right\u{202E}to left", "zero\u{FEFF}width",
                   BinderInstructions.begin, "text \(BinderInstructions.end)", ManualAddendum.marker, "an <!-- open comment", "a close --> comment"]
        for text in bad { #expect(LearnedRules.problem(text) != nil, "\(text.debugDescription)") }
    }

    @Test func theCardCarriesTheRuleAndNothingElse() throws {
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))])
        let made = try RuleCard(rule: rule, reason: "  You said to remember it.\n", about: .filing).proposal(actor: actor)
        let card = try #require(RuleCard(made))
        #expect(card == RuleCard(rule: rule, reason: "You said to remember it.", about: .filing))
        // Its one op is a log entry that names what the rule is about, never its text.
        #expect(made.ops.count == 1 && made.ops[0]["op"] == .str("add_log_entry"))
        #expect(!JSONWriter.compact(.array(made.ops.map(JSONValue.object))).contains("building manager"))
        #expect(made.raw["title"] == .str("A rule for filing"))

        // A card with another op, another title or an unknown subject is not a rule card.
        var other = made.raw
        other.set("ops", .array([.object(made.ops[0]), .object(made.ops[0])]))
        #expect(RuleCard(Proposal(raw: other)) == nil)
        other = made.raw
        other.set("title", .str("Something else"))
        #expect(RuleCard(Proposal(raw: other)) == nil)
        other = made.raw
        other.set("provenance", .obj([("rule", .obj([("text", .string(rule)), ("reason", .str("r")), ("about", .str("everything"))]))]))
        #expect(RuleCard(Proposal(raw: other)) == nil)

        #expect(throws: RuleCard.Refused.self) { _ = try RuleCard(rule: "two\nlines", reason: "r", about: .filing).proposal(actor: actor) }
        #expect(throws: RuleCard.Refused.self) { _ = try RuleCard(rule: rule, reason: " ", about: .filing).proposal(actor: actor) }
        #expect(throws: RuleCard.Refused.self) { _ = try RuleCard(rule: rule, reason: String(repeating: "r", count: 1_001), about: .filing).proposal(actor: actor) }
    }
}

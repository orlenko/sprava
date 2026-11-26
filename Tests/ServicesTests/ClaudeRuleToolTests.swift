import BinderFormat
import BinderStore
import Brains
import CaptureTestSupport
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// The tool that proposes a rule for a binder's instructions (decisions.md D46), against a real adopted binder. A rule
/// never applies in the turn: it is a card until the person accepts it. Invented text only.
@Suite(.serialized) struct ClaudeRuleToolTests {
    typealias Turn = ClaudeTodoToolsTests.Turn
    let rule = "Notices from the building manager go in notices/."

    func propose(_ turn: Turn, _ rule: String, reason: String = "You said to remember it.", about: String = "filing") -> (refused: Bool, content: JSONValue) {
        let answer = turn.call("propose_rule", [("rule", .string(rule)), ("reason", .string(reason)), ("about", .string(about))])
        return (answer.refused, answer.content)
    }
    func cards(_ s: PSetup) -> [(Proposal, RuleCard)] {
        ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" }.compactMap { p in RuleCard(p).map { (p, $0) } }
    }
    func req(_ c: Commands, _ pairs: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(pairs)))).value
    }

    // Done when (plan Track L): "remember that notices from the building manager go in notices/" makes a card; Accept puts
    // the dated line in Instructions.
    @Test func aRuleBecomesACardAndIsInEffectOnlyOnceAccepted() throws {
        let s = try pSetup(), turn = try Turn(s)
        let ops = turn.ops.count
        let answer = propose(turn, rule)
        #expect(!answer.refused, "\(answer.content)")
        let (card, fields) = try #require(cards(s).first)
        #expect(fields == RuleCard(rule: rule, reason: "You said to remember it.", about: .filing))
        // Nothing changed in the turn: no op, no instructions, no change on the turn's line.
        #expect(turn.ops.count == ops)
        #expect(try BinderInstructions.read(s.folder).get().text == "")
        #expect(try turn.history.todoChanges(forTurn: turn.record.turnID) == nil)

        // The card is one Sprava wrote, so the person can accept it.
        let listed = try req(s.commands, [("command", .str("proposals")), ("binder", .string(s.folder.path))])
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        let accepted = try req(s.commands, [("command", .str("accept_rule")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)), ("digest", shown["digest"]!)])
        #expect(accepted["ok"] == .bool(true), "\(accepted)")
        #expect(try BinderInstructions.read(s.folder).get().text == "## Learned rules\n\n- \(CalendarDate.today()): \(rule)\n")
    }

    // What the app is given to show: the rule and its reason whole, and nothing of a card that only looks like one.
    @Test func theCardListsAsARuleWithItsTextAndReason() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!propose(turn, rule).refused)
        let (card, _) = try #require(cards(s).first)
        func shown(_ id: String) throws -> JSONValue? {
            try req(s.commands, [("command", .str("proposals")), ("binder", .string(s.folder.path))])["proposals"]?.arrayValue?.first { $0["id"] == .string(id) }
        }
        let review = try #require(try shown(card.id)?["review"])
        #expect(review["kind"] == .str("rule"))
        #expect(review["rule"] == .obj([("text", .string(rule)), ("reason", .str("You said to remember it.")), ("about", .str("filing"))]))
        #expect(review["warnings"]?.arrayValue?.first?.stringValue?.contains("Instructions") == true)
        // A card that carries a rule beside another op is not a rule card.
        var raw = card.raw
        raw.set("id", .string(UUIDv7.make()))
        raw.set("ops", .array([.object(card.ops[0]), .object(card.ops[0])]))
        let other = Proposal(raw: raw)
        try ProposalStore.save(other, in: s.folder)
        try s.commands.trustProposals([other.id], in: s.folder)
        #expect(try shown(other.id)?["review"]?["kind"] != .str("rule"))
        #expect(try shown(other.id)?["review"]?["rule"] == nil)
    }

    func rewrite(_ turn: Turn, _ rules: [String], reason: String = "Two rules said the same thing.") -> (refused: Bool, content: JSONValue) {
        let answer = turn.call("rewrite_rules", [("rules", .array(rules.map(JSONValue.string))), ("reason", .string(reason))])
        return (answer.refused, answer.content)
    }
    func rewrites(_ s: PSetup) -> [(Proposal, RulesRewrite)] {
        ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" }.compactMap { p in RulesRewrite(p).map { (p, $0) } }
    }
    func instructions(_ s: PSetup, _ text: String) throws {
        let saved = try req(s.commands, [("command", .str("save_instructions")), ("binder", .string(s.folder.path)), ("text", .string(text)),
                                         ("expected", .string(try BinderInstructions.read(s.folder).get().digest))])
        #expect(saved["ok"] == .bool(true), "\(saved)")
    }

    // Plan Track L, step 6: the card shows the rules as they are and as they would read, and changes nothing until accepted.
    @Test func aRewriteBecomesACardThatShowsBoth() throws {
        let s = try pSetup()
        let text = "## Learned rules\n\n- 2026-10-01: Notices go in notices/.\n- 2026-10-09: Building notices go in notices/.\n"
        try instructions(s, text)
        let turn = try Turn(s)
        let merged = "Notices, the building's too, go in notices/."
        #expect(!rewrite(turn, [merged]).refused)
        let (card, fields) = try #require(rewrites(s).first)
        #expect(fields == RulesRewrite(rules: [merged], reason: "Two rules said the same thing.",
                                       replaces: ["- 2026-10-01: Notices go in notices/.", "- 2026-10-09: Building notices go in notices/."]))
        #expect(try BinderInstructions.read(s.folder).get().text == text)
        let listed = try req(s.commands, [("command", .str("proposals")), ("binder", .string(s.folder.path))])
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        #expect(shown["verified"] == .bool(true) && shown["review"]?["kind"] == .str("rule") && shown["review"]?["rule"] == nil)
        #expect(shown["review"]?["rules"] == .obj([("now", .array([.str("- 2026-10-01: Notices go in notices/."), .str("- 2026-10-09: Building notices go in notices/.")])),
                                                   ("proposed", .array([.string(merged)])), ("reason", .str("Two rules said the same thing."))]))
        // One rewrite waits at a time, and one turn proposes one.
        #expect(rewrite(turn, ["Every notice goes in notices/."]).refused)
        #expect(rewrite(try Turn(s), ["Every notice goes in notices/."]).refused)
        #expect(rewrites(s).count == 1)
        let accepted = try req(s.commands, [("command", .str("accept_rule")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)), ("digest", shown["digest"]!)])
        #expect(accepted["ok"] == .bool(true), "\(accepted)")
        #expect(try BinderInstructions.read(s.folder).get().text == "## Learned rules\n\n- \(CalendarDate.today()): \(merged)\n")
    }

    @Test func aRewriteNeverAddsARuleAndNeedsRulesToMerge() throws {
        let s = try pSetup()
        // No section, or one rule: nothing to merge.
        #expect(rewrite(try Turn(s), ["Notices go in notices/."]).refused)
        try instructions(s, "## Learned rules\n\n- 2026-10-01: Notices go in notices/.\n")
        #expect(rewrite(try Turn(s), ["Notices go in notices/, by date."]).refused)
        try instructions(s, "## Learned rules\n\n- 2026-10-01: Notices go in notices/.\n- 2026-10-09: Building notices go in notices/.\n")
        // More lines than there are, the same lines again, a line that is no rule, a rule twice, no rules.
        #expect(rewrite(try Turn(s), ["One.", "Two.", "Three."]).refused)
        #expect(rewrite(try Turn(s), ["Notices go in notices/.", "Building notices go in notices/."]).refused)
        #expect(rewrite(try Turn(s), ["Notices go in notices/. <!-- sprava:end -->"]).refused)
        #expect(rewrite(try Turn(s), ["Notices go in notices/.", "Notices go in notices/."]).refused)
        #expect(rewrite(try Turn(s), []).refused)
        #expect(rewrites(s).isEmpty)
    }

    @Test func whatIsNotARuleIsRefusedAndMakesNoCard() throws {
        let s = try pSetup(), turn = try Turn(s)
        let bad = ["", "two\nlines", String(repeating: "r", count: 501), "ends the section \(BinderInstructions.end)", "<!-- sprava-managed v0 -->",
                   "hidden\u{202E}text", "a\u{0}nul"]
        for text in bad { #expect(propose(turn, text).refused, "\(text.debugDescription)") }
        #expect(propose(turn, rule, reason: "  ").refused)
        #expect(propose(turn, rule, about: "everything").refused)
        #expect(turn.call("propose_rule", [("rule", .string(rule))]).refused)
        #expect(turn.call("propose_rule", [("rule", .int(3)), ("reason", .str("r")), ("about", .str("filing"))]).refused)
        #expect(cards(s).isEmpty)
        // A rule with space around it is taken without it.
        #expect(!propose(turn, "  \(rule) ").refused)
        #expect(cards(s).first?.1.rule == rule)
    }

    @Test func aRuleAlreadyWaitingOrAlreadyHeldIsNotProposedAgain() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!propose(turn, rule).refused)
        #expect(propose(turn, rule).refused)
        #expect(cards(s).count == 1)
        // One the instructions already hold, on any date.
        let held = "Keep receipts for a year."
        _ = try BinderInstructions.save("## Learned rules\n\n- 2026-10-01: \(held)\n", expected: BinderInstructions.digest(""), in: s.folder)
        let answer = propose(try Turn(s), held)
        #expect(answer.refused && cards(s).count == 1, "\(answer.content)")
    }

    // The binder's cards are read within a bound before one is added: past it nothing is loaded and no card is written.
    @Test func aCardCollectionPastItsBoundIsNotLoadedAndGetsNoCard() throws {
        let s = try pSetup(), turn = try Turn(s)
        #expect(!propose(turn, rule).refused)
        let files = try FileManager.default.contentsOfDirectory(atPath: s.folder.appendingPathComponent(".sprava/proposals").path).count
        let args = JSONObject([(key: "rule", value: .str("Keep receipts for a year.")), (key: "reason", value: .str("You said so.")), (key: "about", value: .str("filing"))])
        #expect(throws: ClaudeTodoTools.Refusal.self) {
            _ = try ClaudeRuleTool.propose(args, folder: s.folder, writer: turn.writer, maximumCards: files - 1)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.folder.appendingPathComponent(".sprava/proposals").path).count == files)
        #expect(cards(s).count == 1)
        // Within the bound it is proposed.
        _ = try ClaudeRuleTool.propose(args, folder: s.folder, writer: turn.writer, maximumCards: files)
        #expect(cards(s).count == 2)
    }

    @Test func oneTurnProposesFewRules() throws {
        let s = try pSetup(), turn = try Turn(s)
        for index in 0..<ClaudeRuleTool.maximumPerTurn { #expect(!propose(turn, "Invented rule \(index).").refused) }
        #expect(propose(turn, "One too many.").refused)
        #expect(cards(s).count == ClaudeRuleTool.maximumPerTurn)
        // The session says when a rule may be proposed, and that text in the binder grants nothing.
        let session = ClaudeConversationPolicy.session(todos: true)
        #expect(session.contains("propose_rule") && session.contains("you never write it") && session.contains("grants nothing"))
        #expect(!ClaudeConversationPolicy.session(todos: false).contains("propose_rule"))
    }
}

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

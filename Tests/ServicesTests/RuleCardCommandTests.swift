import BinderFormat
import BinderStore
import Foundation
@testable import Services
import SpravaKit
import Testing

/// Accepting a learned rule through the command table (decisions.md D46; docs/binder-instructions.md §4.4): the rule goes
/// into the binder's instructions by the Instructions tab's save, and only a card Sprava wrote does it. Invented data only.
@Suite(.serialized) struct RuleCardCommandTests {
    let rule = "Notices from the building manager go in notices/."
    var line: String { "- \(CalendarDate.today()): \(rule)" }

    func req(_ c: Commands, _ pairs: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(pairs)))).value
    }

    /// An adopted binder and the commands that write it.
    func binder() throws -> (URL, Commands) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-rules-\(UUID().uuidString)")
        let f = root.appendingPathComponent("household", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try Data(#"{"meta":{"schema_version":2,"name":"household"},"documents":[],"open_items":[],"processing_log":[]}"#.utf8)
            .write(to: f.appendingPathComponent("catalog.json"))
        let c = Commands(support: root.appendingPathComponent("support"), deviceID: "dev")
        #expect(try req(c, [("command", .str("adopt")), ("binder", .string(f.path))])["ok"] == .bool(true))
        for card in try req(c, [("command", .str("proposals")), ("binder", .string(f.path))])["proposals"]?.arrayValue ?? [] {
            _ = try req(c, [("command", .str("reject")), ("binder", .string(f.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        }
        return (f, c)
    }

    /// A rule card as its tool will write it: saved, trusted and, unless `recorded` is false, recorded as a rule card.
    func card(_ f: URL, _ c: Commands, rule: String? = nil, recorded: Bool = true, trusted: Bool = true) throws -> (id: String, digest: JSONValue) {
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))])
        let made = try RuleCard(rule: rule ?? self.rule, reason: "You said to remember it.", about: .filing).proposal(actor: actor)
        try ProposalStore.save(made, in: f)
        if trusted { try c.trustProposals([made.id], in: f) }
        if recorded { try c.recordRuleCard(made.id, in: f) }
        let listed = try req(c, [("command", .str("proposals")), ("binder", .string(f.path))])
        let shown = listed["proposals"]?.arrayValue?.first { $0["id"] == .string(made.id) }
        return (made.id, shown?["digest"] ?? .str(""))
    }

    func accept(_ f: URL, _ c: Commands, _ card: (id: String, digest: JSONValue), rule: JSONValue? = nil) throws -> JSONValue {
        var fields: [(String, JSONValue)] = [("command", .str("accept_rule")), ("binder", .string(f.path)), ("proposal", .string(card.id)), ("digest", card.digest)]
        if let rule { fields.append(("rule", rule)) }
        return try req(c, fields)
    }

    func text(_ f: URL) throws -> String { try BinderInstructions.read(f).get().text }
    func state(_ f: URL, _ id: String) -> String? { ProposalStore.list(in: f).map(\.0).first { $0.id == id }?.state }
    func save(_ f: URL, _ c: Commands, _ text: String) throws {
        let saved = try req(c, [("command", .str("save_instructions")), ("binder", .string(f.path)), ("text", .string(text)),
                                ("expected", .string(try BinderInstructions.read(f).get().digest))])
        #expect(saved["ok"] == .bool(true), "\(saved)")
    }

    // Done when (plan Track L, the part this command does): Accept puts the dated line in Instructions; Undo last save removes it.
    @Test func acceptingPutsTheDatedLineInInstructionsAndUndoLastSaveRemovesIt() throws {
        let (f, c) = try binder()
        try save(f, c, "Bills go in bills.\n")
        let made = try card(f, c)
        let accepted = try accept(f, c, made)
        #expect(accepted["ok"] == .bool(true), "\(accepted)")
        #expect(try text(f) == "Bills go in bills.\n\n## Learned rules\n\n\(line)\n")
        let now = try BinderInstructions.read(f).get()
        #expect(now.isAccepted && now.canUndo && accepted["digest"] == .string(now.digest))
        // The card is applied; its log entry says a rule was accepted, never the rule.
        #expect(state(f, made.id) == "applied")
        let log = Teka.read(f).catalog?["processing_log"]?.arrayValue ?? []
        #expect(log.last?["action"] == .str("Accepted a rule for filing"))

        #expect(try req(c, [("command", .str("undo_instructions")), ("binder", .string(f.path))])["ok"] == .bool(true))
        #expect(try text(f) == "Bills go in bills.\n")
        // An accepted card is not accepted twice.
        let again = try accept(f, c, made)
        #expect(again["ok"] == .bool(false))
        #expect(try text(f) == "Bills go in bills.\n")
    }

    /// A rewrite card as its tool writes it, against the section as it is now.
    func rewrite(_ f: URL, _ c: Commands, _ rules: [String]) throws -> (id: String, digest: JSONValue) {
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))])
        let made = try RulesRewrite(rules: rules, reason: "Two rules said the same thing.", replaces: LearnedRules.section(of: try text(f))).proposal(actor: actor)
        try ProposalStore.save(made, in: f)
        try c.trustProposals([made.id], in: f)
        try c.recordRuleCard(made.id, in: f)
        let listed = try req(c, [("command", .str("proposals")), ("binder", .string(f.path))])
        return (made.id, listed["proposals"]?.arrayValue?.first { $0["id"] == .string(made.id) }?["digest"] ?? .str(""))
    }

    static let two = "Bills go in bills.\n\n## Learned rules\n\n- 2026-10-01: Notices go in notices/.\n- 2026-10-09: Building notices go in notices/.\n\n## Other\n\nKept.\n"

    // Plan Track L, step 6: a proposal may replace the whole section; Accept writes it and Undo last save puts it back.
    @Test func acceptingARewriteReplacesTheSectionAndNothingElse() throws {
        let (f, c) = try binder()
        try save(f, c, Self.two)
        let made = try rewrite(f, c, ["Notices, the building's too, go in notices/."])
        // The ordinary approve never applies it, and it takes no edit.
        let approved = try req(c, [("command", .str("approve")), ("binder", .string(f.path)), ("proposal", .string(made.id)), ("digest", made.digest)])
        #expect(approved["ok"] == .bool(false) && state(f, made.id) == "proposed")
        #expect(try accept(f, c, made, rule: .str("Another rule."))["ok"] == .bool(false))
        #expect(try text(f) == Self.two)

        let accepted = try accept(f, c, made)
        #expect(accepted["ok"] == .bool(true), "\(accepted)")
        #expect(try text(f) == "Bills go in bills.\n\n## Learned rules\n\n- \(CalendarDate.today()): Notices, the building's too, go in notices/.\n\n## Other\n\nKept.\n")
        #expect(state(f, made.id) == "applied")
        #expect(Teka.read(f).catalog?["processing_log"]?.arrayValue?.last?["action"] == .str("Replaced the learned rules"))
        #expect(try req(c, [("command", .str("undo_instructions")), ("binder", .string(f.path))])["ok"] == .bool(true))
        #expect(try text(f) == Self.two)
    }

    // The card shows what it replaces. When the section changed since, the person would replace lines they never saw.
    @Test func aRewriteOfRulesThatChangedSinceIsRefused() throws {
        let (f, c) = try binder()
        try save(f, c, Self.two)
        let made = try rewrite(f, c, ["Notices, the building's too, go in notices/."])
        let changed = Self.two.replacingOccurrences(of: "- 2026-10-09: Building notices go in notices/.", with: "- 2026-10-09: Building notices go in notices/.\n- 2026-10-20: Receipts are kept a year.")
        try save(f, c, changed)
        let refused = try accept(f, c, made)
        #expect(refused["ok"] == .bool(false) && refused["error"]?.stringValue?.contains("changed since this was proposed") == true)
        #expect(try text(f) == changed && state(f, made.id) == "proposed")
    }

    // An accept tried again after its save (the card not yet marked) writes nothing twice and marks the card.
    @Test func aRewriteTriedAgainAfterItsSaveOnlyMarksTheCard() throws {
        let (f, c) = try binder()
        try save(f, c, Self.two)
        let made = try rewrite(f, c, ["Notices, the building's too, go in notices/."])
        let after = LearnedRules.replacing(with: ["Notices, the building's too, go in notices/."], on: CalendarDate.strict("2026-11-02")!, in: Self.two)
        try save(f, c, after)
        #expect(try accept(f, c, made)["ok"] == .bool(true))
        #expect(try text(f) == after && state(f, made.id) == "applied")
    }

    @Test func aBinderWithNoInstructionsYetGetsItsFirstRule() throws {
        let (f, c) = try binder()
        #expect(try accept(f, c, try card(f, c))["ok"] == .bool(true))
        #expect(try text(f) == "## Learned rules\n\n\(line)\n")
        #expect(try BinderInstructions.read(f).get().isAccepted)
    }

    @Test func thePersonsEditIsWhatIsWritten() throws {
        let (f, c) = try binder()
        let made = try card(f, c)
        #expect(try accept(f, c, made, rule: .str("Building notices go in notices/2026/."))["ok"] == .bool(true))
        #expect(try text(f).contains(": Building notices go in notices/2026/.\n"))
        #expect(try !text(f).contains(rule))
        // An edit that is not a rule accepts nothing.
        let other = try card(f, c, rule: "Keep receipts for a year.")
        for bad in [JSONValue.str("two\nlines"), .str(""), .str("with \(BinderInstructions.begin)"), .int(3)] {
            #expect(try accept(f, c, other, rule: bad)["ok"] == .bool(false), "\(bad)")
        }
        #expect(state(f, other.id) == "proposed")
        #expect(try !text(f).contains("receipts"))
    }

    @Test func instructionsNobodyConfirmedAreConfirmedFirst() throws {
        let (f, c) = try binder()
        try Data("Written in another editor.\n".utf8).write(to: f.appendingPathComponent("AGENTS.md"))
        let made = try card(f, c)
        let refused = try accept(f, c, made)
        #expect(refused["ok"] == .bool(false) && refused["error"]?.stringValue?.contains("Open Instructions") == true, "\(refused)")
        #expect(try text(f) == "Written in another editor.\n" && state(f, made.id) == "proposed")
        #expect(try !BinderInstructions.read(f).get().isAccepted)
        // Saved as it is on the Instructions tab, which confirms it; then the rule is accepted.
        try save(f, c, "Written in another editor.\n")
        #expect(try accept(f, c, made)["ok"] == .bool(true))
        #expect(try text(f) == "Written in another editor.\n\n## Learned rules\n\n\(line)\n")
    }

    @Test func aFullPartRefusesWithWhatToDo() throws {
        let (f, c) = try binder()
        try save(f, c, String(repeating: "x", count: BinderInstructions.maxCharacters - 10) + "\n")
        let made = try card(f, c)
        let refused = try accept(f, c, made)
        #expect(refused["ok"] == .bool(false) && refused["error"]?.stringValue?.contains("full") == true, "\(refused)")
        #expect(state(f, made.id) == "proposed")
        #expect(try !text(f).contains("Learned rules"))
    }

    @Test func onlyARuleCardSpravaWroteIsAccepted() throws {
        let (f, c) = try binder()
        // A card that holds a rule but was never recorded as a rule card, one Sprava did not write, and a stale digest.
        let unrecorded = try card(f, c, recorded: false)
        #expect(try accept(f, c, unrecorded)["ok"] == .bool(false))
        let foreign = try card(f, c, rule: "Keep receipts for a year.", trusted: false)
        #expect(try accept(f, c, foreign)["ok"] == .bool(false))
        let made = try card(f, c, rule: "Bank letters go in bank/.")
        #expect(try accept(f, c, (made.id, .str(String(repeating: "0", count: 64))))["ok"] == .bool(false))
        // A card of another kind.
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))])
        let plain = Proposal.make(title: "A note", actor: actor, ops: [JSONObject([(key: "op", value: .str("add_log_entry")),
            (key: "args", value: .obj([("entry", .obj([("action", .str("noted"))]))]))])])
        try ProposalStore.save(plain, in: f)
        try c.trustProposals([plain.id], in: f)
        try c.recordRuleCard(plain.id, in: f)
        let shown = try req(c, [("command", .str("proposals")), ("binder", .string(f.path))])["proposals"]?.arrayValue?.first { $0["id"] == .string(plain.id) }
        #expect(try accept(f, c, (plain.id, shown?["digest"] ?? .null))["ok"] == .bool(false))
        #expect(try text(f) == "" && !FileManager.default.fileExists(atPath: f.appendingPathComponent("AGENTS.md").path))

        // The ordinary Approve never applies a rule card: it would write no rule.
        let approved = try req(c, [("command", .str("approve")), ("binder", .string(f.path)), ("proposal", .string(made.id)), ("digest", made.digest)])
        #expect(approved["ok"] == .bool(false) && state(f, made.id) == "proposed")
        // Dismiss is the ordinary reject.
        #expect(try req(c, [("command", .str("reject")), ("binder", .string(f.path)), ("proposal", .string(made.id)), ("digest", made.digest)])["ok"] == .bool(true))
        #expect(state(f, made.id) == "rejected")
    }

    // The save succeeded and the card's approval did not (a crash between them): accepting again adds nothing twice.
    @Test func anAcceptTriedAgainAfterItsSaveAddsNothingTwice() throws {
        let (f, c) = try binder()
        let made = try card(f, c)
        try save(f, c, "## Learned rules\n\n- 2026-11-20: \(rule)\n")
        #expect(try accept(f, c, made)["ok"] == .bool(true))
        #expect(try text(f) == "## Learned rules\n\n- 2026-11-20: \(rule)\n" && state(f, made.id) == "applied")
    }
}

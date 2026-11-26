import BinderFormat
import BinderStore
import Brains
import Foundation
import SpravaKit

/// The tool by which the agent of a person's turn proposes a rule for the binder's instructions (decisions.md D46;
/// docs/binder-instructions.md §4.4). It writes a card and nothing else: the rule is in effect only once the person
/// accepts it on the card, where they can edit it first. What a rule may hold is `LearnedRules`' to say, checked here
/// when it is proposed and again when it is accepted. `ClaudeTodoTools` holds the turn's lock and calls in here.
enum ClaudeRuleTool {
    typealias Refusal = ClaudeTodoTools.Refusal
    static let name = "propose_rule"
    /// A turn proposes few rules: each is a card the person must read.
    static let maximumPerTurn = 3
    /// Rule cards that may wait in one binder; past it the person settles some first.
    static let maximumWaiting = 20

    /// `maximumCards` bounds how many card files the binder may hold for the waiting rules to be read at all: decided
    /// cards stay in the folder, and a collection past the bound is never loaded (architecture 4.6).
    static func propose(_ args: JSONObject, folder: URL, writer: ClaudeTodoWriter, maximumCards: Int = ProposalStore.maximumEntries) throws -> JSONValue {
        guard let rule = args["rule"]?.stringValue, let reason = args["reason"]?.stringValue else {
            throw Refusal.invalid("Give the rule, one line, and the reason for it. Nothing was proposed.")
        }
        guard let about = args["about"]?.stringValue.flatMap(LearnedRules.About.init(rawValue:)) else {
            throw Refusal.invalid("Say what the rule is about: filing, drafting or routine. Nothing was proposed.")
        }
        let card = RuleCard(rule: rule.trimmingCharacters(in: .whitespaces), reason: reason, about: about)
        do {
            try writer.perform { commands in
                let made = try card.proposal(actor: JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))]))
                // A rule the instructions already hold, or one already waiting on a card, is not proposed again.
                if case .success(let instructions) = BinderInstructions.read(folder),
                   LearnedRules.adding(card.rule, on: CalendarDate.today(), to: instructions.text) == instructions.text {
                    throw Refusal.invalid("This binder's instructions already hold that rule. Nothing was proposed.")
                }
                let listed: [(Proposal, String)]
                do { listed = try ProposalStore.boundedList(in: folder, maxEntries: maximumCards) } catch {
                    throw Refusal.invalid("This binder's cards are too many or cannot be read safely, so none was added. Tell the person; nothing was proposed.")
                }
                let waiting = listed.map(\.0).filter { $0.state == "proposed" }.compactMap(RuleCard.init)
                guard !waiting.contains(where: { $0.rule == card.rule }) else {
                    throw Refusal.invalid("That rule is already on a card, waiting for the person. Nothing was proposed.")
                }
                guard waiting.count < maximumWaiting else {
                    throw Refusal.invalid("This binder has \(maximumWaiting) rules waiting on cards. Tell the person to accept or dismiss some first; nothing was proposed.")
                }
                try ProposalStore.save(made, in: folder)
                try commands.trustProposals([made.id], in: folder)
                try commands.recordRuleCard(made.id, in: folder)
            }
        } catch let refusal as Refusal { throw refusal }
        catch let refused as RuleCard.Refused { throw Refusal.invalid(refused.description + " Nothing was proposed.") }
        catch { throw Refusal.refused }
        return .obj([("ok", .bool(true)),
                     ("message", .str("The rule is on a card in this binder for the person to accept, edit or dismiss. It is not in effect until they accept it; tell them it is waiting."))])
    }

    static let tool = ClaudeAppTools.Tool(
        name: name,
        description: "Proposes one rule for this binder's instructions, on a card for the person to accept, edit or dismiss. Nothing changes until they accept it.",
        schema: .obj([("type", .str("object")), ("properties", .obj([
            ("rule", .obj([("type", .str("string")), ("description", .str("The rule as one plain line of at most \(LearnedRules.maxRule) characters, as the person would write it."))])),
            ("reason", .obj([("type", .str("string")), ("description", .str("Why: what the person said or corrected, in a sentence or two."))])),
            ("about", .obj([("type", .str("string")), ("enum", .array(LearnedRules.About.allCases.map { .string($0.rawValue) })),
                            ("description", .str("filing: where documents go and what they are called. drafting: how replies are written. routine: anything else this binder does again and again."))])),
        ])), ("required", .array([.str("rule"), .str("reason"), .str("about")])), ("additionalProperties", .bool(false))]))
}

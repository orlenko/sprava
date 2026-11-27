import BinderFormat
import BinderStore
import Brains
import Foundation
import SpravaKit

/// The tool by which the agent of a person's turn suggests an improvement to Sprava itself (decisions.md D47): what
/// this binder could not do, or keeps doing by hand. It writes a card in this binder and nothing else; the person's
/// approval carries the text to the Improvements binder, which the session never reaches (D16). A script's text is
/// read here, when the card is made, under the rules a draft's attachment is: a path inside the binder, never a key
/// file, a size bound. `ClaudeTodoTools` holds the turn's lock and calls in here.
enum ClaudeSuggestionTool {
    typealias Refusal = ClaudeTodoTools.Refusal
    static let name = "suggest_improvement"
    static let maximumPerTurn = 2
    /// Suggestion cards that may wait in one binder; past it the person settles some first.
    static let maximumWaiting = 10

    /// `counted` is true for the card Sprava makes of its own from counts (`ClaudeScriptRuns`): its actor is Sprava,
    /// with no model.
    static func suggest(_ args: JSONObject, folder: URL, writer: ClaudeTodoWriter, maximumCards: Int = ProposalStore.maximumEntries,
                        counted: Bool = false) throws -> JSONValue {
        guard let title = args["title"]?.stringValue, let attempted = args["attempted"]?.stringValue, let obstacle = args["obstacle"]?.stringValue else {
            throw Refusal.invalid("Give a title, what was attempted, and what stood in the way or keeps being repeated. Nothing was suggested.")
        }
        if let value = args["script"], value.stringValue == nil { throw Refusal.invalid("script is one path in this binder. Nothing was suggested.") }
        var script: SuggestionCard.Script?
        if let path = args["script"]?.stringValue {
            // Checked before the file is opened; the read goes from the binder's folder down with no link on the way.
            guard SuggestionCard.isScriptPath(path) else {
                throw Refusal.invalid("The script is not one a card may carry: give the path of a script inside the binder, under scripts/ or named as one, that is no key or credential file. Nothing was suggested.")
            }
            guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(path), under: folder, limit: SuggestionCard.maxScript),
                  let text = String(data: data, encoding: .utf8) else {
                throw Refusal.invalid("The script could not be read as text of at most \(SuggestionCard.maxScript / 1024) KiB. Suggest without it, or name the part that matters. Nothing was suggested.")
            }
            script = .init(path: path, text: text)
        }
        let card = SuggestionCard(title: title, attempted: attempted, obstacle: obstacle, script: script)
        do {
            try writer.perform { commands in
                let actor = counted
                    ? JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
                    : JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("claude"))])
                let made = try card.proposal(actor: actor)
                let listed: [(Proposal, String)]
                do { listed = try ProposalStore.boundedList(in: folder, maxEntries: maximumCards) } catch {
                    throw Refusal.invalid("This binder's cards are too many or cannot be read safely, so none was added. Tell the person; nothing was suggested.")
                }
                let waiting = listed.map(\.0).filter { $0.state == "proposed" }.compactMap(SuggestionCard.init)
                guard !waiting.contains(where: { $0.title == card.title.trimmingCharacters(in: .whitespaces) }) else {
                    throw Refusal.invalid("A suggestion with that title is already on a card, waiting for the person. Nothing was suggested.")
                }
                guard waiting.count < maximumWaiting else {
                    throw Refusal.invalid("This binder has \(maximumWaiting) suggestions waiting on cards. Tell the person to send or dismiss some first; nothing was suggested.")
                }
                try ProposalStore.save(made, in: folder)
                try commands.trustProposals([made.id], in: folder)
                try commands.recordSuggestionCard(made.id, in: folder)
            }
        } catch let refusal as Refusal { throw refusal }
        catch let refused as SuggestionCard.Refused { throw Refusal.invalid(refused.description + " Nothing was suggested.") }
        catch { throw Refusal.refused }
        return .obj([("ok", .bool(true)),
                     ("message", .str("The suggestion is on a card in this binder for the person to read, edit and send. Nothing has left this binder; tell them it is waiting."))])
    }

    static let tool = ClaudeAppTools.Tool(
        name: name,
        description: "Suggests an improvement to Sprava itself, on a card for the person to read, edit and send to their Improvements list. Nothing leaves this binder until they send it.",
        schema: .obj([("type", .str("object")), ("properties", .obj([
            ("title", .obj([("type", .str("string")), ("description", .str("One line of at most \(SuggestionCard.maxTitle) characters: what Sprava should be able to do."))])),
            ("attempted", .obj([("type", .str("string")), ("description", .str("What was attempted here, in general terms. No names, amounts or contents of this binder's documents."))])),
            ("obstacle", .obj([("type", .str("string")), ("description", .str("What stood in the way, or what keeps being done by hand or by script."))])),
            ("script", .obj([("type", .str("string")), ("description", .str("Optional: the path in this binder of the script that does the job now. Its text goes on the card, so it must hold no key or password."))])),
        ])), ("required", .array([.str("title"), .str("attempted"), .str("obstacle")])), ("additionalProperties", .bool(false))]))
}

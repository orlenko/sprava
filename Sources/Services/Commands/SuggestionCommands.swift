import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

extension Commands {
    /// The suggestion cards Sprava itself wrote, by binder and card id. Only these are sent to Improvements.
    private var suggestionCards: RuleCardRecord { RuleCardRecord(file: support.appendingPathComponent("improvements/suggestion-cards.json")) }

    /// Records a suggestion card Sprava wrote. Its writer calls this once the card is saved and trusted.
    public func recordSuggestionCard(_ id: String, in folder: URL) throws {
        try suggestionCards.record(key(folder, id))
    }

    /// `send_suggestion`: `{binder, proposal, digest, text?, parent, create_parent?}`. The person's approval of a
    /// suggestion card (decisions.md D47): the card's text, or the person's edit of it (`text`), becomes an open to-do
    /// in the Improvements binder, which is made on this first use under `parent` as `improvements_binder` makes it,
    /// and the card is applied in the binder it came from, where it leaves a log entry with none of the text.
    ///
    /// The to-do comes first: a card applied with nothing sent would lose what the person approved. The to-do carries
    /// the card's id, so an approval tried again after the to-do was written adds no second one. Answers
    /// `{improvements}`, the Improvements binder's folder.
    func sendSuggestion(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        guard case .string(let id)? = r["proposal"], case .string(let seen)? = r["digest"] else {
            throw Failure(message: "send_suggestion needs proposal and digest")
        }
        if let edit = r["text"], edit.stringValue == nil { throw Failure(message: "text must be text; nothing was sent") }
        let teka = Teka.read(f)
        guard teka.isAdopted else { throw Failure(message: "this binder is not adopted yet") }
        guard !teka.writesBlocked else { throw Failure(message: "this binder's writes are blocked until it is repaired; nothing was sent") }
        guard let recorded = try loadDigests()[key(f, id)] else { throw Failure(message: "this card was not written by Sprava, so it cannot be sent") }
        guard recorded == seen else { throw Failure(message: "this card changed since it was shown; reload it") }
        let proposal = try ProposalStore.load(id, in: f, expectedDigest: recorded)
        guard let card = SuggestionCard(proposal), suggestionCards.contains(key(f, id)) else {
            throw Failure(message: "this card holds no suggestion Sprava wrote, so it cannot be sent; nothing was changed")
        }
        guard proposal.state == "proposed" else { throw Failure(message: "this card is \(proposal.state), so nothing was sent") }
        do { _ = try card.checked() } catch { throw Failure(message: "\(error) Nothing was sent.") }
        let text = r["text"]?.stringValue ?? card.note
        if let problem = SuggestionCard.problem(note: text) { throw Failure(message: problem + " Nothing was sent.") }

        let improvements: URL
        do {
            guard let path = try builtInBinder(.improvements, r, now: now, today: today)["binder"]?.stringValue else { throw Failure(message: "no folder") }
            improvements = URL(fileURLWithPath: path, isDirectory: true)
        } catch { throw Failure(message: "The Improvements binder could not be used, so nothing was sent: \(error)") }
        let already = Teka.read(improvements).catalog?["open_items"]?.arrayValue?.contains { $0["suggestion_card"] == .string(id) } == true
        if !already {
            let item = JSONValue.obj([("id", .str("$new:1")), ("title", .string(card.title)), ("status", .str("open")), ("priority", .str("normal")),
                                      ("no_deadline", .bool(true)), ("details", .string(text)), ("suggestion_card", .string(id))])
            let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
            _ = try TekaStore(folder: improvements, client: client).applyMinting([.init(op: "add_item", args: .init([(key: "item", value: item)]), actor: actor)], now: now)
        }
        _ = try TekaStore(folder: f, client: client).approve(proposal, edited: nil, now: now)
        try recordDigests([id], in: f)
        return JSONObject([(key: "improvements", value: .string(improvements.path))])
    }
}

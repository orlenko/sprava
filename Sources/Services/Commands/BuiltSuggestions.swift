import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The suggestions this build of Sprava built (decisions.md D47; plan Track I, step 6). Export gives each suggestion a
/// code; the issue made from it keeps the code; the change that builds it adds a line here with the release's note.
enum BuiltSuggestions {
    struct Built: Equatable {
        /// The code Export wrote above the suggestion's text, `S-` and ten hex digits.
        let code: String
        /// What the release does about it: one line of plain words, shown to the person and kept in the binder's log.
        let note: String
    }

    static let all: [Built] = []

    /// A card's title: one line, bounded, naming the to-do it would close.
    static func cardTitle(_ title: String) -> String {
        let line = title.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "Built into Sprava: " + String(line.prefix(200))
    }
}

extension Commands {
    /// `close_built_suggestions`: no fields; the app sends it when it starts. For each open to-do in Improvements that a
    /// suggestion card made and this build lists as built, writes a card in Improvements that closes it as done with
    /// the release's note. The person approves the card; nothing is closed without them. A to-do that ever had such a
    /// card, waiting or settled, gets no second one, so a card the person rejected does not come back. Never makes the
    /// Improvements binder. Answers `{cards}`, the number written.
    func closeBuiltSuggestions(now: Date, built: [BuiltSuggestions.Built] = BuiltSuggestions.all) throws -> JSONObject {
        func answer(_ cards: Int) -> JSONObject { JSONObject([(key: "cards", value: .int(cards))]) }
        guard !built.isEmpty, let improvements = try? BuiltInBinder(.improvements, support: support).folder(),
              let catalog = Teka.read(improvements).catalog else { return answer(0) }
        let notes = Dictionary(built.map { ($0.code, $0.note) }, uniquingKeysWith: { first, _ in first })
        let open = (catalog["open_items"]?.arrayValue ?? []).compactMap { item -> (id: JSONValue, title: String, code: String, note: String)? in
            guard let card = item["suggestion_card"]?.stringValue, let id = item["id"], let note = notes[SuggestionExport.code(card: card)] else { return nil }
            return (id, item["title"]?.stringValue ?? "", SuggestionExport.code(card: card), note)
        }
        guard !open.isEmpty else { return answer(0) }
        // Cards that cannot be listed safely: none is added to them.
        guard let listed = try? ProposalStore.boundedList(in: improvements, maxEntries: ProposalStore.maximumEntries) else { return answer(0) }
        let had = Set(listed.compactMap { $0.0.raw["provenance"]?["built_suggestion"]?.stringValue })
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(client)), (key: "model", value: .str("none"))])
        var written = 0
        for item in open where !had.contains(item.code) {
            let close = JSONObject([(key: "op", value: .str("complete")), (key: "args", value: .obj([("id", item.id), ("note", .string(item.note))]))])
            let card = Proposal.make(title: BuiltSuggestions.cardTitle(item.title), actor: actor, ops: [close],
                                     provenance: JSONObject([(key: "built_suggestion", value: .string(item.code)), (key: "note", value: .string(item.note))]), now: now)
            try ProposalStore.save(card, in: improvements)
            try trustProposals([card.id], in: improvements)
            written += 1
        }
        return answer(written)
    }
}

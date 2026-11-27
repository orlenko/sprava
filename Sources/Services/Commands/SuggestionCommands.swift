import BinderFormat
import BinderStore
import CryptoKit
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
    /// the card's id, so an approval tried again after the to-do was written adds no second one; when the person
    /// changed the text before trying again, the to-do is given the text they approved last. Answers
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
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        let store = TekaStore(folder: improvements, client: client)
        if let sent = Teka.read(improvements).catalog?["open_items"]?.arrayValue?.first(where: { $0["suggestion_card"] == .string(id) }) {
            // An earlier try wrote the to-do and stopped before the card was marked. What the person approves now is
            // what the to-do holds: an edit made since then is written, never dropped.
            if sent["details"] != .string(text), let item = sent["id"] {
                _ = try store.apply([.init(op: "update_item", args: .init([(key: "id", value: item), (key: "set", value: .obj([("details", .string(text))]))]), actor: actor)], now: now)
            }
        } else {
            let item = JSONValue.obj([("id", .str("$new:1")), ("title", .string(card.title)), ("status", .str("open")), ("priority", .str("normal")),
                                      ("no_deadline", .bool(true)), ("details", .string(text)), ("suggestion_card", .string(id))])
            _ = try store.applyMinting([.init(op: "add_item", args: .init([(key: "item", value: item)]), actor: actor)], now: now)
        }
        _ = try TekaStore(folder: f, client: client).approve(proposal, edited: nil, now: now)
        try recordDigests([id], in: f)
        return JSONObject([(key: "improvements", value: .string(improvements.path))])
    }
}

/// The approved suggestions as one Markdown file for the development loop (decisions.md D47): each one's title as a
/// heading and its text, exactly as the person approved it, inside a fenced block. The fence is longer than any run of
/// backticks in the text, so the text is never cut short or rendered as anything but itself. The text is every byte
/// between the line that opens the block and the one line break before the line that closes it: that line break is
/// always added, so a text that ends in a line break and the same text without it export differently, and each comes
/// back exactly. Above the block is the suggestion's code, which the issue made from it keeps: a release that builds
/// the suggestion names that code (`BuiltSuggestions`), and this Mac then offers to close the to-do.
enum SuggestionExport {
    /// A short name for one suggestion, from the id of the card that made it: the same at every export, and nothing
    /// of its text.
    static func code(card: String) -> String {
        "S-" + SHA256.hash(data: Data(card.utf8)).map { String(format: "%02x", $0) }.joined().prefix(10)
    }

    static func markdown(_ suggestions: [(title: String, text: String, code: String)], on day: CalendarDate) -> String {
        var out = "# Suggestions for Sprava\n\nExported \(day). \(suggestions.count == 1 ? "1 suggestion" : "\(suggestions.count) suggestions").\n"
        for suggestion in suggestions {
            var longest = 0, run = 0
            for character in suggestion.text { run = character == "`" ? run + 1 : 0; longest = max(longest, run) }
            let fence = String(repeating: "`", count: max(3, longest + 1))
            let title = suggestion.title.split(whereSeparator: \.isNewline).joined(separator: " ")
            out += "\n## \(title)\n\nCode: `\(suggestion.code)`\n\n\(fence)text\n\(suggestion.text)\n\(fence)\n"
        }
        return out
    }
}

extension Commands {
    /// `export_suggestions`: `{path}`. Writes the suggestions that are open to-dos in the Improvements binder to the
    /// Markdown file at `path`, which the person picked in a save panel: an absolute path ending in `.md`, in a folder
    /// that exists. Only to-dos a suggestion card made are written, never the binder's other to-dos, and nothing in the
    /// binder changes. Answers `{count, path}`.
    func exportSuggestions(_ r: JSONObject, today: CalendarDate) throws -> JSONObject {
        guard let path = r["path"]?.stringValue, path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4_096 else {
            throw Failure(message: "Export needs the file to write, as a full path.")
        }
        let file = URL(fileURLWithPath: path).standardizedFileURL
        guard file.pathExtension.lowercased() == "md" else { throw Failure(message: "Export writes a Markdown file; give it a name ending in .md.") }
        // The folder as it physically is, every link on the way followed, so the checks below and the write name the
        // same place.
        func physical(_ folder: URL) -> String? {
            guard let resolved = realpath(folder.path, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var info = stat()
        guard let parent = physical(file.deletingLastPathComponent()), stat(parent, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw Failure(message: "The folder to export into does not exist.")
        }
        let target = URL(fileURLWithPath: parent, isDirectory: true).appendingPathComponent(file.lastPathComponent)
        // Never over something that is not an ordinary file, and never through a link.
        if lstat(target.path, &info) == 0, info.st_mode & S_IFMT != S_IFREG {
            throw Failure(message: "There is something at that name that is not an ordinary file. Choose another name; nothing was written.")
        }
        let improvements: URL?
        do { improvements = try BuiltInBinder(.improvements, support: support).folder() }
        catch { throw Failure(message: "\(error) Nothing was exported.") }
        guard let improvements else { throw Failure(message: "There are no suggestions yet: none has been sent to Improvements.") }
        // Sprava never writes a suggestion file into a binder, on the Shelf or not, where it would arrive as a document,
        // nor into its own state: no folder above the file holds a catalog.json or is the support folder.
        let own = physical(support)
        var above = URL(fileURLWithPath: parent, isDirectory: true)
        while above.path != "/" {
            if above.path == own || lstat(above.appendingPathComponent("catalog.json").path, &info) == 0 {
                throw Failure(message: "Choose a folder outside your binders and Sprava's own folder; nothing was written.")
            }
            above = above.deletingLastPathComponent()
        }
        let teka = Teka.read(improvements)
        guard let catalog = teka.catalog else { throw Failure(message: "The Improvements binder cannot be read. Nothing was exported.") }
        let suggestions = (catalog["open_items"]?.arrayValue ?? []).compactMap { item -> (title: String, text: String, code: String)? in
            guard let card = item["suggestion_card"]?.stringValue, item["status"] != .str("done"), item["status"] != .str("dropped"),
                  let title = item["title"]?.stringValue, let text = item["details"]?.stringValue else { return nil }
            return (title, text, SuggestionExport.code(card: card))
        }
        guard !suggestions.isEmpty else { throw Failure(message: "There are no open suggestions in Improvements to export.") }
        // For the person alone: the text can hold a script, and the folder picked may be a shared one. The file is
        // written new and moved into place, so one it replaces never keeps a wider mode either.
        try AtomicFile.write(Data(SuggestionExport.markdown(suggestions, on: today).utf8), to: target, mode: 0o600)
        return JSONObject([(key: "count", value: .int(suggestions.count)), (key: "path", value: .string(target.path))])
    }
}

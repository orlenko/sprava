import AppKit
import Combine
import BinderFormat
import BinderStore
import SpravaKit

/// One binder's review cards and actions, all through the runtime (mvp.md feature 3).
@MainActor
final class BinderActions: ObservableObject {
    struct Card: Identifiable {
        let id: String
        let title: String
        let actor: String
        let lines: [String]
        let digest: String
        let verified: Bool
        /// For a filing card: the intake file's details and the suggested folder, which the person may change.
        let intake: String?
        let folder: String?
        let notes: [String]
        let editable: [Editable]
        /// A filing card whose source could not tell how the document reached the person (adaptation-layer §3.3).
        var asksChannel = false
    }

    /// One add_item, or one item an adoption repair card completes, the person may change before approving.
    struct Editable: Identifiable, Equatable {
        let index: Int
        var title: String
        var due: String
        var priority: String
        /// Who the item waits on, when the card offers it (a repair card, binder-v0 §9.4); nil otherwise.
        var waitingOn: String?
        var include = true
        var id: Int { index }
    }

    @Published var cards: [Card] = []
    @Published var editing: [String: [Editable]] = [:]
    @Published var folders: [String: String] = [:]
    @Published var channels: [String: String] = [:]
    @Published var said: [String: String] = [:]
    @Published var history: [Change] = []

    struct Change: Identifiable {
        let id: String
        let line: String
        let who: String
        let at: Date?
        let undoable: Bool
        let undone: Bool
    }
    @Published var message: String?
    @Published var busy = false
    @Published var description = ""
    @Published var filing = false
    /// Whether `description` and `filing` hold this binder's saved settings. Until they do, nothing writes them:
    /// the fields would otherwise save another binder's line, or empty ones, over this binder's.
    @Published var settingsLoaded = false
    @Published var showPreview = false
    @Published var copied = false
    /// The binder this model serves. The page keeps one model while the person moves between binders, so a reply
    /// for another binder is dropped, and everything shown is cleared when the binder changes.
    private(set) var folder: URL?
    let client: RuntimeClient

    init(client: RuntimeClient = RuntimeClient()) {
        self.client = client
    }

    /// Whether `folder` is still the binder shown.
    func serves(_ folder: URL) -> Bool { self.folder == folder.standardizedFileURL }

    func load(_ folder: URL, adopted: Bool) async {
        let folder = folder.standardizedFileURL
        if self.folder != folder {
            self.folder = folder
            cards = []; history = []; editing = [:]; folders = [:]; channels = [:]; said = [:]
            description = ""; filing = false; settingsLoaded = false; message = nil; showPreview = false; copied = false
        }
        guard adopted else { cards = []; history = []; return }
        do {
            let s = try await client.command("binder_settings", binder: folder, timeout: 5)
            guard serves(folder) else { return }
            description = s["description"]?.stringValue ?? ""
            filing = s["filing"] == .bool(true)
            settingsLoaded = true
        } catch {
            guard serves(folder) else { return }
            message = "This binder's settings could not be read: \(error)"
        }
        await loadReview(folder)
    }

    /// The cards and the history only: the page's timer calls this, so it never overwrites the description being
    /// typed. Edits in progress are kept, since they live apart from the cards, by card id.
    func loadReview(_ folder: URL) async {
        guard serves(folder) else { return }
        do {
            let reply = try await client.command("proposals", binder: folder, timeout: 5)
            guard serves(folder) else { return }
            cards = (reply["proposals"]?.arrayValue ?? []).compactMap { p in
                guard p["state"] == .str("proposed"), let id = p["id"]?.stringValue else { return nil }
                var card = Card(id: id, title: p["title"]?.stringValue ?? "", actor: p["actor"]?["kind"]?.stringValue ?? "?",
                            lines: p["lines"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            digest: p["digest"]?.stringValue ?? "", verified: p["verified"] == .bool(true),
                            intake: p["intake"].map(Self.intakeLine), folder: p["document_folder"]?.stringValue,
                            notes: p["notes"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            editable: (p["editable"]?.arrayValue ?? []).compactMap { e in
                                guard let i = e["index"]?.numberValue?.safeInteger else { return nil }
                                return Editable(index: Int(i), title: e["title"]?.stringValue ?? "", due: e["due"]?.stringValue ?? "",
                                                priority: e["priority"]?.stringValue ?? "normal", waitingOn: e["waiting_on"]?.stringValue)
                            })
                card.asksChannel = p["intake"]?["obtained"]?["channel"] == .str("other")
                return card
            }
            let past = try await client.command("history", binder: folder, timeout: 5)
            guard serves(folder) else { return }
            history = (past["ops"]?.arrayValue ?? []).compactMap { o in
                guard let id = o["id"]?.stringValue else { return nil }
                let who: String
                switch (o["actor"]?.stringValue, o["origin"]?.stringValue) {
                case ("external", "spool-outbox"): who = "checked off on the hub"
                case ("external", _): who = "edited outside Sprava"
                case ("user", _): who = "you"
                case (let kind?, _): who = kind
                default: who = "?"
                }
                return Change(id: id, line: o["line"]?.stringValue ?? "", who: who, at: ISOTime.date(o["at"]?.stringValue),
                              undoable: o["undoable"] == .bool(true), undone: o["undone"] == .bool(true))
            }
        } catch {
            guard serves(folder) else { return }
            message = "\(error)"
        }
    }

    static func intakeLine(_ v: JSONValue) -> String {
        let bytes = v["bytes"]?.numberValue?.safeInteger.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
        return [v["name"]?.stringValue, v["modified"]?.stringValue, bytes, v["sha256"]?.stringValue.map { "sha256 " + $0.prefix(16) + "…" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The binder's line for the clerk and whether it is on the filing list (mvp.md feature 1).
    func saveSettings(_ folder: URL) {
        guard settingsLoaded, serves(folder) else { return }
        run("binder_settings", folder, [("description", .string(description)), ("filing", .bool(filing))], then: {})
    }

    func undo(_ change: Change, _ folder: URL, reload: @escaping () -> Void) {
        run("undo", folder, [("op_id", .string(change.id))], then: reload)
    }

    @discardableResult
    func run(_ name: String, _ folder: URL, _ fields: [(String, JSONValue)], then reload: @escaping () -> Void,
             onSuccess: @escaping () -> Void = {}) -> Task<Void, Never> {
        busy = true
        return Task {
            defer { busy = false }
            await send(name, folder, fields, onSuccess: onSuccess)
            if serves(folder) { reload() }
        }
    }

    /// One change through the runtime; its outcome is shown only while its binder is the one shown.
    func send(_ name: String, _ folder: URL, _ fields: [(String, JSONValue)], onSuccess: () -> Void = {}) async {
        do {
            _ = try await client.command(name, binder: folder, fields)
            guard serves(folder) else { return }
            message = nil
            onSuccess()
        } catch {
            guard serves(folder) else { return }
            message = "\(error)"
        }
    }

    func adopt(_ folder: URL, inRegistry: Bool, reload: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Adopt this binder?"
        alert.informativeText = """
        Sprava adds a hidden .sprava folder and a .teka.lock file, saves a copy of catalog.json as found, \
        and fills in follow-up dates for items waiting on someone (each marked as filled in). Everything else \
        arrives as cards for you to approve. Nothing else in the folder changes.
        """
        alert.addButton(withTitle: "Adopt")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        run("adopt", folder, [("in_registry", .bool(inRegistry))], then: reload)
    }

    @discardableResult
    func approve(_ card: Card, _ folder: URL, reload: @escaping () -> Void) -> Task<Void, Never> {
        run("approve", folder, approval(card), then: reload, onSuccess: { [weak self] in self?.forget(card) })
    }

    /// The approve request with the person's edits, chosen folder and provenance answer. They stay until the
    /// runtime accepts the approval, so a refused date or an unreachable runtime loses none of them.
    func approval(_ card: Card) -> [(String, JSONValue)] {
        var fields: [(String, JSONValue)] = [("proposal", .string(card.id)), ("digest", .string(card.digest))]
        if let edits = editing[card.id] {
            let changed: [JSONValue] = edits.compactMap { e in
                guard let original = card.editable.first(where: { $0.index == e.index }) else { return nil }
                if !e.include { return .obj([("index", .int(e.index)), ("skip", .bool(true))]) }
                var o: [(String, JSONValue)] = [("index", .int(e.index))]
                if e.title != original.title { o.append(("title", .string(e.title))) }
                if e.due != original.due { o.append(("due", .string(e.due))) }
                if e.priority != original.priority { o.append(("priority", .string(e.priority))) }
                if let party = e.waitingOn, party != original.waitingOn { o.append(("waiting_on", .string(party))) }
                return o.count > 1 ? .obj(o) : nil
            }
            if !changed.isEmpty { fields.append(("edits", .array(changed))) }
        }
        if let chosen = folders[card.id], chosen != card.folder { fields.append(("document_folder", .string(chosen))) }
        if let channel = channels[card.id] {
            fields.append(("obtained", .obj([("channel", .string(channel)), ("said", .string(said[card.id] ?? ""))])))
        }
        return fields
    }

    /// Drops what the person set on a card, once its approval is accepted.
    func forget(_ card: Card) {
        editing[card.id] = nil
        folders[card.id] = nil
        channels[card.id] = nil
        said[card.id] = nil
    }

    func reject(_ card: Card, _ folder: URL, reload: @escaping () -> Void) {
        run("reject", folder, [("proposal", .string(card.id)), ("digest", .string(card.digest))], then: reload)
    }

    func close(_ item: Item, as op: String, _ folder: URL, reload: @escaping () -> Void) {
        guard let id = item.object?["id"] else { return }
        let at = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!)
        run("apply", folder, [("op", .string(op)),
                              ("args", .obj([("id", id), ("closed_at", .string(at)), ("source", .str("user"))]))], then: reload)
    }
}

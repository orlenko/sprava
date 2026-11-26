import AppKit
import Combine
import BinderFormat
import BinderStore
import SpravaKit

/// One binder's review cards and actions, all through the runtime (mvp.md feature 3).
@MainActor
final class BinderActions: ObservableObject, RuntimePage, DraftOwner {
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
        /// What the card shows first; see `CardReview`.
        var review = CardReview()
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
    /// What the person set on each card, by card id. Changed only through the methods below, which refuse a card
    /// while its approval or rejection is pending or once it is settled.
    @Published private(set) var editing: [String: [Editable]] = [:]
    @Published private(set) var folders: [String: String] = [:]
    @Published private(set) var channels: [String: String] = [:]
    @Published private(set) var said: [String: String] = [:]
    /// The person's edit of a proposed rule, by card id, while they are changing it (decisions.md D46).
    @Published private(set) var rules: [String: String] = [:]
    /// The cards whose approval or rejection the runtime is carrying out. The request already holds the card's
    /// edits, so the card stays locked until the runtime answers: an edit made meanwhile would be dropped with
    /// the ones sent once the approval is accepted.
    @Published private(set) var pending: Set<String> = []
    /// The cards whose approval or rejection the runtime accepted, until a reload no longer lists them. Their edits
    /// are dropped, so a card left on the page until then stays locked: words typed into it would vanish with it.
    @Published private(set) var settled: Set<String> = []
    @Published var history: [Change] = []
    /// Whether `history` is this binder's as last read, so an empty list is told apart from one not read yet or not readable.
    enum HistoryRead { case reading, read, failed }
    @Published private(set) var historyRead = HistoryRead.reading

    struct Change: Identifiable {
        let id: String
        let line: String
        let who: String
        let at: Date?
        let undoable: Bool
        let undone: Bool
    }
    @Published var message: String? { didSet { readFoundNoRuntime = false } }
    /// What the last approval did, said where the card was until the next change, another binder or a few seconds.
    @Published private(set) var confirmation: String?
    /// The last Done on a repeating to-do: where it moved ("Done: … Next: December 15."), and the op its Undo takes back.
    /// The next change, or another binder, ends it.
    struct Moved: Equatable {
        let line: String
        let opID: String
    }
    @Published private(set) var moved: Moved?
    /// Why the item editor offers no new repeat in this binder (binder_settings `repeats_off`); nil when it may.
    @Published private(set) var repeatsOff: String?
    private var confirmationEnds: Task<Void, Never>?
    var confirmationLifetime: Duration = .seconds(8)
    /// The cards whose Details are open.
    @Published private(set) var openDetails: Set<String> = []
    /// Files in intake left out of review because a copy, or the same email, is already filed (`intake/...` paths).
    @Published private(set) var intakeCopies: [String] = []
    var readFoundNoRuntime = false
    @Published var busy = false
    @Published var description = ""
    @Published var filing = false
    /// Whether `description` and `filing` hold this binder's saved settings. Until they do, nothing writes them:
    /// the fields would otherwise save another binder's line, or empty ones, over this binder's.
    @Published var settingsLoaded = false
    @Published var showPreview = false
    @Published var copied = false
    /// The description as last read from or saved through the runtime. `description` differs from it only while
    /// the person has typed a line not yet saved, which a reload after an unrelated action keeps.
    private var savedDescription = ""
    /// A description draft brought back to this binder, shown once its saved settings are read.
    private var descriptionDraft: String?
    /// The binder this model serves. The page keeps one model while the person moves between binders, so a reply
    /// for another binder is dropped, and everything shown is cleared when the binder changes. What the person
    /// typed or changed and has not saved or approved is set aside for that binder, and comes back with it.
    private(set) var folder: URL?

    /// What the person typed or changed in one binder and has not yet saved or approved.
    struct Draft {
        var description: String?
        var editing: [String: [Editable]] = [:]
        var folders: [String: String] = [:]
        var channels: [String: String] = [:]
        var said: [String: String] = [:]
        var rules: [String: String] = [:]
        var originalItems: [String: [Editable]] = [:]
        var originalFolders: [String: String] = [:]
        /// Each rule card's rule as proposed, so an edit opened and left as it was is not unsaved work.
        var originalRules: [String: String] = [:]
        var isEmpty: Bool { description == nil && editing.isEmpty && folders.isEmpty && channels.isEmpty && said.isEmpty && rules.isEmpty }
        var hasChanges: Bool {
            description != nil || editing.contains { $0.value != originalItems[$0.key] }
                || folders.contains { $0.value != originalFolders[$0.key] } || !channels.isEmpty || !said.isEmpty
                || rules.contains { $0.value != originalRules[$0.key] }
        }
    }
    /// The drafts of the binders left behind, by folder, so returning to one brings its drafts back.
    private var drafts: [URL: Draft] = [:]
    var draftState: DraftState {
        DraftState(hasChanges: draft.hasChanges || drafts.values.contains { $0.hasChanges }, saving: busy || !pending.isEmpty)
    }
    let client: RuntimeClient

    /// Whether Sprava keeps DASHBOARD.md, and whether the manual carries the addendum (nil: no manual).
    struct Keeping: Sendable, Equatable {
        var switched: Bool
        var addendum: Bool?

        static func read(_ folder: URL) -> Keeping {
            Keeping(switched: DashboardKeeper(folder: folder).isSwitched, addendum: ManualAddendum.isPresent(in: folder))
        }
    }
    /// Read off the main actor with a bound, like the Shelf: a binder on a stalled volume or a manual still being
    /// downloaded leaves the page responsive and says so. Nil until read.
    @Published private(set) var keeping: Keeping?
    @Published private(set) var keepingNote: String?
    /// The dashboard as Sprava would write it today, once rendered for the preview sheet.
    @Published private(set) var preview: String?
    private let disk: ShelfDiskWorker
    private let readTimeout: TimeInterval
    private let readKeeping: @Sendable (URL) -> Keeping
    private let renderPreview: @Sendable (URL, CalendarDate) -> String?
    private let reveal: @MainActor (URL) -> Void

    init(client: RuntimeClient = RuntimeClient(), readTimeout: TimeInterval = 5,
         readKeeping: @escaping @Sendable (URL) -> Keeping = Keeping.read,
         renderPreview: @escaping @Sendable (URL, CalendarDate) -> String? = { DashboardKeeper(folder: $0).preview(today: $1) },
         deadline: @escaping DiskDeadline = ShelfDiskWorker.wallClock,
         reveal: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }) {
        disk = ShelfDiskWorker(queue: DispatchQueue(label: "sprava.binder.reads", qos: .utility), deadline: deadline)
        self.reveal = reveal
        self.client = client
        self.readTimeout = readTimeout
        self.readKeeping = readKeeping
        self.renderPreview = renderPreview
        client.clearsNotRunning(self)
    }

    /// Whether `folder` is still the binder shown.
    func serves(_ folder: URL) -> Bool { self.folder == folder.standardizedFileURL }

    func load(_ folder: URL, adopted: Bool) async {
        let folder = folder.standardizedFileURL
        if self.folder != folder {
            if let left = self.folder { drafts[left] = draft.isEmpty ? nil : draft }
            self.folder = folder
            let kept = drafts.removeValue(forKey: folder) ?? Draft()
            cards = []; history = []; historyRead = .reading; intakeCopies = []; editing = kept.editing; folders = kept.folders; channels = kept.channels; said = kept.said
            rules = kept.rules
            description = ""; savedDescription = ""; descriptionDraft = kept.description
            filing = false; settingsLoaded = false; message = nil; showPreview = false; copied = false; moved = nil; repeatsOff = nil
            confirm(nil)
            keeping = nil; keepingNote = nil; preview = nil
        }
        guard adopted else { cards = []; history = []; historyRead = .read; intakeCopies = []; return }
        await loadKeeping(folder)
        do {
            let s = try await client.command("binder_settings", binder: folder, timeout: 5)
            guard serves(folder) else { return }
            let saved = s["description"]?.stringValue ?? ""
            if !settingsLoaded {
                description = descriptionDraft ?? saved
                descriptionDraft = nil
            } else if description == savedDescription {
                description = saved
            }
            savedDescription = saved
            filing = s["filing"] == .bool(true)
            repeatsOff = s["repeats_off"]?.stringValue
            settingsLoaded = true
        } catch {
            guard serves(folder) else { return }
            readFailed("This binder's settings could not be read: \(error)", error)
        }
        await loadReview(folder)
    }

    func loadKeeping(_ folder: URL) async {
        guard serves(folder) else { return }
        let read = readKeeping
        let value = await disk.run(timeout: readTimeout) { read(folder) }
        guard serves(folder) else { return }
        if let value {
            keeping = value
            keepingNote = nil
        } else {
            keepingNote = "This binder's dashboard and manual are taking too long to read; they show once the files can be read."
        }
    }

    /// Opens the preview sheet at once and fills it when the rendering, bounded like every read here, arrives.
    func showDashboardPreview(_ folder: URL, today: CalendarDate) async {
        guard serves(folder) else { return }
        preview = nil
        showPreview = true
        let render = renderPreview
        let value = await disk.run(timeout: readTimeout) { render(folder, today) }
        guard serves(folder), showPreview else { return }
        switch value {
        case let text??: preview = text
        case .some(nil): preview = "unreadable"
        case nil: preview = "The binder's files are taking too long to read; try again once they can be read."
        }
    }

    /// What the person has set in the binder shown and not yet saved or approved.
    private var draft: Draft {
        let typed = settingsLoaded ? (description == savedDescription ? nil : description) : descriptionDraft
        return Draft(description: typed, editing: editing, folders: folders, channels: channels, said: said, rules: rules,
                     originalItems: Dictionary(cards.map { ($0.id, $0.editable) }, uniquingKeysWith: { first, _ in first }),
                     originalFolders: Dictionary(cards.compactMap { card in card.folder.map { (card.id, $0) } }, uniquingKeysWith: { first, _ in first }),
                     originalRules: Dictionary(cards.compactMap { card in card.review.rule.map { (card.id, $0.text) } }, uniquingKeysWith: { first, _ in first }))
    }

    /// The cards and the history only: the page's timer calls this, so it never overwrites the description being
    /// typed. Edits in progress are kept, since they live apart from the cards, by card id.
    func loadReview(_ folder: URL) async {
        guard serves(folder) else { return }
        do {
            let reply = try await client.command("proposals", binder: folder, timeout: 5)
            guard serves(folder) else { return }
            let before = cards
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
                card.review = CardReview(p["review"])
                return card
            }
            intakeCopies = (reply["intake_copies"]?.arrayValue ?? []).compactMap(\.stringValue)
            noticeDraftsLost(from: before)
            // A reply sent before the runtime settled a card still lists it, and the card stays locked.
            settled.formIntersection(cards.map(\.id))
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
            historyRead = .read
        } catch {
            guard serves(folder) else { return }
            historyRead = .failed
            readFailed("\(error)", error)
        }
    }

    static func intakeLine(_ v: JSONValue) -> String {
        let bytes = v["bytes"]?.numberValue?.safeInteger.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "?"
        return [v["name"]?.stringValue, v["modified"]?.stringValue, bytes, v["sha256"]?.stringValue.map { "sha256 " + $0.prefix(16) + "…" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// The binder's line for the clerk and whether it is on the filing list (mvp.md feature 1).
    @discardableResult
    func saveSettings(_ folder: URL) -> Task<Void, Never>? {
        guard settingsLoaded, serves(folder) else { return nil }
        let line = description
        return run("binder_settings", folder, [("description", .string(line)), ("filing", .bool(filing))], then: {},
                   onSuccess: { [weak self] in self?.savedDescription = line })
    }

    /// Undoes a change. Fields the person changed again since keep their newer values, and the page says which.
    @discardableResult
    func undo(_ change: Change, _ folder: URL, reload: @escaping () -> Void) -> Task<Void, Never> {
        busy = true
        confirm(nil)
        moved = nil
        return Task {
            defer { busy = false }
            do {
                let reply = try await client.command("undo", binder: folder, [("op_id", .string(change.id))])
                if serves(folder) { message = Self.keptNote(reply["kept"]?.arrayValue?.compactMap(\.stringValue) ?? []) }
            } catch {
                if serves(folder) { message = "\(error)" }
            }
            if serves(folder) { reload() }
        }
    }

    /// "Undone. Your later change to the due date was kept." for fields an undo left alone; nil when there were none.
    static func keptNote(_ fields: [String]) -> String? {
        guard !fields.isEmpty else { return nil }
        let names: [String: String] = ["due": "due date", "follow_up_at": "follow-up date", "expected_by": "expected date",
                                       "waiting_on": "who it waits on", "no_deadline": "deadline", "dismissed": "hidden state",
                                       "redact": "privacy marker", "slice_title": "hub title"]
        let words = fields.map { names[$0] ?? $0.replacingOccurrences(of: "_", with: " ") }
        let list = words.count == 1 ? words[0] : words.dropLast().joined(separator: ", ") + " and " + words.last!
        return "Undone. Your later change to the \(list) was kept."
    }

    @discardableResult
    func run(_ name: String, _ folder: URL, _ fields: [(String, JSONValue)], then reload: @escaping () -> Void,
             onSuccess: @escaping () -> Void = {}, onAccepted: @escaping () -> Void = {},
             onReply: @escaping (JSONObject) -> Void = { _ in }, onEnd: @escaping () -> Void = {}) -> Task<Void, Never> {
        busy = true
        return Task {
            defer { busy = false; onEnd() }
            await send(name, folder, fields, onSuccess: onSuccess, onAccepted: onAccepted, onReply: onReply)
            if serves(folder) { reload() }
        }
    }

    /// One change through the runtime; its outcome is shown only while its binder is the one shown. `onAccepted`
    /// runs whenever the runtime accepts it, shown or not, for state kept per binder that must follow the binder.
    func send(_ name: String, _ folder: URL, _ fields: [(String, JSONValue)], onSuccess: () -> Void = {},
              onAccepted: () -> Void = {}, onReply: (JSONObject) -> Void = { _ in }) async {
        // The next change ends the last approval's confirmation, and the line of a repeating to-do's last Done: each says
        // only what that one change did.
        if serves(folder) { confirm(nil); moved = nil }
        do {
            let reply = try await client.command(name, binder: folder, fields)
            onAccepted()
            guard serves(folder) else { return }
            message = nil
            onSuccess()
            onReply(reply)
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

    /// Approves a card with what the person set on it; nil when the card already has a request pending.
    @discardableResult
    func approve(_ card: Card, _ folder: URL, reload: @escaping () -> Void) -> Task<Void, Never>? {
        // A proposed rule has its own command, which writes the rule into the binder's instructions (decisions.md D46).
        if card.verified, card.review.kind == .rule {
            return settle(card, "accept_rule", folder, ruleAcceptance(card), reload: reload, onSuccess: { [weak self] in self?.forget(card) },
                          onReply: { [weak self] _ in self?.confirm("Added the rule to this binder\u{2019}s Instructions.") })
        }
        return settle(card, "approve", folder, approval(card), reload: reload, onSuccess: { [weak self] in self?.forget(card) },
               onReply: { [weak self] in self?.confirm(CardReview.approvedLine($0)) })
    }

    /// Shows what an approval did, or ends what is shown; it goes by itself after `confirmationLifetime`.
    func confirm(_ text: String?) {
        confirmationEnds?.cancel()
        confirmation = text
        guard text != nil else { return }
        let lifetime = confirmationLifetime
        confirmationEnds = Task { [weak self] in
            try? await Task.sleep(for: lifetime)
            guard !Task.isCancelled else { return }
            self?.confirmation = nil
        }
    }

    /// Sends a card's approval or rejection, with the card locked until the runtime answers, and, once the runtime
    /// accepts it, until a reload no longer lists the card.
    private func settle(_ card: Card, _ name: String, _ folder: URL, _ fields: [(String, JSONValue)],
                        reload: @escaping () -> Void, onSuccess: @escaping () -> Void = {},
                        onReply: @escaping (JSONObject) -> Void = { _ in }) -> Task<Void, Never>? {
        guard isChangeable(card.id) else { return nil }
        pending.insert(card.id)
        return run(name, folder, fields, then: reload,
                   onSuccess: { [weak self] in onSuccess(); self?.settled.insert(card.id) }, onReply: onReply,
                   onEnd: { [weak self] in self?.pending.remove(card.id) })
    }

    /// Whether the person may change what is set on a card: not while its approval or rejection is pending, nor
    /// once it is settled and the card has yet to leave the page.
    func isChangeable(_ card: String) -> Bool { !pending.contains(card) && !settled.contains(card) }

    /// Opens a card's items for editing; false when the card is locked or already open.
    @discardableResult
    func startEditing(_ card: Card) -> Bool {
        if card.verified, card.review.kind == .rule, let rule = card.review.rule {
            guard isChangeable(card.id), rules[card.id] == nil else { return false }
            rules[card.id] = rule.text
            return true
        }
        guard isChangeable(card.id), editing[card.id] == nil else { return false }
        editing[card.id] = card.editable
        return true
    }

    /// Sets the person's edit of a proposed rule; false when the card is locked or not being edited.
    @discardableResult
    func setRule(_ card: String, _ value: String) -> Bool {
        guard isChangeable(card), rules[card] != nil else { return false }
        rules[card] = value
        return true
    }

    /// The accept request for a rule card: the person's edit when they made one, as one line without space around it.
    /// It stays until the runtime accepts it, so a refused edit is still there to fix.
    func ruleAcceptance(_ card: Card) -> [(String, JSONValue)] {
        var fields: [(String, JSONValue)] = [("proposal", .string(card.id)), ("digest", .string(card.digest))]
        if let edit = rules[card.id]?.trimmingCharacters(in: .whitespacesAndNewlines), edit != card.review.rule?.text {
            fields.append(("rule", .string(edit)))
        }
        return fields
    }

    /// Changes one item of a card being edited; false when the card is locked, or its edits were dropped.
    @discardableResult
    func setItem<T>(_ card: String, _ index: Int, _ path: WritableKeyPath<Editable, T>, _ value: T) -> Bool {
        guard isChangeable(card), let i = editing[card]?.firstIndex(where: { $0.index == index }) else { return false }
        editing[card]?[i][keyPath: path] = value
        return true
    }

    /// Sets the folder a filing card files into; false when the card is locked.
    @discardableResult
    func setFolder(_ card: String, _ value: String) -> Bool {
        guard isChangeable(card) else { return false }
        folders[card] = value
        return true
    }

    /// Sets how the document reached the person; false when the card is locked.
    @discardableResult
    func setChannel(_ card: String, _ value: String) -> Bool {
        guard isChangeable(card) else { return false }
        channels[card] = value
        return true
    }

    /// Sets the person's own words on how the document reached them; false when the card is locked.
    @discardableResult
    func setSaid(_ card: String, _ value: String) -> Bool {
        guard isChangeable(card) else { return false }
        said[card] = value
        return true
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
        // Either field alone is an answer: words typed under an untouched picker go with "other", the picker's default.
        if channels[card.id] != nil || said[card.id] != nil {
            fields.append(("obtained", .obj([("channel", .string(channels[card.id] ?? "other")),
                                             ("said", .string(said[card.id] ?? ""))])))
        }
        return fields
    }

    func setDetails(_ card: String, open: Bool) {
        if open { openDetails.insert(card) } else { openDetails.remove(card) }
    }

    /// Shows a card's file in Finder, never running it. Its path comes from a card, so it is checked again here.
    func showInFinder(_ file: CardReview.File, _ folder: URL) async {
        let path = file.path
        let located = await disk.run(timeout: readTimeout) { CardReview.fileURL(path, in: folder) }
        guard serves(folder) else { return }
        guard let url = located ?? nil else {
            message = "This file is no longer in intake, or cannot be shown safely. Check the binder folder."
            return
        }
        reveal(url)
    }

    /// The runtime withdraws a card once its document is filed another way or its file changes. What the person typed
    /// on that card has nowhere left to go, so they are told; it is never dropped without a word.
    private func noticeDraftsLost(from before: [Card]) {
        // By the drafts themselves: coming back to a binder restores them with no card shown yet.
        let drafts = Set(editing.keys).union(folders.keys).union(channels.keys).union(said.keys).union(rules.keys)
        // A card the person decided is not one that went away by itself.
        let gone = drafts.filter { id in !cards.contains { $0.id == id } && isChangeable(id) }
        guard !gone.isEmpty else { return }
        for id in gone {
            editing[id] = nil; folders[id] = nil; channels[id] = nil; said[id] = nil; rules[id] = nil
        }
        let named = before.first { gone.contains($0.id) }.map { "The card for \u{201C}\($0.shown.heading ?? $0.title)\u{201D}" }
        message = (named ?? "A card you were changing") + " went away because its document is already filed or its file changed. What you typed on it was not used."
    }

    func showCopyInFinder(_ path: String, _ folder: URL) async {
        await showInFinder(CardReview.File(path: path, name: "", kind: "document"), folder)
    }

    /// Drops what the person set on a card, once its approval is accepted.
    func forget(_ card: Card) {
        editing[card.id] = nil
        folders[card.id] = nil
        channels[card.id] = nil
        said[card.id] = nil
        rules[card.id] = nil
    }

    @discardableResult
    func reject(_ card: Card, _ folder: URL, reload: @escaping () -> Void) -> Task<Void, Never>? {
        settle(card, "reject", folder, [("proposal", .string(card.id)), ("digest", .string(card.digest))], reload: reload,
               onSuccess: { [weak self] in self?.forget(card) })
    }

    /// Marks an item done (`complete`) or drops it (`drop`), as the person; nil for an item without an id. A Done on a
    /// repeating item names the date it completes, and the page then says where the item moved, with its Undo.
    @discardableResult
    func close(_ item: Item, as op: String, _ folder: URL, reload: @escaping () -> Void,
               onAccepted: @escaping () -> Void = {}, onEnd: @escaping () -> Void = {}) -> Task<Void, Never>? {
        if op == "complete", item.repeatUnreadable { message = RepeatWords.unreadableDone; return nil }
        let at = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!)
        guard let args = item.closeArgs(op, at: at) else { return nil }
        let title = item.title
        return run("apply", folder, [("op", .string(op)), ("args", args)], then: reload, onAccepted: onAccepted,
                   onReply: { [weak self] reply in
                       guard let next = reply["next_due"]?.stringValue.flatMap(CalendarDate.strict),
                             let op = reply["op"]?.stringValue else { return }
                       self?.moved = Moved(line: "Done: \(title). " + RepeatWords.next(next, today: .today()), opID: op)
                   },
                   onEnd: onEnd)
    }

    /// Takes back the Done that moved a repeating to-do on.
    func undoMoved(_ folder: URL, reload: @escaping () -> Void) {
        guard let moved, !busy else { return }
        self.moved = nil
        undo(Change(id: moved.opID, line: moved.line, who: "you", at: nil, undoable: true, undone: false), folder, reload: reload)
    }
}

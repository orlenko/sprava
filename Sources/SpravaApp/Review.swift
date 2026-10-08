import AppKit
import Combine
import SpravaCore
import SwiftUI

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

    /// One add_item the person may change before approving.
    struct Editable: Identifiable, Equatable {
        let index: Int
        var title: String
        var due: String
        var priority: String
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
    @Published var showPreview = false
    @Published var copied = false
    let client = RuntimeClient()

    func load(_ folder: URL, adopted: Bool) async {
        guard adopted else { cards = []; history = []; return }
        if let s = try? await client.command("binder_settings", binder: folder, timeout: 5) {
            description = s["description"]?.stringValue ?? ""
            filing = s["filing"] == .bool(true)
        }
        await loadReview(folder)
    }

    /// The cards and the history only: the page's timer calls this, so it never overwrites the description being
    /// typed. Edits in progress are kept, since they live apart from the cards, by card id.
    func loadReview(_ folder: URL) async {
        do {
            let reply = try await client.command("proposals", binder: folder, timeout: 5)
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
                                                priority: e["priority"]?.stringValue ?? "normal")
                            })
                card.asksChannel = p["intake"]?["obtained"]?["channel"] == .str("other")
                return card
            }
            let past = try await client.command("history", binder: folder, timeout: 5)
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
        run("binder_settings", folder, [("description", .string(description)), ("filing", .bool(filing))], then: {})
    }

    func undo(_ change: Change, _ folder: URL, reload: @escaping () -> Void) {
        run("undo", folder, [("op_id", .string(change.id))], then: reload)
    }

    func run(_ name: String, _ folder: URL, _ fields: [(String, JSONValue)], then reload: @escaping () -> Void) {
        busy = true
        Task {
            defer { busy = false }
            do {
                _ = try await client.command(name, binder: folder, fields)
                message = nil
            } catch {
                message = "\(error)"
            }
            reload()
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

    func approve(_ card: Card, _ folder: URL, reload: @escaping () -> Void) {
        var fields: [(String, JSONValue)] = [("proposal", .string(card.id)), ("digest", .string(card.digest))]
        if let edits = editing[card.id] {
            let changed: [JSONValue] = edits.compactMap { e in
                guard let original = card.editable.first(where: { $0.index == e.index }) else { return nil }
                if !e.include { return .obj([("index", .int(e.index)), ("skip", .bool(true))]) }
                var o: [(String, JSONValue)] = [("index", .int(e.index))]
                if e.title != original.title { o.append(("title", .string(e.title))) }
                if e.due != original.due { o.append(("due", .string(e.due))) }
                if e.priority != original.priority { o.append(("priority", .string(e.priority))) }
                return o.count > 1 ? .obj(o) : nil
            }
            if !changed.isEmpty { fields.append(("edits", .array(changed))) }
            editing[card.id] = nil
        }
        if let chosen = folders[card.id], chosen != card.folder { fields.append(("document_folder", .string(chosen))) }
        if let channel = channels[card.id] {
            fields.append(("obtained", .obj([("channel", .string(channel)), ("said", .string(said[card.id] ?? ""))])))
            channels[card.id] = nil
            said[card.id] = nil
        }
        run("approve", folder, fields, then: reload)
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

struct ReviewSection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let reload: () -> Void

    var body: some View {
        if !actions.cards.isEmpty {
            Section(header: Text("Waiting for your OK (\(actions.cards.count))").font(.headline)) {
                ForEach(actions.cards) { card in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(card.title).font(.body.bold())
                            Spacer()
                            Text("from \(card.actor)").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(card.lines, id: \.self) { Text("• \($0)").font(.callout) }
                        ForEach(card.notes, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                        if let intake = card.intake {
                            Text(intake).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        if let suggested = card.folder {
                            HStack {
                                Text("Folder").font(.caption)
                                TextField(suggested, text: Binding(get: { actions.folders[card.id] ?? suggested },
                                                                   set: { actions.folders[card.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 280)
                            }
                        }
                        if card.asksChannel {
                            HStack {
                                Picker("How did it reach you?", selection: Binding(get: { actions.channels[card.id] ?? "other" },
                                                                                  set: { actions.channels[card.id] = $0 })) {
                                    Text("not saying").tag("other")
                                    Text("by email").tag("email")
                                    Text("on paper, scanned").tag("paper")
                                    Text("downloaded").tag("download")
                                    Text("in a message").tag("message")
                                    Text("I wrote it").tag("note")
                                }
                                .frame(maxWidth: 320)
                                TextField("in your words (optional)", text: Binding(get: { actions.said[card.id] ?? "" },
                                                                                    set: { actions.said[card.id] = $0 }))
                                    .textFieldStyle(.roundedBorder)
                            }
                            .font(.caption)
                        }
                        if !card.verified {
                            Text("Not written by Sprava; it cannot be approved. Reject it to clear it away.").font(.caption).foregroundStyle(.orange)
                        }
                        if let edits = actions.editing[card.id] {
                            ForEach(edits) { e in
                                HStack {
                                    Toggle("", isOn: binding(card.id, e.index, \.include)).labelsHidden()
                                    TextField("Title", text: binding(card.id, e.index, \.title)).textFieldStyle(.roundedBorder)
                                    TextField("YYYY-MM-DD or empty", text: binding(card.id, e.index, \.due)).textFieldStyle(.roundedBorder).frame(width: 130)
                                    Picker("", selection: binding(card.id, e.index, \.priority)) {
                                        Text("high").tag("high"); Text("normal").tag("normal"); Text("low").tag("low")
                                    }
                                    .labelsHidden().frame(width: 90)
                                }
                            }
                        }
                        HStack {
                            Button("Approve") { actions.approve(card, folder, reload: reload) }
                                .disabled(!card.verified || actions.busy)
                            if !card.editable.isEmpty, actions.editing[card.id] == nil {
                                Button("Edit") { actions.editing[card.id] = card.editable }.disabled(!card.verified)
                            }
                            Button("Reject") { actions.reject(card, folder, reload: reload) }
                                .disabled(actions.busy)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

extension ReviewSection {
    /// A binding into one editable item of one card.
    func binding<T>(_ card: String, _ index: Int, _ path: WritableKeyPath<BinderActions.Editable, T>) -> Binding<T> {
        Binding(get: { actions.editing[card]!.first { $0.index == index }![keyPath: path] },
                set: { value in
                    guard let i = actions.editing[card]?.firstIndex(where: { $0.index == index }) else { return }
                    actions.editing[card]![i][keyPath: path] = value
                })
    }
}

struct HistorySection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let reload: () -> Void

    var body: some View {
        if !actions.history.isEmpty {
            Section(header: Text("Recent changes").font(.headline)) {
                ForEach(actions.history.prefix(10)) { change in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(change.line).strikethrough(change.undone)
                            Text([change.who, change.at.map { $0.formatted(.relative(presentation: .named)) }].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if change.undone {
                            Text("undone").font(.caption).foregroundStyle(.secondary)
                        } else if change.undoable, let at = change.at, Date().timeIntervalSince(at) < 7 * 86_400 {
                            Button("Undo") { actions.undo(change, folder, reload: reload) }.disabled(actions.busy)
                        }
                    }
                }
            }
        }
    }
}

/// The binder's description for the clerk and its place on the filing list.
struct FilingSection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL

    var body: some View {
        Section(header: Text("For the clerk").font(.headline)) {
            TextField("One line: what this binder is about", text: $actions.description)
                .textFieldStyle(.roundedBorder)
                .onSubmit { actions.saveSettings(folder) }
            Toggle("On the clerk's filing list", isOn: Binding(get: { actions.filing }, set: {
                actions.filing = $0
                actions.saveSettings(folder)
            }))
            .disabled(actions.description.trimmingCharacters(in: .whitespaces).isEmpty)
            Text("The clerk files a note here only when it is on the list. The line stays in Sprava, never in the binder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// DASHBOARD.md and the manual addendum (binder-v0 §7.1, §9.8).
struct KeepingSection: View {
    @ObservedObject var actions: BinderActions
    let folder: URL
    let today: CalendarDate
    let reload: () -> Void

    var body: some View {
        let keeper = DashboardKeeper(folder: folder)
        let addendum = ManualAddendum.isPresent(in: folder)
        Section(header: Text("Dashboard and manual").font(.headline)) {
            HStack {
                Text(keeper.isSwitched ? "Sprava keeps DASHBOARD.md. Edit only below \u{201C}## Notes\u{201D}."
                                       : "DASHBOARD.md is kept by hand. Sprava can keep it for you; your text moves into its Notes section.")
                Spacer()
                Button("Preview") { actions.showPreview = true }
                if !keeper.isSwitched {
                    Button("Let Sprava Keep It") {
                        let alert = NSAlert()
                        alert.messageText = "Let Sprava keep DASHBOARD.md?"
                        alert.informativeText = "Sprava rewrites the file from the catalog every day and after each change. The current text moves below \u{201C}## Notes\u{201D}, which Sprava never changes, and a copy is kept in the binder's .sprava folder."
                        alert.addButton(withTitle: "Switch")
                        alert.addButton(withTitle: "Cancel")
                        if alert.runModal() == .alertFirstButtonReturn { actions.run("switch_dashboard", folder, [], then: reload) }
                    }
                    .disabled(actions.busy)
                }
            }
            HStack {
                switch addendum {
                case true?: Text("The manual carries Sprava's addendum.").foregroundStyle(.secondary)
                case false?: Text("Paste Sprava's addendum into CLAUDE.md or AGENTS.md, so agents propose instead of editing.").foregroundStyle(.orange)
                case nil: Text("No CLAUDE.md or AGENTS.md here. Paste the addendum into one if an agent works in this binder.").foregroundStyle(.secondary)
                }
                Spacer()
                Button(actions.copied ? "Copied" : "Copy Addendum") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ManualAddendum.text, forType: .string)
                    actions.copied = true
                }
            }
        }
        .sheet(isPresented: $actions.showPreview) {
            VStack(alignment: .leading) {
                ScrollView { Text(keeper.preview(today: today) ?? "unreadable").font(.body.monospaced()).textSelection(.enabled).padding() }
                HStack { Spacer(); Button("Close") { actions.showPreview = false }.keyboardShortcut(.defaultAction) }.padding()
            }
            .frame(width: 720, height: 560)
        }
    }
}

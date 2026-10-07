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
    }

    @Published var cards: [Card] = []
    @Published var folders: [String: String] = [:]
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
    let client = RuntimeClient()

    func load(_ folder: URL, adopted: Bool) async {
        guard adopted else { cards = []; history = []; return }
        do {
            let reply = try await client.command("proposals", binder: folder, timeout: 5)
            cards = (reply["proposals"]?.arrayValue ?? []).compactMap { p in
                guard p["state"] == .str("proposed"), let id = p["id"]?.stringValue else { return nil }
                return Card(id: id, title: p["title"]?.stringValue ?? "", actor: p["actor"]?["kind"]?.stringValue ?? "?",
                            lines: p["lines"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            digest: p["digest"]?.stringValue ?? "", verified: p["verified"] == .bool(true),
                            intake: p["intake"].map(Self.intakeLine), folder: p["document_folder"]?.stringValue)
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
        if let chosen = folders[card.id], chosen != card.folder { fields.append(("document_folder", .string(chosen))) }
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
                        if !card.verified {
                            Text("Not written by Sprava; it cannot be approved.").font(.caption).foregroundStyle(.orange)
                        }
                        HStack {
                            Button("Approve") { actions.approve(card, folder, reload: reload) }
                                .disabled(!card.verified || actions.busy)
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

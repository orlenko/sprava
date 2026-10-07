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
    }

    @Published var cards: [Card] = []
    @Published var message: String?
    @Published var busy = false
    let client = RuntimeClient()

    func load(_ folder: URL, adopted: Bool) async {
        guard adopted else { cards = []; return }
        do {
            let reply = try await client.command("proposals", binder: folder, timeout: 5)
            cards = (reply["proposals"]?.arrayValue ?? []).compactMap { p in
                guard p["state"] == .str("proposed"), let id = p["id"]?.stringValue else { return nil }
                return Card(id: id, title: p["title"]?.stringValue ?? "", actor: p["actor"]?["kind"]?.stringValue ?? "?",
                            lines: p["lines"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                            digest: p["digest"]?.stringValue ?? "", verified: p["verified"] == .bool(true))
            }
        } catch {
            message = "\(error)"
        }
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
        run("approve", folder, [("proposal", .string(card.id)), ("digest", .string(card.digest))], then: reload)
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

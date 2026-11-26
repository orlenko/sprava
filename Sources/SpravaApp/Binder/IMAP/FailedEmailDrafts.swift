import SpravaKit
import SwiftUI

/// Shows only failed placements, on the binder's working page. Older requests have only their date as a label.
@MainActor
final class FailedEmailDrafts: ObservableObject {
    struct Draft: Identifiable, Equatable {
        let id: String
        let subject: String?
        let date: Date?
        let needsReconnection: Bool
        let reason: String
        var label: String { subject.flatMap { $0.isEmpty ? nil : $0 } ?? date.map { "Draft from " + $0.formatted() } ?? "Email draft" }
    }
    enum Action: String { case retry = "imap_draft_retry", discard = "imap_draft_discard", reconnect = "imap_draft_reconnect" }
    @Published private(set) var drafts: [Draft] = []
    @Published private(set) var message: String?
    @Published private(set) var changing = false
    private let client: RuntimeClient
    private var current: URL?
    private var generation = 0

    init(client: RuntimeClient) { self.client = client }

    func reload(_ folder: URL) async {
        if current != folder {
            current = folder
            drafts = []
            message = nil
            changing = false
        }
        guard !changing else { return }
        await request("imap_drafts", folder: folder)
    }

    func apply(_ action: Action, draft: Draft, folder: URL) async {
        guard current == folder, !changing, drafts.contains(draft) else { return }
        changing = true
        defer { if current == folder { changing = false } }
        await request(action.rawValue, folder: folder, fields: [("id", .str(draft.id)), ("if_failed", .bool(true))])
    }

    private func request(_ name: String, folder: URL, fields: [(String, JSONValue)] = []) async {
        generation += 1
        let turn = generation
        do {
            let reply = try await client.command(name, binder: folder, fields)
            guard turn == generation else { return }
            guard let rows = reply["drafts"]?.arrayValue else { return }
            drafts = rows.compactMap {
                let reconnect = $0["state"] == .str("reconnect")
                guard reconnect || $0["state"] == .str("failed"), let id = $0["id"]?.stringValue else { return nil }
                return Draft(id: id, subject: $0["subject"]?.stringValue, date: ISOTime.date($0["created"]?.stringValue),
                             needsReconnection: reconnect, reason: $0["failure"]?.stringValue ?? "Placement failed")
            }
            message = nil
        } catch {
            guard turn == generation else { return }
            message = (error as? RuntimeClient.Failure)?.message ?? "Sprava could not check the draft queue."
        }
    }
}

struct FailedEmailDraftSection: View {
    let folder: URL
    @StateObject private var model: FailedEmailDrafts
    @State private var discard: FailedEmailDrafts.Draft?

    init(folder: URL, client: RuntimeClient) {
        self.folder = folder
        _model = StateObject(wrappedValue: FailedEmailDrafts(client: client))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.drafts) { draft in
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: draft.label).fontWeight(.medium)
                        Text(draft.needsReconnection ? "This binder contains the approved card. Reconnect it to recover the draft." : "Draft could not be placed: " + draft.reason).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if draft.needsReconnection {
                        Button("Reconnect draft") { Task { await model.apply(.reconnect, draft: draft, folder: folder) } }
                    } else {
                        Button("Try again") { Task { await model.apply(.retry, draft: draft, folder: folder) } }
                        Button("Discard…") { discard = draft }
                    }
                }
                .disabled(model.changing)
            }
            if let message = model.message { Text(verbatim: message).foregroundStyle(.secondary) }
        }
        .alert(item: $discard) { draft in
            Alert(title: Text("Discard this draft?"), message: Text(verbatim: draft.label),
                  primaryButton: .destructive(Text("Discard")) { Task { await model.apply(.discard, draft: draft, folder: folder) } },
                  secondaryButton: .cancel())
        }
        .task(id: folder) {
            repeat {
                await model.reload(folder)
                try? await Task.sleep(for: .seconds(15))
            } while !Task.isCancelled
        }
    }
}

import AppKit
import BinderFormat
import Shelf
import SpravaKit
import SwiftUI

struct ConversationSection: View {
    @ObservedObject var model: ClaudeBinderConversation
    let row: ShelfRow
    let reload: () -> Void
    /// Shows the Brains page, where Claude is set up for Sprava.
    var openBrains: () -> Void = {}
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Talk to this binder").font(.headline)
                Spacer()
                ConversationSharingControls(model: model, sharing: model.sharing, folder: row.folder)
            }
            if model.folder == row.folder, model.chat.folder == row.folder {
                // A connected binder's sharing is in its settings. No DisclosureGroup here: it fixes its content's height, and
                // SwiftUI measures the window's minimum with almost no width, so opening one pushed the page above the window's top.
                if !model.connected {
                    ConnectionPanel(model: model, adopted: row.teka.isAdopted, folder: row.folder, openBrains: openBrains)
                }
                ChatView(chat: model.chat, connected: model.connected, suggestion: suggestion)
                if let message = model.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
            } else {
                ProgressView("Loading conversation…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: row.folder) { model.changed = reload; await model.show(row.folder) }
        .onReceive(NotificationCenter.default.publisher(for: .init("Sprava.ClaudeConnectionChanged"))) { _ in Task { await model.show(row.folder) } }
        .confirmationDialog("Clear this binder's saved app conversation and native Claude context?", isPresented: $model.askToClear) {
            Button("Clear conversation", role: .destructive) { Task { await model.clear() } }
        } message: { Text("Stops any active reply first. Tasks already saved remain. Information already sent to Anthropic cannot be recalled.") }
    }

    private func suggestion(_ id: UUID) -> AnyView {
        guard let card = model.cards[id], card.taskTitle != nil || card.to != nil || !card.citations.isEmpty else {
            return AnyView(EmptyView())
        }
        return AnyView(VStack(alignment: .leading, spacing: 4) {
            Text("Suggestions and sources for this reply").font(.caption).foregroundStyle(.secondary)
            ConversationCard(model: model, id: id)
        })
    }
}

/// A binder's connection to Claude, in its settings: what is shared, and the ways to change it.
struct ConversationSettings: View {
    @ObservedObject var model: ClaudeBinderConversation
    var body: some View {
        if model.connected {
            VStack(alignment: .leading, spacing: 8) {
                Text("Shares this binder's tasks and saved app conversation" + (model.documents ? ", filed documents" : "") + (model.intake ? ", and intake" : "") + ".")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Disconnect / change sharing") { Task { await model.disconnect() } }.disabled(model.busy)
                    Button("Clear conversation\u{2026}", role: .destructive) { model.askToClear = true }.disabled(model.busy)
                }
            }
        } else {
            Text("Not connected. Connect it from this binder's conversation.").foregroundStyle(.secondary)
        }
    }
}

private struct ConversationCard: View {
    @ObservedObject var model: ClaudeBinderConversation
    let id: UUID
    var body: some View {
        if let card = model.cards[id] {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(card.citations.enumerated()), id: \.offset) { _, citation in
                    if let path = citation["path"]?.stringValue,
                       (DocumentPaths.isSafe(path, forFiling: false) || DocumentPaths.isIntake(path)), !DocumentPaths.isKeyFile(path) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([card.binder.appendingPathComponent(path)]) } label: {
                            Text(verbatim: "Reveal current source file: " + path)
                        }.font(.caption)
                    }
                }
                if card.taskTitle != nil {
                    Text(card.historical ? "Earlier task suggestion — check To-dos before creating another copy" : "Suggested To-do").font(.headline)
                    TextField("Task title", text: Binding(get: { model.cards[id]?.taskTitle ?? "" }, set: { model.cards[id]?.taskTitle = $0 }))
                        .disabled(card.saving || card.saved || card.uncertain)
                    TextField("Details", text: Binding(get: { model.cards[id]?.taskDetails ?? "" }, set: { model.cards[id]?.taskDetails = $0 }))
                        .disabled(card.saving || card.saved || card.uncertain)
                    HStack {
                        TextField("Due YYYY-MM-DD (blank means no deadline)", text: Binding(get: { model.cards[id]?.due ?? "" }, set: { model.cards[id]?.due = $0 }))
                        Picker("Priority", selection: Binding(get: { model.cards[id]?.priority ?? "normal" }, set: { model.cards[id]?.priority = $0 })) {
                            Text("High").tag("high"); Text("Normal").tag("normal"); Text("Low").tag("low")
                        }
                    }.disabled(card.saving || card.saved || card.uncertain)
                    Button(card.saved ? "Added to To-dos" : card.historical ? "Create a new private To-do" : "Add privately to To-dos") { Task { await model.addTask(id) } }
                        .disabled(card.saving || card.saved || card.uncertain || (card.taskTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let to = card.to {
                    Text("Email draft — not sent").font(.headline)
                    Text(verbatim: "To: " + to).textSelection(.enabled)
                    Text(verbatim: "Subject: " + card.subject).textSelection(.enabled)
                    if !card.recipientGrounded { Text("Verify the recipient against the source email before using this draft.").font(.caption).foregroundStyle(.orange) }
                    Text(verbatim: card.body).textSelection(.enabled)
                    HStack {
                        Button("Copy draft privately") {
                            let text = "To: \(to)\nSubject: \(card.subject)\n\n\(card.body)"
                            model.cards[id]?.message = ProtectedClipboard.copy(text) ? "Copied privately for 60 seconds. Paste into your mail composer to edit and send." : "The draft could not be copied; its text is still here."
                        }
                        Button("Save draft text…") { save(card) }
                    }
                    Text("The original draft is saved with this conversation. Copy or save it to edit in your mail application.").font(.caption).foregroundStyle(.secondary)
                }
                if let message = card.message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
            }
            .padding(8)
        }
    }
    private func save(_ card: ClaudeBinderConversation.Card) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "reply-draft.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try AtomicFile.write(Data("To: \(card.to ?? "")\nSubject: \(card.subject)\n\n\(card.body)".utf8), to: url)
            model.cards[id]?.message = "Draft text saved. No email was sent."
        } catch { model.cards[id]?.message = "The draft could not be saved. Its text is still here." }
    }
}

struct ConversationSharingControls: View {
    @ObservedObject var model: ClaudeBinderConversation
    @ObservedObject var sharing: ConversationSharing
    let folder: URL
    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Menu {
                Button("Copy conversation") { share(.clipboard) }
                Button("Save transcript…") { share(.file) }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(.secondary).frame(width: 24, height: 24).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Copy or save this conversation")
            .accessibilityLabel("Copy or save this conversation")
            .disabled(sharing.busy || model.folder != folder || model.chat.folder != folder)
            if sharing.busy { ProgressView().controlSize(.small) }
            if let message = sharing.message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func share(_ destination: ConversationSharing.Destination) {
        let scope = model.scopeID
        let entries = model.chat.entries
        let cards = model.cards.filter { $0.value.binder == folder && $0.value.scopeID == scope }
        Task {
            await sharing.share(destination, folder: folder, scope: scope, entries: entries, cards: cards,
                                stillSelected: { model.folder == folder && model.chat.folder == folder && model.scopeID == scope })
        }
    }
}

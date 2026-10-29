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
        Section("Conversation with Claude") {
            if model.connected {
                HStack {
                    Text("Shares this binder's tasks and saved app conversation" + (model.documents ? ", filed documents" : "") + (model.intake ? ", and intake mail/attachments." : "."))
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Disconnect / change sharing") { Task { await model.disconnect() } }.disabled(model.busy)
                    Button("Clear conversation…", role: .destructive) { model.askToClear = true }.disabled(model.busy)
                }
            } else {
                Text("Connect this binder to Claude, then ask about priorities, find a source, draft an email, or suggest a To-do.")
                if model.accountReady == false {
                    // The sharing choices come after the one-time setup, so the first thing asked is the thing missing.
                    HStack {
                        Text("First set up Claude in Sprava, once, in Brains.").font(.callout)
                        Button("Open Brains") { openBrains() }
                    }
                } else {
                    Toggle("Share filed documents, including private ones", isOn: $model.documents)
                    Toggle("Share intake mail and attachments", isOn: $model.intake)
                    Button("Connect this binder to Claude") { Task { await model.connect() } }.disabled(model.busy || !row.teka.isAdopted)
                    Text("Claude always sees this binder's task titles and details and the saved conversation, plus what you tick above. It goes to Anthropic; a copied binder has its own conversation. Claude cannot send mail or save tasks itself.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if model.hasSavedScope {
                if !model.connected { Button("Clear saved conversation…", role: .destructive) { model.askToClear = true }.disabled(model.busy) }
                ConversationThread(chat: model.chat, connected: model.connected)
                ForEach(model.chat.entries.compactMap { model.cards[$0.id] }.filter { $0.taskTitle != nil || $0.to != nil || !$0.citations.isEmpty }) { card in
                    ConversationCard(model: model, id: card.id)
                }
            }
            if let message = model.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
        }
        .task(id: row.folder) { model.changed = reload; await model.show(row.folder) }
        .onReceive(NotificationCenter.default.publisher(for: .init("Sprava.ClaudeConnectionChanged"))) { _ in Task { await model.show(row.folder) } }
        .confirmationDialog("Clear this binder's saved app conversation and native Claude context?", isPresented: $model.askToClear) {
            Button("Clear conversation", role: .destructive) { Task { await model.clear() } }
        } message: { Text("Stops any active reply first. Tasks already saved remain. Information already sent to Anthropic cannot be recalled.") }
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

/// The thread, observed on its own, so saved turns that load after the page appears are shown when they arrive.
private struct ConversationThread: View {
    @ObservedObject var chat: BinderChat
    let connected: Bool

    var body: some View {
        if connected || ChatView.showsWhileDisconnected(chat) { ChatView(chat: chat, connected: connected) }
    }
}

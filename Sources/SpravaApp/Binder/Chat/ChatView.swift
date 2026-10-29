import Services
import SwiftUI

/// The conversation drawn on a binder's page: the thread, then the composer (conversation.md §3.1). Every text is
/// shown as plain text, never as Markdown or a link, so a reply or a saved line cannot load anything.
struct ChatView: View {
    @ObservedObject var chat: BinderChat
    /// False while the binder is not connected: its saved turns stay in view, but there is nothing to send to, so
    /// there is no second input on the page, unless an unsent line is kept there, which stays in sight.
    var connected = true

    static let emptyHint = "Ask about this binder's to-dos and documents, or ask for a draft."
    /// Over a line kept in the composer of a binder that is not connected, so it is not taken for the to-do box.
    static let unsentNote = "Unsent message to Claude, kept here until this binder is connected again."

    /// What the conversation shows. A transcript only with turns in it, so an empty one takes no room; the hint only
    /// where there is someone to ask.
    struct Parts: Equatable { var transcript: Bool; var hint: Bool; var composer: Bool }
    static func parts(turns: Int, draft: String, connected: Bool) -> Parts {
        Parts(transcript: turns > 0, hint: connected && turns == 0, composer: connected || !draft.isEmpty)
    }

    /// Whether a binder that is not connected shows its conversation at all: saved turns, a note about them (it
    /// could not be read, say), a message, or an unsent line. Nothing when there is truly nothing.
    static func showsWhileDisconnected(_ chat: BinderChat) -> Bool {
        !chat.entries.isEmpty || chat.historyNote != nil || chat.message != nil || !chat.draft.isEmpty
    }

    var body: some View {
        let parts = Self.parts(turns: chat.entries.count, draft: chat.draft, connected: connected)
        VStack(alignment: .leading, spacing: 8) {
            if let note = chat.historyNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            if parts.hint { Text(Self.emptyHint).font(.callout).foregroundStyle(.secondary) }
            if parts.transcript { transcript }
            if let message = chat.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
            if parts.composer {
                if !connected { Text(Self.unsentNote).font(.caption).foregroundStyle(.secondary) }
                Composer(chat: chat)
            }
        }
    }

    var transcript: some View {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(chat.entries) { entry in
                            EntryView(entry: entry, chat: chat).id(entry.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: chat.entries.last?.id) { _, last in
                    if let last { withAnimation { scroller.scrollTo(last, anchor: .bottom) } }
                }
            }
            // The turns take the room; the composer keeps the height of what is typed in it.
            .frame(minHeight: 160, idealHeight: 340, maxHeight: 460)
    }
}

private struct EntryView: View {
    let entry: BinderChat.Entry
    @ObservedObject var chat: BinderChat

    var body: some View {
        VStack(alignment: entry.speaker == .person ? .trailing : .leading, spacing: 4) {
            if !entry.text.isEmpty {
                Text(verbatim: entry.text)
                    .textSelection(.enabled)
                    .padding(8)
                    .background(entry.speaker == .person ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8))
            }
            if let activity = entry.activity {
                Label { Text(verbatim: activity) } icon: { ProgressView().controlSize(.small) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(Array(entry.changes.enumerated()), id: \.offset) { _, change in
                HStack(spacing: 8) {
                    Text(verbatim: change.summary).font(.callout)
                    if change.undo != nil {
                        if chat.isUndone(change) {
                            Text("Undone").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Button("Undo") { Task { await chat.undo(change) } }.controlSize(.small)
                        }
                    }
                }
            }
            if entry.changesCut {
                Text("More changes were made than this page shows; the binder's history has them all.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            status
        }
        .frame(maxWidth: .infinity, alignment: entry.speaker == .person ? .trailing : .leading)
    }

    @ViewBuilder private var status: some View {
        switch entry.state {
        case .sending: Text("Sending\u{2026}").font(.caption).foregroundStyle(.secondary)
        case .notSent(let why):
            HStack(spacing: 8) {
                Text(verbatim: "Not sent. \(why)").font(.caption).foregroundStyle(.secondary)
                Button("Retry") { Task { await chat.retry(entry) } }.controlSize(.small).disabled(chat.isReplying)
            }
        case .replying where entry.text.isEmpty && entry.activity == nil:
            ProgressView().controlSize(.small)
        case .stopped: Text("Stopped. Changes made before Stop keep their Undo.").font(.caption).foregroundStyle(.secondary)
        case .incomplete: Text("This reply stopped before it finished.").font(.caption).foregroundStyle(.secondary)
        case .failed(let why): Text(verbatim: why).font(.caption).foregroundStyle(.secondary)
        default: EmptyView()
        }
    }
}

private struct Composer: View {
    @ObservedObject var chat: BinderChat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            DraftEditor(text: Binding(get: { chat.draft }, set: { chat.draft = $0 }))
                .disabled(!chat.isAvailable)
            HStack {
                if !chat.isAvailable {
                    Text("This binder cannot hold a conversation yet.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if chat.isReplying {
                    Button(chat.isStopping ? "Stopping\u{2026}" : "Stop") { Task { await chat.stop() } }
                        .keyboardShortcut(.escape, modifiers: [])
                        .disabled(chat.isStopping)
                }
                Button("Send") { Task { await chat.send() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!chat.canSend)
            }
        }
    }
}

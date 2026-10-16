import Services
import SwiftUI

/// The conversation drawn on a binder's page: the thread, then the composer (conversation.md §3.1). Every text is
/// shown as plain text, never as Markdown or a link, so a reply or a saved line cannot load anything.
struct ChatView: View {
    @ObservedObject var chat: BinderChat

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let note = chat.historyNote { Text(note).font(.caption).foregroundStyle(.secondary) }
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
            if let message = chat.message { Text(verbatim: message).font(.callout).foregroundStyle(.secondary) }
            Composer(chat: chat)
        }
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
            TextEditor(text: Binding(get: { chat.draft }, set: { chat.draft = $0 }))
                .font(.body)
                .frame(minHeight: 60)
                .disabled(!chat.isAvailable)
                .overlay(alignment: .topLeading) {
                    if chat.draft.isEmpty {
                        Text("Tell this binder\u{2026}").foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                    }
                }
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

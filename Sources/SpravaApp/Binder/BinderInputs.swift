import SwiftUI

/// The page's input. With the binder connected to Claude, the conversation is the one input, and adding to-dos
/// without Claude stays one click away below it. Otherwise the to-do box comes first, labelled for what it does,
/// and the conversation section below offers the setup and keeps any saved transcript in view. Both models keep
/// their drafts whichever is shown, and nothing typed in one is ever sent through the other.
struct BinderInputs: View {
    let note: NoteBox?
    let conversation: ConversationSection?

    var body: some View {
        if let conversation {
            InputsWithConversation(model: conversation.model, note: note, conversation: conversation)
        } else if let note {
            note
        }
    }
}

private struct InputsWithConversation: View {
    @ObservedObject var model: ClaudeBinderConversation
    let note: NoteBox?
    let conversation: ConversationSection

    var body: some View {
        if model.connected {
            conversation
            if let note { DirectNote(box: note, note: note.note) }
        } else {
            if let note { note }
            conversation
        }
    }
}

/// The to-do box behind a button while the conversation is the page's input.
private struct DirectNote: View {
    let box: NoteBox
    @ObservedObject var note: BinderNote

    var body: some View {
        if note.directShown {
            box.besideConversation()
        } else {
            Section {
                Button("Add to-dos without Claude\u{2026}") { note.directOpen = true }
            }
        }
    }
}

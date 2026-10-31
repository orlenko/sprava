import SwiftUI

/// The binder's assistant is always first. Direct to-do entry remains separately labelled and preserves drafts,
/// so an unavailable assistant never turns a question into an unintended to-do.
struct BinderInputs: View {
    let note: NoteBox?
    let conversation: ConversationSection?

    var body: some View {
        if let conversation {
            conversation
            if let note { DirectNote(box: note, note: note.note) }
        } else if let note {
            note
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

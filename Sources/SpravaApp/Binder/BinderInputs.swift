import SwiftUI

/// Local capture and the optional provider conversation are independent entry points.
/// Keeping a conversation model must never remove the person's local note form.
struct BinderInputs: View {
    let note: NoteBox?
    let conversation: ConversationSection?

    var body: some View {
        if let note { note }
        if let conversation { conversation }
    }
}

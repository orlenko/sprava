import SwiftUI

/// The box a person types a note or a message into, with its placeholder. It grows with what is typed up to
/// `maxHeight`, then scrolls inside: grown to a long pasted text, it ran past the page's top and bottom.
struct DraftEditor: View {
    static let minHeight: CGFloat = 60
    static let maxHeight: CGFloat = 240
    @Binding var text: String
    var placeholder = "Tell this binder\u{2026}"

    var body: some View {
        TextEditor(text: $text)
            .font(.body)
            .frame(minHeight: Self.minHeight, maxHeight: Self.maxHeight)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).foregroundStyle(.tertiary).padding(.leading, 5).allowsHitTesting(false)
                }
            }
            // A box you can see: in a List row a bare TextEditor has no edge, and reads as empty page.
            .padding(4)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

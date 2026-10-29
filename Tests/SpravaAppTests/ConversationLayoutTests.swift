import Foundation
import Services
@testable import SpravaApp
import Testing

/// Rendered with invented fixtures (2026-10-29): a disconnected binder with a saved conversation drew a second,
/// greyed-out "Tell this binder" box under the to-do box, and an empty conversation stretched its composer over a
/// blank transcript.
@MainActor
@Suite struct ConversationLayoutTests {
    @Test func aDisconnectedBinderShowsNoSecondInputUnlessALineIsKeptThere() {
        #expect(ChatView.parts(turns: 3, draft: "", connected: false) == .init(transcript: true, hint: false, composer: false))
        #expect(ChatView.parts(turns: 0, draft: "", connected: false) == .init(transcript: false, hint: false, composer: false))
        // An unsent line stays in sight, so nothing typed is ever hidden.
        #expect(ChatView.parts(turns: 0, draft: "Which invented bylaw?", connected: false).composer)
    }

    @Test func anEmptyConnectedConversationIsTheComposerAndAHint() {
        #expect(ChatView.parts(turns: 0, draft: "", connected: true) == .init(transcript: false, hint: true, composer: true))
        #expect(ChatView.parts(turns: 2, draft: "", connected: true) == .init(transcript: true, hint: false, composer: true))
    }

    @Test func aDisconnectedBinderShowsItsThreadOnlyWhenThereIsSomethingInIt() async {
        let folder = URL(fileURLWithPath: "/invented/workshop")
        let empty = BinderChat(commands: nil, binderID: { _ in "acme-binder" }, readHistory: { _ in ([], nil) })
        await empty.show(folder)
        #expect(!ChatView.showsWhileDisconnected(empty))
        empty.draft = "Which invented bylaw?"
        #expect(ChatView.showsWhileDisconnected(empty))
        // A history that could not be read says so; that is not "nothing".
        let unread = BinderChat(commands: nil, binderID: { _ in "acme-binder" },
                                readHistory: { _ in ([], "Saved conversation is unavailable.") })
        await unread.show(folder)
        #expect(ChatView.showsWhileDisconnected(unread))
    }
}

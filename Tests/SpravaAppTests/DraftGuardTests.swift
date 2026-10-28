import AppKit
import Foundation
import SpravaKit
@testable import SpravaApp
import Testing

@MainActor @Suite struct DraftGuardTests {
    final class Owner: DraftOwner { var draftState = DraftState() }
    let folder = URL(fileURLWithPath: "/invented/workshop")
    let other = URL(fileURLWithPath: "/invented/garden")

    @Test func closingAndQuittingRequireAnExplicitChoiceForUnfinishedWork() {
        let registry = DraftRegistry(), owner = Owner(); registry.track(owner)
        var prompts = 0, allow = false
        let policy = DraftGuard(registry: registry, confirm: { _, saving in
            #expect(!saving); prompts += 1; return allow
        })
        #expect(policy.permits(.close) && policy.permits(.quit)); #expect(prompts == 0)
        owner.draftState.hasChanges = true
        #expect(!policy.permits(.close) && !policy.permits(.quit)); #expect(prompts == 2)
        allow = true
        #expect(policy.permits(.close) && policy.permits(.quit)); #expect(prompts == 4)
        #expect(owner.draftState.hasChanges) // Closing never saves or approves anything on the person's behalf.
    }

    @Test func evenAnEmptyEditorCannotCloseWhileItsSaveIsUnconfirmed() {
        let registry = DraftRegistry(), owner = Owner(); registry.track(owner)
        owner.draftState.saving = true
        let policy = DraftGuard(registry: registry, confirm: { _, saving in #expect(saving); return true })
        #expect(!policy.permits(.quit) && !policy.permits(.close))
        owner.draftState.saving = false
        #expect(policy.permits(.quit))
    }

    @Test func theApplicationObservesEveryWindowWithoutKeepingClosedWindowsAlive() {
        let application = DraftRegistry(), window = DraftRegistry(), owner = Owner()
        application.track(window); window.track(owner); owner.draftState.hasChanges = true
        #expect(application.draftState.hasChanges)
        var temporary: Owner? = Owner(); temporary?.draftState.saving = true
        weak var observed = temporary
        window.track(temporary!)
        #expect(application.draftState.saving)
        temporary = nil
        #expect(observed == nil && !application.draftState.saving)
    }

    @Test func notesAndCardEditsInABinderLeftBehindStillProtectTheWindow() async throws {
        let runtime = StandInRuntime(), registry = DraftRegistry()
        let note = BinderNote(client: runtime.client, support: folder)
        registry.track(note); note.show(folder); note.text = "Keep these invented words"; note.show(other)
        #expect(note.text.isEmpty && registry.draftState.hasChanges)
        note.show(folder); note.text = ""; note.show(other)
        #expect(!registry.draftState.hasChanges)

        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"Invented hint","filing":true}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let actions = BinderActions(client: runtime.client); registry.track(actions)
        await actions.load(folder, adopted: true)
        #expect(!registry.draftState.hasChanges)
        actions.description = "A revised invented instruction"
        await actions.load(other, adopted: true)
        #expect(registry.draftState.hasChanges)
        await actions.load(folder, adopted: true)
        #expect(actions.description == "A revised invented instruction")
        actions.description = "Invented hint"
        #expect(!registry.draftState.hasChanges)

        actions.setSaid("invented-card", "Handed over on paper")
        await actions.load(other, adopted: true)
        #expect(registry.draftState.hasChanges)
        let policy = DraftGuard(registry: registry, confirm: { _, _ in false })
        #expect(!policy.permits(.quit))
        #expect(!runtime.sent.contains { ["apply", "approve"].contains($0["command"]?.stringValue ?? "") })
    }

    @Test func anItemSaveBlocksDismissalUntilTheRuntimeAcknowledgesIt() async throws {
        let fixture = ItemEditingTests(), (actions, _, folder) = try await fixture.binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor(), registry = DraftRegistry(); registry.track(editor)
        let item = try await fixture.openItem("acme-1", in: folder)
        #expect(editor.begin(item, in: folder, actions, reload: {}))
        #expect(!registry.draftState.hasChanges)
        editor.setTitle("Send the invented invoice by post", in: folder)
        #expect(registry.draftState.hasChanges)
        let save = try #require(editor.save(in: folder, actions, reload: {}))
        let policy = DraftGuard(registry: registry, confirm: { _, saving in #expect(saving); return true })
        #expect(!policy.permits(.quit))
        await save.value
        #expect(policy.permits(.quit) && !registry.draftState.hasChanges)
    }

    @Test func inboxAndTodoComposersNeverCloseSilentlyWithTypedWords() {
        let runtime = StandInRuntime(), registry = DraftRegistry()
        let inbox = InboxModel(client: runtime.client, support: folder), todo = TodoModel(client: runtime.client)
        registry.track(inbox); registry.track(todo)
        let policy = DraftGuard(registry: registry, confirm: { _, _ in false })
        inbox.draft = "An invented note"
        #expect(!policy.permits(.quit))
        inbox.draft = ""; todo.draft = "An invented task"
        #expect(!policy.permits(.close))
        todo.draft = ""
        #expect(policy.permits(.quit) && runtime.sent.isEmpty)
    }

    @Test func openingAReviewEditorIsCleanUntilItsWordsActuallyChange() {
        let runtime = StandInRuntime()
        let actions = BinderActions(client: runtime.client)
        let editable = BinderActions.Editable(index: 0, title: "Read the invented notice", due: "", priority: "normal")
        let card = BinderActions.Card(id: "invented-card", title: "Add an item", actor: "clerk", lines: [], digest: "invented-digest",
                                      verified: true, intake: nil, folder: "documents", notes: [], editable: [editable])
        actions.cards = [card, card] // Repeated ids in a response must not crash a close decision.
        #expect(actions.startEditing(card))
        #expect(!actions.draftState.hasChanges)
        #expect(actions.setItem(card.id, 0, \.title, "Read it by Friday"))
        #expect(actions.draftState.hasChanges)
        #expect(actions.setItem(card.id, 0, \.title, editable.title))
        #expect(!actions.draftState.hasChanges)
        #expect(actions.setFolder(card.id, "documents"))
        #expect(!actions.draftState.hasChanges)
        #expect(actions.setFolder(card.id, "notices"))
        #expect(actions.draftState.hasChanges && runtime.sent.isEmpty)
    }

    @Test func conversationDraftsAndEditedTaskSuggestionsAreIncluded() async throws {
        let fixtures = ClaudeConversationAdapterTests(), server = ClaudeConversationAdapterTests.Server()
        let conversation = fixtures.model(server), registry = DraftRegistry(); registry.track(conversation)
        await conversation.show(fixtures.folder)
        conversation.chat.draft = "Ask about the invented bylaw"
        #expect(registry.draftState.hasChanges)
        await conversation.chat.send(); await fixtures.until { !conversation.chat.isReplying }
        #expect(!registry.draftState.hasChanges)
        let id = try #require(conversation.cards.keys.first)
        conversation.cards[id]?.taskDetails = "Words added by the person"
        #expect(registry.draftState.hasChanges)
        conversation.cards[id]?.taskDetails = "Request written permission."
        #expect(!registry.draftState.hasChanges)
    }

    final class OriginalDelegate: NSObject, NSWindowDelegate {
        var allow = true
        func windowShouldClose(_ sender: NSWindow) -> Bool { allow }
        func windowDidResize(_ notification: Notification) {}
    }
    @Test func theWindowGuardPreservesTheExistingDelegateAndItsOtherCallbacks() {
        _ = NSApplication.shared
        let registry = DraftRegistry(), owner = Owner(); registry.track(owner)
        var choice = false
        let policy = DraftGuard(registry: registry, confirm: { _, _ in choice })
        let proxy = WindowDraftDelegate(guarding: policy), original = OriginalDelegate()
        proxy.original = original
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 20, height: 20), styleMask: [.titled], backing: .buffered, defer: false)
        owner.draftState.hasChanges = true
        #expect(!proxy.windowShouldClose(window))
        choice = true; #expect(proxy.windowShouldClose(window))
        original.allow = false; #expect(!proxy.windowShouldClose(window))
        let callback = #selector(NSWindowDelegate.windowDidResize(_:))
        #expect(proxy.responds(to: callback))
        #expect((proxy.forwardingTarget(for: callback) as AnyObject?) === original)
    }
}

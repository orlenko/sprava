import Foundation
import Shelf
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

/// One binder's page against a stand-in runtime: settings never cross binders, a late reply for a binder left
/// behind is dropped, a refused approval keeps the person's edits, a card is locked while its approval is on its
/// way and, once approved, until it leaves the page, and drafts wait for their binder. Invented paths only.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct BinderPageTests {
    let kitchen = URL(fileURLWithPath: "/Invented/kitchen-reno", isDirectory: true)
    let garden = URL(fileURLWithPath: "/Invented/garden-shed", isDirectory: true)

    @Test func repeatedDisplayTextHasDistinctIDsIndependentOfItsContents() {
        let text = ["Invented private matter", "Invented private matter", ""]
        let rows = DisplayLine.rows(text)
        #expect(rows.map(\.text) == text)
        #expect(Set(rows.map(\.id)).count == text.count)
        // Editing the words never puts those words into the row's identity.
        let changed = DisplayLine.rows(["Other invented words", "Other invented words", "Other invented words"])
        #expect(changed.map(\.id) == rows.map(\.id))
        #expect(DisplayLine.rows([]).isEmpty)
    }

    @Test func anotherBindersSettingsAreNeverSavedIntoThisOne() async {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"Kitchen renovation quotes","filing":true}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        #expect(actions.settingsLoaded && actions.description == "Kitchen renovation quotes" && actions.filing)

        // The garden binder's settings cannot be read: the fields are cleared and stay locked.
        runtime.answers["binder_settings"] = nil
        await actions.load(garden, adopted: true)
        #expect(!actions.settingsLoaded && actions.description.isEmpty && !actions.filing)
        actions.description = "typed before the settings arrived"
        actions.saveSettings(garden)
        // A save that went ahead would be busy at once; this one was refused before anything was sent.
        #expect(!actions.busy)
        let writes = runtime.sent.filter { $0["command"]?.stringValue == "binder_settings" && $0["description"] != nil }
        #expect(writes.isEmpty)
    }

    @Test func aReplyForTheBinderLeftBehindIsDropped() async {
        let runtime = StandInRuntime()
        let actions = BinderActions(client: runtime.client)
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["binder_settings"] = { [garden, kitchenPath = kitchen.standardizedFileURL.path] request in
            guard request["binder"]?.stringValue == kitchenPath else {
                return #"{"ok":true,"description":"Garden shed build","filing":false}"#
            }
            // The person opens the garden binder while the kitchen's settings are on their way.
            await actions.load(garden, adopted: true)
            return #"{"ok":true,"description":"Kitchen renovation quotes","filing":true}"#
        }
        await actions.load(kitchen, adopted: true)
        #expect(actions.serves(garden))
        #expect(actions.description == "Garden shed build" && !actions.filing && actions.settingsLoaded)
    }

    @Test func theDashboardAndManualAreReadOffTheMainActorWithABound() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let stalled = StalledBinderRead()
        defer { stalled.release.signal() }
        // Only the stalled read times out, when the test expires it; the later reads and the preview never do.
        let deadlines = ManualDeadlines()
        let actions = BinderActions(client: runtime.client, readKeeping: stalled.keeping,
                                    renderPreview: { _, _ in Thread.isMainThread ? "rendered on the main actor" : "Invented dashboard" },
                                    deadline: deadlines.deadline)
        // The binder's volume stalls: the page loads, says the files are slow, and the settings still arrive.
        let loading = Task { await actions.load(kitchen, adopted: true) }
        await stalled.calls.wait(for: 1)
        deadlines.expire()
        await loading.value
        // The page loaded while the read was still stalled.
        #expect(!stalled.completed)
        #expect(stalled.ranOffMain && actions.keeping == nil && actions.keepingNote != nil && actions.settingsLoaded)
        _ = KeepingSection(actions: actions, folder: kitchen, today: CalendarDate.today(), reload: {}).body
        #expect(stalled.calls.value == 1)

        // Once the read ends, the next load shows what it found and the note goes away.
        stalled.release.signal()
        await stalled.finishes.wait(for: 1)
        try await untilDone({ actions.keeping != nil }) { await actions.loadKeeping(kitchen) }
        #expect(stalled.calls.value >= 2)
        #expect(actions.keeping == BinderActions.Keeping(switched: true, addendum: false) && actions.keepingNote == nil)

        await actions.showDashboardPreview(kitchen, today: CalendarDate.today())
        #expect(actions.showPreview && actions.preview == "Invented dashboard")
    }

    @Test func aRefusedApprovalKeepsTheEdits() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-1","state":"proposed","title":"Add 1 item","digest":"d1","verified":true,"actor":{"kind":"clerk"},"lines":["Call the tiler"],"editable":[{"index":0,"title":"Call the tiler","due":"2026-10-20","priority":"normal"}]}]}"#
        }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)
        actions.startEditing(card)
        actions.setItem(card.id, 0, \.due, "2026-10-32")

        runtime.answers["approve"] = { _ in #"{"ok":false,"error":"due: not a calendar date"}"# }
        await actions.approve(card, kitchen, reload: {})?.value
        #expect(actions.editing[card.id]?.first?.due == "2026-10-32")
        #expect(actions.message == "due: not a calendar date")

        actions.setItem(card.id, 0, \.due, "2026-10-31")
        runtime.answers["approve"] = { _ in #"{"ok":true}"# }
        await actions.approve(card, kitchen, reload: {})?.value
        #expect(actions.editing[card.id] == nil)
        let sent = runtime.sent.last { $0["command"]?.stringValue == "approve" }
        let edits = try #require(sent?["edits"]?.arrayValue)
        #expect(edits.first?["due"]?.stringValue == "2026-10-31")
    }

    @Test func wordsTypedUnderAnUntouchedPickerGoWithTheApproval() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-2","state":"proposed","title":"File quote.pdf","digest":"d2","verified":true,"actor":{"kind":"intake"},"lines":["File quote.pdf"],"document_folder":"quotes","intake":{"name":"quote.pdf","obtained":{"channel":"other"}}}]}"#
        }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["approve"] = { _ in #"{"ok":true}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)
        #expect(card.asksChannel)
        actions.setSaid(card.id, "handed over by the tiler")
        await actions.approve(card, kitchen, reload: {})?.value
        let obtained = try #require(runtime.sent.last { $0["command"]?.stringValue == "approve" }?["obtained"])
        #expect(obtained["channel"]?.stringValue == "other")
        #expect(obtained["said"]?.stringValue == "handed over by the tiler")
    }

    @Test func aReloadAfterAnotherActionKeepsAnUnsavedDescription() async throws {
        let runtime = StandInRuntime()
        var saved = "Kitchen renovation quotes"
        runtime.answers["binder_settings"] = { request in
            if let line = request["description"]?.stringValue { saved = line }
            return #"{"ok":true,"description":"\#(saved)","filing":true}"#
        }
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)

        // Typed without Return, then a card is approved or an item marked done: the page reloads.
        actions.description = "Kitchen and pantry renovation"
        await actions.load(kitchen, adopted: true)
        #expect(actions.description == "Kitchen and pantry renovation")

        // Once saved, the line follows the runtime again.
        try await #require(actions.saveSettings(kitchen)).value
        #expect(saved == "Kitchen and pantry renovation")
        saved = "Pantry only"
        await actions.load(kitchen, adopted: true)
        #expect(actions.description == "Pantry only")
    }

    @Test func anEditorReadAfterItsEditsWereDroppedGivesTheItemAsDrawn() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-3","state":"proposed","title":"Add 1 item","digest":"d3","verified":true,"actor":{"kind":"clerk"},"lines":["Chase the plumber"],"editable":[{"index":0,"title":"Chase the plumber","due":"2026-10-22","priority":"high","waiting_on":"Invented Plumbing"}]}]}"#
        }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["approve"] = { _ in #"{"ok":true}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)
        actions.startEditing(card)
        let item = try #require(actions.editing[card.id]?.first)
        let section = ReviewSection(actions: actions, folder: kitchen, reload: {})
        let title = section.binding(card.id, item, \.title)
        let party = section.partyBinding(card.id, item)
        title.wrappedValue = "Chase the plumber again"
        #expect(title.wrappedValue == "Chase the plumber again")

        // The approval is accepted and the edits dropped while the controls still hold their bindings.
        await actions.approve(card, kitchen, reload: {})?.value
        #expect(actions.editing[card.id] == nil)
        #expect(title.wrappedValue == "Chase the plumber")
        #expect(party.wrappedValue == "Invented Plumbing")
        title.wrappedValue = "ignored"
        #expect(actions.editing[card.id] == nil)
    }

    @Test func draftsSurviveAVisitToAnotherBinder() async throws {
        let runtime = StandInRuntime()
        let kitchenPath = kitchen.standardizedFileURL.path
        runtime.answers["binder_settings"] = { request in
            request["binder"]?.stringValue == kitchenPath
                ? #"{"ok":true,"description":"Kitchen renovation quotes","filing":true}"#
                : #"{"ok":true,"description":"Garden shed build","filing":false}"#
        }
        runtime.answers["proposals"] = { request in
            guard request["binder"]?.stringValue == kitchenPath else { return #"{"ok":true,"proposals":[]}"# }
            return #"{"ok":true,"proposals":[{"id":"p-4","state":"proposed","title":"Add 1 item","digest":"d4","verified":true,"actor":{"kind":"clerk"},"lines":["Order the tiles"],"editable":[{"index":0,"title":"Order the tiles","due":"","priority":"normal"}]}]}"#
        }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)

        // Typed without Return, and a proposal edited, then the garden binder is opened.
        actions.description = "Kitchen and pantry renovation"
        actions.startEditing(card)
        actions.setItem(card.id, 0, \.due, "2026-11-02")
        await actions.load(garden, adopted: true)
        #expect(actions.description == "Garden shed build")
        #expect(actions.editing.isEmpty)

        await actions.load(kitchen, adopted: true)
        #expect(actions.description == "Kitchen and pantry renovation")
        #expect(actions.editing[card.id]?.first?.due == "2026-11-02")

        // Once approved, nothing of it comes back after another visit.
        runtime.answers["approve"] = { _ in #"{"ok":true}"# }
        await actions.approve(card, kitchen, reload: {})?.value
        await actions.load(garden, adopted: true)
        await actions.load(kitchen, adopted: true)
        #expect(actions.editing[card.id] == nil)
    }

    @Test func aCardIsLockedWhileItsApprovalIsOnItsWay() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-5","state":"proposed","title":"File invoice.pdf","digest":"d5","verified":true,"actor":{"kind":"intake"},"lines":["File invoice.pdf","Pay the tiler"],"document_folder":"invoices","intake":{"name":"invoice.pdf","obtained":{"channel":"other"}},"editable":[{"index":0,"title":"Pay the tiler","due":"2026-10-25","priority":"normal"}]}]}"#
        }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        // The runtime answers the approval only when the test lets it.
        let (replies, reply) = AsyncStream<String>.makeStream()
        runtime.answers["approve"] = { _ in
            for await text in replies { return text }
            return #"{"ok":false,"error":"no answer"}"#
        }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)
        actions.startEditing(card)
        actions.setItem(card.id, 0, \.title, "Pay the tiler in full")
        actions.setSaid(card.id, "handed over by the tiler")

        let approval = try #require(actions.approve(card, kitchen, reload: {}))
        #expect(actions.pending == [card.id] && !actions.isChangeable(card.id))
        // While the runtime works, nothing on the card can change, and a second approval or a rejection is refused.
        #expect(!actions.setItem(card.id, 0, \.title, "Pay the tiler half now"))
        #expect(!actions.setItem(card.id, 0, \.waitingOn, "Invented Tiling"))
        #expect(!actions.setSaid(card.id, "handed over by the tiler, with the receipt"))
        #expect(!actions.setChannel(card.id, "paper"))
        #expect(!actions.setFolder(card.id, "receipts"))
        #expect(actions.approve(card, kitchen, reload: {}) == nil)
        #expect(actions.reject(card, kitchen, reload: {}) == nil)
        #expect(actions.editing[card.id]?.first?.title == "Pay the tiler in full")
        #expect(actions.said[card.id] == "handed over by the tiler")
        #expect(actions.channels[card.id] == nil && actions.folders[card.id] == nil)

        // The approval is refused: the card opens again with what was set before it.
        reply.yield(#"{"ok":false,"error":"the card changed since it was shown"}"#)
        await approval.value
        #expect(actions.pending.isEmpty && actions.isChangeable(card.id))
        #expect(actions.editing[card.id]?.first?.title == "Pay the tiler in full")
        #expect(actions.said[card.id] == "handed over by the tiler")
        #expect(actions.setSaid(card.id, "handed over by the tiler, with the receipt"))
        #expect(actions.said[card.id] == "handed over by the tiler, with the receipt")
        let sent = runtime.sent.filter { $0["command"]?.stringValue == "approve" }
        #expect(sent.count == 1)
    }

    @Test func anApprovedCardStaysLockedUntilARefreshNoLongerListsIt() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        let listed = #"{"ok":true,"proposals":[{"id":"p-6","state":"proposed","title":"File receipt.pdf","digest":"d6","verified":true,"actor":{"kind":"intake"},"lines":["File receipt.pdf","Claim the deposit back"],"document_folder":"receipts","intake":{"name":"receipt.pdf","obtained":{"channel":"other"}},"editable":[{"index":0,"title":"Claim the deposit back","due":"2026-11-05","priority":"normal"}]}]}"#
        runtime.answers["proposals"] = { _ in listed }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["approve"] = { _ in #"{"ok":true}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)
        actions.startEditing(card)
        actions.setItem(card.id, 0, \.due, "2026-11-06")

        // The refresh after the approval is slow, and its reply still lists the card, as one sent before the
        // runtime settled it would.
        let (replies, reply) = AsyncStream<String>.makeStream()
        runtime.answers["proposals"] = { _ in
            for await text in replies { return text }
            return #"{"ok":false,"error":"no answer"}"#
        }
        let kitchen = kitchen
        var refresh: Task<Void, Never>?
        try await #require(actions.approve(card, kitchen, reload: { refresh = Task { await actions.loadReview(kitchen) } })).value
        #expect(actions.pending.isEmpty && actions.settled == [card.id])
        #expect(actions.cards.map(\.id) == [card.id] && actions.editing[card.id] == nil)
        // The card is still on the page, but nothing typed into it now could go anywhere: it stays locked.
        #expect(!actions.isChangeable(card.id))
        #expect(!actions.startEditing(card))
        #expect(!actions.setSaid(card.id, "handed over by the tiler"))
        #expect(!actions.setFolder(card.id, "deposits"))
        #expect(actions.approve(card, kitchen, reload: {}) == nil && actions.reject(card, kitchen, reload: {}) == nil)
        reply.yield(listed)
        await refresh?.value
        #expect(actions.cards.map(\.id) == [card.id] && !actions.isChangeable(card.id))

        // A refresh that no longer lists the card lets go of it.
        runtime.answers["proposals"] = { _ in #"{"ok":true,"proposals":[]}"# }
        await actions.loadReview(kitchen)
        #expect(actions.cards.isEmpty && actions.settled.isEmpty)
        #expect(runtime.sent.filter { $0["command"]?.stringValue == "approve" }.count == 1)
    }

    @Test func aRefusedRejectionUnlocksTheCard() async throws {
        let runtime = StandInRuntime()
        runtime.answers["binder_settings"] = { _ in #"{"ok":true,"description":"","filing":false}"# }
        runtime.answers["proposals"] = { _ in
            #"{"ok":true,"proposals":[{"id":"p-7","state":"proposed","title":"Add 1 item","digest":"d7","verified":true,"actor":{"kind":"clerk"},"lines":["Book the electrician"],"editable":[{"index":0,"title":"Book the electrician","due":"","priority":"normal"}]}]}"#
        }
        runtime.answers["history"] = { _ in #"{"ok":true,"ops":[]}"# }
        runtime.answers["reject"] = { _ in #"{"ok":false,"error":"the card changed since it was shown"}"# }
        let actions = BinderActions(client: runtime.client)
        await actions.load(kitchen, adopted: true)
        let card = try #require(actions.cards.first)
        try await #require(actions.reject(card, kitchen, reload: {})).value
        #expect(actions.pending.isEmpty && actions.settled.isEmpty && actions.isChangeable(card.id))
        #expect(actions.startEditing(card))
    }
}

/// A binder read that waits for the test, standing in for a stalled volume or a file still being downloaded.
private final class StalledBinderRead: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    let calls = Arrivals()
    let finishes = Arrivals()
    private let lock = NSLock()
    private var offMain = true
    var ranOffMain: Bool { lock.withLock { offMain } }
    var completed: Bool { finishes.value > 0 }

    func keeping(_ folder: URL) -> BinderActions.Keeping {
        lock.withLock { offMain = offMain && !Thread.isMainThread }
        if calls.arrive() == 1 {
            // A bound far beyond the test's own pace, so a broken implementation fails instead of hanging.
            _ = release.wait(timeout: .now() + 30)
            finishes.arrive()
        }
        return BinderActions.Keeping(switched: true, addendum: false)
    }
}

import BinderFormat
import Foundation
import SpravaKit
@testable import SpravaApp
import Testing

@MainActor
@Suite struct ItemFollowUpTests {
    @Test func detailsPriorityAndFollowUpSurviveSavingAndReopening() async throws {
        let fixture = ItemEditingTests()
        let (actions, _, folder) = try await fixture.binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        editor.begin(try await fixture.openItem("acme-1", in: folder), in: folder, actions, reload: {})
        editor.setDetails("Compare the invented maintenance quotes", in: folder)
        editor.setPriority(.high, in: folder)
        editor.setStatus(.waiting, in: folder)
        editor.setWaitingOn("the contractor", in: folder)
        let followUp = CalendarDate.today().adding(days: 7)
        editor.setFollowUp(followUp, in: folder)
        #expect(editor.draftState.hasChanges)
        try await #require(editor.save(in: folder, actions, reload: {})).value
        #expect(editor.row(in: folder) == nil && !editor.draftState.hasChanges && actions.message == nil)
        let saved = try await fixture.openItem("acme-1", in: folder)
        #expect(saved.object?["details"] == .str("Compare the invented maintenance quotes"))
        #expect(saved.priority == .high && saved.status == .waiting && saved.waitingOn == "the contractor")
        #expect(saved.followUpAt == followUp)
        #expect(await fixture.shown("acme-1", in: folder)?.bucket == .waiting)
        editor.begin(saved, in: folder, actions, reload: {})
        #expect(editor.row(in: folder)?.details == "Compare the invented maintenance quotes")
        #expect(editor.row(in: folder)?.followUp == saved.followUpAt && !editor.draftState.hasChanges)
        editor.setStatus(.open, in: folder)
        try await #require(editor.save(in: folder, actions, reload: {})).value
        let reopened = try await fixture.openItem("acme-1", in: folder)
        #expect(reopened.status == .open && reopened.waitingOn == nil && reopened.followUpAt == nil)
        #expect(reopened.object?["details"] == saved.object?["details"])
    }

    @Test func anIncompleteWaitingEditStaysOpenUntilItCanBeSaved() async throws {
        let fixture = ItemEditingTests()
        let (actions, runtime, folder) = try await fixture.binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        editor.begin(try await fixture.openItem("acme-1", in: folder), in: folder, actions, reload: {})
        editor.setStatus(.blocked, in: folder)
        #expect(editor.save(in: folder, actions, reload: {}) == nil)
        #expect(editor.draftState.hasChanges && editor.row(in: folder)?.validation != nil)
        #expect(!editor.begin(try await fixture.openItem("acme-2", in: folder), in: folder, actions, reload: {}))
        #expect(editor.row(in: folder)?.id == .str("acme-1"))
        #expect(!runtime.sent.contains { $0["command"] == .str("apply") })
    }

    @Test func aRefusedSaveKeepsEveryEditedField() async throws {
        let fixture = ItemEditingTests()
        let (actions, runtime, folder) = try await fixture.binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        editor.begin(try await fixture.openItem("acme-1", in: folder), in: folder, actions, reload: {})
        editor.setDetails("Keep these invented details", in: folder)
        editor.setPriority(.low, in: folder)
        runtime.answers["apply"] = { _ in #"{"ok":false,"error":"invented refusal"}"# }
        try await #require(editor.save(in: folder, actions, reload: {})).value
        #expect(editor.row(in: folder)?.details == "Keep these invented details")
        #expect(editor.row(in: folder)?.priority == .low && editor.draftState.hasChanges)
        #expect(actions.message != nil)
    }
}

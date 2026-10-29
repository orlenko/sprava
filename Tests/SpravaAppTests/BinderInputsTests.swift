import BinderFormat
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
@testable import SpravaApp
import Testing

@MainActor
@Suite struct BinderInputsTests {
    @Test(arguments: [false, true])
    func localCaptureStaysAvailableWithOrWithoutAProviderModel(provider: Bool) async throws {
        let (actions, runtime, folder) = try await ItemEditingTests().binder()
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        let note = BinderNote(client: runtime.client, support: try temporaryFolder())
        note.show(folder)
        note.text = "Record an invented board action"
        let conversation = provider ? ClaudeBinderConversation(client: runtime.client) : nil
        let view = NowView(row: row, today: CalendarDate.today(), page: row.teka.nowPage(today: CalendarDate.today()),
                           reload: {}, note: note, editor: ItemEditor(), conversation: conversation, actions: actions)
        let inputs = view.inputs
        let local = try #require(inputs.note)
        #expect(local.note === note && local.row.folder == folder)
        #expect(local.note.text == "Record an invented board action")
        #expect((inputs.conversation != nil) == provider)
        #expect(runtime.sent.isEmpty)
    }

    @Test func anUnmanagedFolderDoesNotOfferLocalWrites() throws {
        let folder = try temporaryFolder()
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        let view = NowView(row: row, today: CalendarDate.today(), page: row.teka.nowPage(today: CalendarDate.today()),
                           reload: {}, note: BinderNote(client: StandInRuntime().client, support: try temporaryFolder()),
                           editor: ItemEditor())
        #expect(view.inputs.note == nil)
    }
}

/// "Tell this binder" invited a question, and the note box filed it as a to-do (2026-10-28). The box says what it
/// does; with the binder connected, the conversation is the input and the box stays reachable without hiding a draft.
@MainActor
@Suite struct BinderInputLabelTests {
    @Test func theToDoBoxSaysItAddsToDos() {
        #expect(NoteBox.placeholder.hasPrefix("Add to-dos"))
        #expect(!NoteBox.placeholder.contains("Tell this binder"))
    }

    @Test func theToDoBoxBesideAConversationNeverHidesADraftOrAMessage() throws {
        let note = BinderNote(client: StandInRuntime().client, support: try temporaryFolder())
        #expect(!note.directShown)
        note.text = "Call the invented plumber"
        #expect(note.directShown)
        note.text = ""
        #expect(!note.directShown)
        note.directOpen = true
        #expect(note.directShown)
    }

    @Test func besideAConversationTheBoxLeavesCommandReturnToSend() throws {
        let folder = try temporaryFolder()
        let row = ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))
        let box = NoteBox(note: BinderNote(client: StandInRuntime().client, support: try temporaryFolder()), row: row,
                          sharesName: false, added: {})
        #expect(!box.talking && box.besideConversation().talking)
        #expect(box.besideConversation().caption.contains("without Claude"))
        #expect(box.caption.contains("connect it to Claude"))
    }
}

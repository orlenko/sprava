import AppKit
import BinderFormat
import Foundation
import Shelf
import SpravaKit
import SwiftUI
import Testing
@testable import SpravaApp

@MainActor @Suite(.serialized) struct PlainTodoControlsTests {
    func entry(_ item: Item, folder: URL) -> TodoBoard.Entry {
        .init(binder: "Instrument workshop", folder: folder, item: item, bucket: .later, writable: true)
    }
    @Test func globalEditWritesFieldsThroughTheOpLogAndKeepsUndo() async throws {
        let f = ItemEditingTests(), (_, runtime, folder) = try await f.binder()
        let model = TodoModel(client: runtime.client), editor = ItemEditor()
        let item = try await f.openItem("acme-1", in: folder)
        await model.edit(entry(item, folder: folder), editor: editor)
        editor.setDue(nil, in: folder); editor.setPriority(.high, in: folder)
        editor.setDetails("Bring the spare bow.\n  Check café 🎵 notes.", in: folder)
        let writer = model.actions(for: folder)
        try await #require(editor.save(in: folder, writer, reload: {})).value
        let saved = try await f.openItem("acme-1", in: folder)
        #expect(saved.due == nil && saved.priority == .high && saved.object?["details"] == .str("Bring the spare bow.\n  Check café 🎵 notes."))
        #expect(try await f.lastOp(in: folder)["op"] == .str("update_item"))
        await writer.loadReview(folder)
        let change = try #require(writer.history.first)
        #expect(change.undoable)
        await writer.undo(change, folder, reload: {}).value
        let restored = try await f.openItem("acme-1", in: folder)
        #expect(restored.due == item.due && restored.priority == item.priority && restored.object?["details"] == item.object?["details"])
        #expect(runtime.sent.allSatisfy { ["binder_settings", "proposals", "history", "apply", "undo"].contains($0["command"]?.stringValue ?? "") })
    }
    @Test func globalCancelAndProjectCancelUseTheSameUndoableDropOperation() async throws {
        for global in [true, false] {
            let f = ItemEditingTests(), (actions, runtime, folder) = try await f.binder()
            let item = try await f.openItem("acme-1", in: folder)
            if global {
                let model = TodoModel(client: runtime.client)
                await model.cancel(entry(item, folder: folder), reload: {})
                #expect(model.lastChange?.line == "Cancelled: " + item.title)
                await model.undo(reload: {})
            } else {
                await actions.load(folder, adopted: true)
                let row = ItemRow(item: item, bucket: .later, actions: actions, editor: ItemEditor(), folder: folder, editable: true, reload: {})
                row.close("drop")
                for _ in 0..<200 where actions.busy { try await Task.sleep(for: .milliseconds(5)) }
                #expect(await f.shown("acme-1", in: folder) == nil)
                #expect(try await f.lastOp(in: folder)["op"] == .str("drop"))
                await actions.loadReview(folder)
                await actions.undo(try #require(actions.history.first), folder, reload: {}).value
            }
            #expect(await f.page(folder).items.values.joined().contains { $0.title == item.title })
            #expect(runtime.sent.contains { $0["command"] == .str("apply") && $0["op"] == .str("drop") })
        }
    }
    @Test func directAddFromEitherSurfaceIsAModelFreeWriteWithDescriptionAndUndo() async throws {
        for project in [false, true] {
            let f = ItemEditingTests(), (_, runtime, folder) = try await f.binder()
            let model = TodoModel(client: runtime.client), target = TodoModel.Target(folder: folder, label: "Instrument workshop")
            if project { _ = DirectTodoSection(model: model, target: target, reload: {}).body }
            else { _ = QuickAdd(model: model, targets: [target], contexts: [], reload: {}).body }
            model.draft = "Tune the cello"; model.details = "Use the spare strings."; model.priority = .low
            await model.add(to: target, reload: {})
            let added = try #require(await f.page(folder).items.values.joined().first { $0.title == "Tune the cello" })
            #expect(added.object?["details"] == .str("Use the spare strings.") && added.priority == .low && added.due == nil)
            #expect(try await f.lastOp(in: folder)["op"] == .str("add_item"))
            await model.undo(reload: {})
            #expect(!((await f.page(folder)).items.values.joined().contains { $0.title == "Tune the cello" }))
            #expect(runtime.sent.allSatisfy { ["apply", "undo"].contains($0["command"]?.stringValue ?? "") })
        }
    }
    @Test func completeFromTheBoardSavesAnOpenProjectDraftAndARefusalKeepsIt() async throws {
        let f = ItemEditingTests(), (actions, runtime, folder) = try await f.binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor(), model = TodoModel(client: runtime.client)
        let item = try await f.openItem("acme-1", in: folder)
        editor.begin(item, in: folder, actions, reload: {})
        editor.setDetails("Keep this unsaved description", in: folder)
        let apply = runtime.answers["apply"]
        runtime.answers["apply"] = { _ in #"{"ok":false,"error":"Invented refusal"}"# }
        await model.complete(entry(item, folder: folder), editor: editor, reload: {})
        #expect(editor.row(in: folder)?.details == "Keep this unsaved description" && editor.draftState.hasChanges)
        runtime.answers["apply"] = apply
        await model.complete(entry(item, folder: folder), editor: editor, reload: {})
        let stillOpen = await f.shown("acme-1", in: folder)
        #expect(editor.row(in: folder) == nil && stillOpen == nil)
        let applies = runtime.sent.filter { $0["command"] == .str("apply") }
        #expect(applies.suffix(2).map { $0["op"] } == [.str("edit_item"), .str("complete")])
    }
    @Test func aDifferentEditorOpenedWhileLoadingCannotBeClosedByTheEarlierClick() async throws {
        let f = ItemEditingTests(), (actions, runtime, folder) = try await f.binder()
        await actions.load(folder, adopted: true)
        let first = try await f.openItem("acme-1", in: folder), second = try await f.openItem("acme-2", in: folder)
        let editor = ItemEditor(), model = TodoModel(client: runtime.client)
        editor.begin(first, in: folder, actions, reload: {})
        let settings = try #require(runtime.answers["binder_settings"])
        let (gate, resume) = AsyncStream<Void>.makeStream()
        runtime.answers["binder_settings"] = { request in
            for await _ in gate { break }
            return await settings(request)
        }
        let before = runtime.sent.count
        let closing = Task { await model.complete(entry(first, folder: folder), editor: editor, reload: {}) }
        for _ in 0..<200 where !runtime.sent.dropFirst(before).contains(where: { $0["command"] == .str("binder_settings") }) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(editor.cancel(in: folder))
        editor.begin(second, in: folder, actions, reload: {})
        editor.setDetails("Keep the second task's edits", in: folder)
        resume.yield(); await closing.value
        #expect(editor.row(in: folder)?.id == .str("acme-2") && editor.row(in: folder)?.details == "Keep the second task's edits")
        #expect(!runtime.sent.contains { $0["command"] == .str("apply") } && model.message != nil)
    }
    @Test func perBinderAddDraftsAndEditedRowsKeepCloseProtectionAndDoNotMix() async {
        let models = BinderTodoModels(), a = URL(fileURLWithPath: "/invented/workshop"), b = URL(fileURLWithPath: "/invented/garden")
        models.model(for: a).draft = "Tune cello"; models.model(for: a).details = "Use spare strings"
        models.model(for: b).draft = "Plant herbs"
        #expect(models.model(for: a).draft == "Tune cello" && models.model(for: b).details.isEmpty && models.draftState.hasChanges)
        let registry = DraftRegistry(); registry.track(models)
        var asked = false
        let guarder = DraftGuard(registry: registry, confirm: { _, _ in asked = true; return false })
        #expect(!guarder.permits(.close) && asked)
        let runtime = StandInRuntime(), model = TodoModel(client: runtime.client)
        model.draft = "Keep this title"; model.details = "Keep this description"
        await model.add(to: .init(folder: a, label: "Workshop"), reload: {})
        #expect(model.draft == "Keep this title" && model.details == "Keep this description" && model.draftState.hasChanges)
    }
}

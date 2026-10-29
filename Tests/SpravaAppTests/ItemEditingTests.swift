import BinderFormat
import BinderStore
import Foundation
import Services
import Shelf
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

/// Editing, completing and dropping an item in place on the binder's page: each is one op through the runtime's
/// command path, the page read back from the binder shows the result, and each can be undone from Recent changes.
/// The stand-in runtime hands the requests to the real command table over an invented binder.
@MainActor
@Suite struct ItemEditingTests {
    /// An adopted binder with two invented items, and a page model whose runtime is the real command table. The
    /// commands run off the main actor, as the runtime's do, so their disk flushes never stall the other suites.
    func binder() async throws -> (BinderActions, StandInRuntime, URL) {
        let folder = try makeTeka(fixture: "sprava-v0", folderName: "acme-books") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            guard case .object(var catalog) = try JSONParser.parse(Data(contentsOf: url)).value else { return }
            catalog.set("open_items", .array([
                .obj([("id", .str("acme-1")), ("title", .str("Send the Acme invoice")), ("status", .str("open")),
                      ("priority", .str("normal")), ("due", .str("2026-12-20"))]),
                .obj([("id", .str("acme-2")), ("title", .str("Call the Acme accountant")), ("status", .str("open")),
                      ("priority", .str("normal")), ("no_deadline", .bool(true))]),
            ]))
            try Data(JSONWriter.compact(.object(catalog)).utf8).write(to: url)
        }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-edit-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "invented-mac")
        let adopt = JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))]))
        let adopted = try JSONParser.parse(await Task.detached { commands.handle(adopt) }.value).value
        #expect(adopted["ok"] == .bool(true))
        let runtime = StandInRuntime()
        for name in ["apply", "undo", "history", "proposals", "binder_settings"] {
            runtime.answers[name] = { request in
                let text = JSONWriter.compact(request)
                return await Task.detached { commands.handle(text) }.value
            }
        }
        return (BinderActions(client: runtime.client), runtime, folder)
    }

    /// The page as the binder now reads, read off the main actor like the Shelf's.
    func page(_ folder: URL) async -> NowPage {
        await Task.detached { Teka.read(folder).nowPage(today: CalendarDate.today()) }.value
    }

    /// The bucket and item with this id, if open.
    func shown(_ id: String, in folder: URL) async -> (bucket: Bucket, item: Item)? {
        for (bucket, items) in await page(folder).items {
            if let item = items.first(where: { $0.object?["id"] == .str(id) }) { return (bucket, item) }
        }
        return nil
    }

    func lastOp(in folder: URL) async throws -> JSONValue {
        let text = try await Task.detached {
            try String(contentsOf: folder.appendingPathComponent(".sprava/ops.ndjson"), encoding: .utf8)
        }.value
        let line = try #require(text.split(separator: "\n").last)
        return try JSONParser.parse(Data(line.utf8)).value
    }

    func openItem(_ id: String, in folder: URL) async throws -> Item { try #require(await shown(id, in: folder)).item }

    func applies(_ runtime: StandInRuntime) -> Int { runtime.sent.filter { $0["command"] == .str("apply") }.count }

    @Test func anOpenEditMustBeSettledBeforeRemovingItsBinder() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let support = try temporaryFolder()
        try ShelfStore(supportDirectory: support).add(folder)
        let shelf = ShelfModel(support: support, client: runtime.client)
        let firstWindow = ShelfView(model: shelf)
        let secondWindow = ShelfView(model: shelf)
        let editor = firstWindow.itemEditor
        #expect(editor === secondWindow.itemEditor)
        let item = try await openItem("acme-1", in: folder)
        #expect(editor.begin(item, in: folder, actions, reload: {}))
        editor.setTitle("Send the Acme invoice by post", in: folder)
        await shelf.refreshAndWait()
        let row = try #require(shelf.rows.first)
        runtime.answers["shelf_remove"] = { _ in
            // A new draft cannot start while the removal is awaiting its runtime answer.
            #expect(!editor.begin(item, in: folder, actions, reload: {}))
            try? ShelfStore(supportDirectory: support).remove(folder)
            return #"{"ok":true}"#
        }
        // Removal from a second window must also respect the first window's draft.
        await shelf.removeFromShelf(row)
        #expect(!runtime.sent.contains { $0["command"] == .str("shelf_remove") })
        #expect(shelf.rows.contains { $0.folder == folder })
        #expect(shelf.selection == folder)
        #expect(editor.row(in: folder)?.title == "Send the Acme invoice by post")
        #expect(shelf.note == "Save or cancel this binder's open edit before removing it from the Shelf.")
        secondWindow.itemEditor.cancel(in: folder)
        await shelf.removeFromShelf(row)
        #expect(runtime.sent.filter { $0["command"] == .str("shelf_remove") }.count == 1)
        #expect(!shelf.rows.contains { $0.folder == folder })
    }

    @Test func editingTheTitleAndDueWritesOneUpdateItemAndThePageShowsIt() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        #expect(editor.begin(try await openItem("acme-1", in: folder), in: folder, actions, reload: {}))
        #expect(editor.row(in: folder)?.title == "Send the Acme invoice")
        #expect(editor.row(in: folder)?.due == CalendarDate(year: 2026, month: 12, day: 20))

        editor.setTitle("  Send the Acme invoice by email ", in: folder)
        editor.setDue(CalendarDate(year: 2026, month: 12, day: 22), in: folder)
        try await #require(editor.save(in: folder, actions, reload: {})).value
        #expect(actions.message == nil && editor.row(in: folder) == nil)
        let op = try await lastOp(in: folder)
        #expect(op["op"] == .str("update_item") && op["actor"]?["kind"] == .str("user"))
        #expect(op["args"] == .obj([("id", .str("acme-1")),
                                    ("set", .obj([("title", .str("Send the Acme invoice by email")), ("due", .str("2026-12-22"))]))]))
        let edited = try await openItem("acme-1", in: folder)
        #expect(edited.title == "Send the Acme invoice by email" && edited.due == CalendarDate(year: 2026, month: 12, day: 22))

        // "No date" replaces the due date with no_deadline, so the item keeps exactly one (binder-v0 §4.4).
        editor.begin(edited, in: folder, actions, reload: {})
        editor.setDue(nil, in: folder)
        try await #require(editor.save(in: folder, actions, reload: {})).value
        #expect(try await lastOp(in: folder)["args"] == .obj([("id", .str("acme-1")), ("set", .obj([("no_deadline", .bool(true))])),
                                                              ("unset", .array([.str("due")]))]))
        #expect(await shown("acme-1", in: folder)?.bucket == .noDeadline)

        // A date on an item without one removes its no_deadline.
        editor.begin(try await openItem("acme-2", in: folder), in: folder, actions, reload: {})
        #expect(editor.row(in: folder)?.due == nil)
        editor.setDue(CalendarDate(year: 2026, month: 12, day: 1), in: folder)
        try await #require(editor.save(in: folder, actions, reload: {})).value
        #expect(try await lastOp(in: folder)["args"] == .obj([("id", .str("acme-2")), ("set", .obj([("due", .str("2026-12-01"))])),
                                                              ("unset", .array([.str("no_deadline")]))]))
        #expect(try await openItem("acme-2", in: folder).object?["no_deadline"] == nil)

        // Nothing changed, or only an emptied title: the row closes and no op is sent.
        let sent = applies(runtime)
        editor.begin(try await openItem("acme-2", in: folder), in: folder, actions, reload: {})
        editor.setTitle("   ", in: folder)
        #expect(editor.save(in: folder, actions, reload: {}) == nil)
        #expect(editor.row(in: folder) == nil && applies(runtime) == sent)

        // A wrong edit is undone from Recent changes.
        await actions.loadReview(folder)
        let change = try #require(actions.history.first)
        #expect(change.undoable)
        await actions.undo(change, folder, reload: {}).value
        #expect(actions.message == nil)
        #expect(try await openItem("acme-2", in: folder).object?["no_deadline"] == .bool(true))
        #expect(try await openItem("acme-2", in: folder).due == nil)
    }

    @Test func undoingAnOlderEditKeepsALaterChangeAndSaysSo() async throws {
        let (actions, _, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        editor.begin(try await openItem("acme-1", in: folder), in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by email", in: folder)
        editor.setDue(CalendarDate(year: 2026, month: 12, day: 22), in: folder)
        try await #require(editor.save(in: folder, actions, reload: {})).value
        editor.begin(try await openItem("acme-1", in: folder), in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by post", in: folder)
        try await #require(editor.save(in: folder, actions, reload: {})).value

        await actions.loadReview(folder)
        let older = try #require(actions.history.dropFirst().first)
        await actions.undo(older, folder, reload: {}).value
        #expect(actions.message == "Undone. Your later change to the title was kept.")
        let item = try await openItem("acme-1", in: folder)
        #expect(item.title == "Send the Acme invoice by post")
        #expect(item.due == CalendarDate(year: 2026, month: 12, day: 20))
        #expect(BinderActions.keptNote(["due", "waiting_on", "title"]) == "Undone. Your later change to the due date, who it waits on and title was kept.")
        #expect(BinderActions.keptNote([]) == nil)
    }

    @Test func aRefusedEditKeepsTheRowOpenWithWhatWasTyped() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        editor.begin(try await openItem("acme-1", in: folder), in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice twice", in: folder)
        runtime.answers["apply"] = { _ in #"{"ok":false,"error":"the binder needs a repair first"}"# }
        try await #require(editor.save(in: folder, actions, reload: {})).value
        #expect(actions.message == "the binder needs a repair first")
        #expect(editor.row(in: folder)?.title == "Send the Acme invoice twice")
        #expect(editor.isEditing(try await openItem("acme-1", in: folder), in: folder))
        #expect(try await openItem("acme-1", in: folder).title == "Send the Acme invoice")
    }

    @Test func openingAnotherRowSavesTheOneOpenAndNothingTypedIsKeptElsewhere() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let invoice = try await openItem("acme-1", in: folder)
        let call = try await openItem("acme-2", in: folder)
        let editor = ItemEditor()
        editor.begin(invoice, in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by post", in: folder)
        // Edit chosen again on the open row changes nothing typed.
        editor.begin(invoice, in: folder, actions, reload: {})
        #expect(editor.row(in: folder)?.title == "Send the Acme invoice by post")

        // Clicking away is saving, as an inline edit on the Mac is; when the runtime refuses, nothing moves.
        let applied = try #require(runtime.answers["apply"])
        runtime.answers["apply"] = { _ in #"{"ok":false,"error":"the binder needs a repair first"}"# }
        #expect(editor.begin(call, in: folder, actions, reload: {}))
        while !actions.busy && actions.message == nil { try await Task.sleep(for: .milliseconds(5)) }
        while actions.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(actions.message == "the binder needs a repair first")
        #expect(editor.isEditing(invoice, in: folder) && editor.row(in: folder)?.title == "Send the Acme invoice by post")

        runtime.answers["apply"] = applied
        #expect(editor.begin(call, in: folder, actions, reload: {}))
        while actions.busy || editor.isEditing(invoice, in: folder) { try await Task.sleep(for: .milliseconds(5)) }
        #expect(editor.isEditing(call, in: folder) && editor.row(in: folder)?.title == "Call the Acme accountant")
        #expect(try await openItem("acme-1", in: folder).title == "Send the Acme invoice by post")

        // Cancel drops what was typed: nothing of it comes back.
        editor.setTitle("Call the Acme accountant on Monday", in: folder)
        let sent = applies(runtime)
        editor.cancel(in: folder)
        editor.begin(call, in: folder, actions, reload: {})
        #expect(editor.row(in: folder)?.title == "Call the Acme accountant" && applies(runtime) == sent)
    }

    /// Waits for work the editor starts after a save (the completion that follows it), at most a few seconds.
    func settle(_ editor: ItemEditor, _ actions: BinderActions, _ done: () -> Bool) async {
        for _ in 0..<300 where !done() || actions.busy || !editor.saving.isEmpty {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The circle and Mark Done work on the open row too (2026-10-28: "I cannot click these… not if it's expanded"):
    /// what was typed is saved first, then the item is completed, so nothing typed is lost.
    @Test func markingTheOpenRowDoneSavesWhatWasTypedFirst() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        let invoice = try await openItem("acme-1", in: folder)
        let row = ItemRow(item: invoice, bucket: .later, actions: actions, editor: editor, folder: folder, editable: true, reload: {})
        editor.begin(invoice, in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by post", in: folder)
        #expect(row.editing && !row.closable)
        row.close("complete")
        await settle(editor, actions) { applies(runtime) == 2 }
        #expect(actions.message == nil && editor.row(in: folder) == nil)
        let ops = runtime.sent.filter { $0["command"] == .str("apply") }.map { $0["op"] }
        #expect(ops == [.str("edit_item"), .str("complete")])
        #expect(await shown("acme-1", in: folder) == nil)
        #expect(await page(folder).closed.contains { $0.title == "Send the Acme invoice by post" && $0.action == "done" })
    }

    /// Showing another binder while the save is on its way must not drop the completion that follows it.
    @Test func aCompletionAfterASaveSurvivesShowingAnotherBinder() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let applied = try #require(runtime.answers["apply"])
        let (gate, open) = AsyncStream<Void>.makeStream()
        var held = true
        runtime.answers["apply"] = { request in
            if held { held = false; for await _ in gate { break } }
            return await applied(request)
        }
        let editor = ItemEditor()
        let invoice = try await openItem("acme-1", in: folder)
        editor.begin(invoice, in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by post", in: folder)
        let save = try #require(editor.close(as: "complete", in: folder, actions, reload: {}))
        await actions.load(try temporaryFolder(), adopted: false)
        #expect(!actions.serves(folder))
        open.yield()
        await save.value
        await settle(editor, actions) { applies(runtime) == 2 }
        let ops = runtime.sent.filter { $0["command"] == .str("apply") }.map { $0["op"] }
        #expect(ops == [.str("edit_item"), .str("complete")])
        #expect(editor.row(in: folder) == nil)
        #expect(await page(folder).closed.contains { $0.title == "Send the Acme invoice by post" && $0.action == "done" })
    }

    /// Delete sits in the open row (2026-10-28: "There's no way to delete something that I mistakenly added").
    @Test func deletingTheOpenRowDropsTheItemAndWhatWasTyped() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        let call = try await openItem("acme-2", in: folder)
        editor.begin(call, in: folder, actions, reload: {})
        editor.setTitle("Call the Acme accountant on Monday", in: folder)
        try await #require(editor.close(as: "drop", in: folder, actions, reload: {})).value
        #expect(actions.message == nil && editor.row(in: folder) == nil && editor.saving.isEmpty)
        #expect(applies(runtime) == 1)
        #expect(try await lastOp(in: folder)["op"] == .str("drop"))
        #expect(await page(folder).closed.contains { $0.title == "Call the Acme accountant" && $0.action == "dropped" })
    }

    @Test func aRefusedDeleteKeepsTheOpenRowAndItsText() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        runtime.answers["apply"] = { _ in #"{"ok":false,"error":"the binder needs a repair first"}"# }
        let editor = ItemEditor()
        let call = try await openItem("acme-2", in: folder)
        editor.begin(call, in: folder, actions, reload: {})
        editor.setTitle("Call the Acme accountant on Monday", in: folder)
        try await #require(editor.close(as: "drop", in: folder, actions, reload: {})).value
        #expect(actions.message != nil && editor.saving.isEmpty)
        #expect(editor.row(in: folder)?.title == "Call the Acme accountant on Monday")
        #expect(await shown("acme-2", in: folder) != nil)
    }

    @Test func anInvalidOpenRowIsNotMarkedDone() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        let invoice = try await openItem("acme-1", in: folder)
        editor.begin(invoice, in: folder, actions, reload: {})
        // Waiting needs whom and until when; the row says so and keeps what was typed.
        editor.setStatus(.waiting, in: folder)
        #expect(editor.close(as: "complete", in: folder, actions, reload: {}) == nil)
        #expect(applies(runtime) == 0 && actions.message != nil && editor.row(in: folder)?.status == .waiting)
    }

    @Test func aRowIsLockedWhileItsChangeIsOnItsWay() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let applied = try #require(runtime.answers["apply"])
        // The runtime answers the change only when the test lets it.
        let (gate, open) = AsyncStream<Void>.makeStream()
        runtime.answers["apply"] = { request in
            for await _ in gate { break }
            return await applied(request)
        }
        let editor = ItemEditor()
        let invoice = try await openItem("acme-1", in: folder)
        editor.begin(invoice, in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by email", in: folder)
        let save = try #require(editor.save(in: folder, actions, reload: {}))
        #expect(!editor.saving.isEmpty)
        // Nothing typed now could reach the binder, so nothing can be typed, and the row cannot close or move.
        #expect(!editor.setTitle("Send the Acme invoice by email today", in: folder))
        #expect(!editor.setDue(nil, in: folder))
        #expect(!editor.cancel(in: folder))
        #expect(!editor.begin(try await openItem("acme-2", in: folder), in: folder, actions, reload: {}))
        #expect(editor.save(in: folder, actions, reload: {}) == nil)
        #expect(editor.row(in: folder)?.title == "Send the Acme invoice by email")

        open.yield()
        await save.value
        #expect(editor.saving.isEmpty && editor.row(in: folder) == nil && actions.message == nil)
        #expect(try await openItem("acme-1", in: folder).title == "Send the Acme invoice by email")
        #expect(applies(runtime) == 1)
    }

    @Test func completingAndDroppingCloseTheItemAndCanBeUndone() async throws {
        let (actions, _, folder) = try await binder()
        await actions.load(folder, adopted: true)
        for (id, op, action) in [("acme-1", "complete", "done"), ("acme-2", "drop", "dropped")] {
            let item = try await openItem(id, in: folder)
            try await #require(actions.close(item, as: op, folder, reload: {})).value
            #expect(actions.message == nil)
            #expect(try await lastOp(in: folder)["op"] == .string(op))
            #expect(await shown(id, in: folder) == nil)
            let closed = await page(folder).closed
            #expect(closed.contains { $0.title == item.title && $0.action == action })

            await actions.loadReview(folder)
            let change = try #require(actions.history.first)
            #expect(change.undoable && !change.undone)
            await actions.undo(change, folder, reload: {}).value
            #expect(actions.message == nil)
            // Reopened under a new id with the same title (binder-v0 §6.10).
            let reopened = await page(folder).items.values.joined()
                .filter { $0.title == item.title }
            #expect(reopened.count == 1 && reopened.first?.object?["id"] != .str(id))
            await actions.loadReview(folder)
            #expect(actions.history.contains { $0.id == change.id && $0.undone })
        }
    }

    @Test func anItemClosedElsewhereWhileEditedKeepsItsRowInReach() async throws {
        let (actions, _, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        let invoice = try await openItem("acme-1", in: folder)
        editor.begin(invoice, in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by post", in: folder)
        #expect(editor.stranded(in: folder, shown: await page(folder)) == nil)

        // Checked off elsewhere (another window, or the hub's outbox) while the person types.
        try await #require(actions.close(invoice, as: "complete", folder, reload: {})).value
        let stranded = try #require(editor.stranded(in: folder, shown: await page(folder)))
        #expect(stranded.title == "Send the Acme invoice by post")
        _ = StrandedItemEdit(actions: actions, editor: editor, folder: folder, page: await page(folder), reload: {}).body

        // Opening another row saves the stranded one first; the runtime refuses, and the text stays in reach.
        let call = try await openItem("acme-2", in: folder)
        #expect(editor.begin(call, in: folder, actions, reload: {}))
        while actions.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(actions.message != nil && editor.row(in: folder)?.title == "Send the Acme invoice by post")
        // Cancel settles it, and the other rows open again.
        editor.cancel(in: folder)
        #expect(editor.stranded(in: folder, shown: await page(folder)) == nil)
        #expect(editor.begin(call, in: folder, actions, reload: {}) && editor.isEditing(call, in: folder))
    }

    @Test func anItemThatRepeatsIsShownReadOnly() {
        let item = Item(raw: .obj([("id", .str("acme-3")), ("title", .str("Pay the Acme retainer")), ("due", .str("2026-12-14")),
                                   ("recurrence", .obj([("freq", .str("monthly"))]))]), index: 0)
        let folder = URL(fileURLWithPath: "/Invented/acme-books", isDirectory: true)
        let editor = ItemEditor()
        let row = ItemRow(item: item, bucket: .later, actions: BinderActions(client: StandInRuntime().client), editor: editor,
                          folder: folder, editable: true, reload: {})
        #expect(!row.changeable && !row.closable)
        row.begin()
        #expect(editor.row(in: folder) == nil)
    }

    @Test func aChangeLeavesALenientDueDateAsWrittenWhenTheDayIsTheSame() {
        let item = Item(raw: .obj([("id", .int(7)), ("title", .str("Send the Acme invoice")), ("due", .str("20261220"))]), index: 0)
        #expect(ItemEditor.change(of: item, title: "Send the Acme invoice", due: CalendarDate(year: 2026, month: 12, day: 20)) == nil)
        #expect(ItemEditor.change(of: item, title: "Send the Acme reminder", due: CalendarDate(year: 2026, month: 12, day: 20))
            == JSONObject([(key: "id", value: .int(7)), (key: "set", value: .obj([("title", .str("Send the Acme reminder"))]))]))
        // A day survives the trip through the date picker in this time zone.
        for day in [CalendarDate(year: 2026, month: 3, day: 29)!, CalendarDate(year: 1500, month: 3, day: 1)!] {
            #expect(ItemEditor.day(ItemEditor.date(day)) == day)
        }
        // A title with spaces at its ends, left as it opened, is not rewritten when only the date changes.
        let spaced = Item(raw: .obj([("id", .int(8)), ("title", .str(" Send the Acme invoice ")), ("due", .str("2026-12-20"))]), index: 0)
        #expect(ItemEditor.change(of: spaced, title: " Send the Acme invoice ", due: CalendarDate(year: 2026, month: 12, day: 21))
            == JSONObject([(key: "id", value: .int(8)), (key: "set", value: .obj([("due", .str("2026-12-21"))]))]))
    }
}

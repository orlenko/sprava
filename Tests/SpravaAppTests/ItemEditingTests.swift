import BinderFormat
import BinderStore
import Foundation
import Services
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

    @Test func anOpenRowIsSavedOrCancelledBeforeItCanBeClosed() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        let invoice = try await openItem("acme-1", in: folder)
        let row = ItemRow(item: invoice, bucket: .later, actions: actions, editor: editor, folder: folder, editable: true, reload: {})
        #expect(row.closable)
        editor.begin(invoice, in: folder, actions, reload: {})
        editor.setTitle("Send the Acme invoice by post", in: folder)
        // A completion the runtime refused would otherwise have taken the typed title with it.
        #expect(!row.closable)
        row.close("complete")
        #expect(applies(runtime) == 0)
        #expect(editor.row(in: folder)?.title == "Send the Acme invoice by post")
        editor.cancel(in: folder)
        #expect(row.closable)
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
        let day = CalendarDate(year: 2026, month: 3, day: 29)!
        #expect(ItemEditor.day(ItemEditor.date(day)) == day)
    }
}

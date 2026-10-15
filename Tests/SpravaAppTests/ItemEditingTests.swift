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

    @Test func editingTheTitleAndDueWritesOneUpdateItemAndThePageShowsIt() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        #expect(editor.begin(try await openItem("acme-1", in: folder), in: folder))
        #expect(editor.title == "Send the Acme invoice" && editor.due == CalendarDate(year: 2026, month: 12, day: 20))

        editor.setTitle("  Send the Acme invoice by email ")
        editor.setDue(CalendarDate(year: 2026, month: 12, day: 22))
        try await #require(editor.save(actions, reload: {})).value
        #expect(actions.message == nil && editor.open == nil)
        let op = try await lastOp(in: folder)
        #expect(op["op"] == .str("update_item") && op["actor"]?["kind"] == .str("user"))
        #expect(op["args"] == .obj([("id", .str("acme-1")),
                                    ("set", .obj([("title", .str("Send the Acme invoice by email")), ("due", .str("2026-12-22"))]))]))
        let edited = try await openItem("acme-1", in: folder)
        #expect(edited.title == "Send the Acme invoice by email" && edited.due == CalendarDate(year: 2026, month: 12, day: 22))

        // "No date" replaces the due date with no_deadline, so the item keeps exactly one (binder-v0 §4.4).
        editor.begin(edited, in: folder)
        editor.setDue(nil)
        try await #require(editor.save(actions, reload: {})).value
        #expect(try await lastOp(in: folder)["args"] == .obj([("id", .str("acme-1")), ("set", .obj([("no_deadline", .bool(true))])),
                                                        ("unset", .array([.str("due")]))]))
        #expect(await shown("acme-1", in: folder)?.bucket == .noDeadline)

        // A date on an item without one removes its no_deadline.
        editor.begin(try await openItem("acme-2", in: folder), in: folder)
        #expect(editor.due == nil)
        editor.setDue(CalendarDate(year: 2026, month: 12, day: 1))
        try await #require(editor.save(actions, reload: {})).value
        #expect(try await lastOp(in: folder)["args"] == .obj([("id", .str("acme-2")), ("set", .obj([("due", .str("2026-12-01"))])),
                                                        ("unset", .array([.str("no_deadline")]))]))
        #expect(try await openItem("acme-2", in: folder).object?["no_deadline"] == nil)

        // Nothing changed, or only an emptied title: the row closes and no op is sent.
        let sent = runtime.sent.filter { $0["command"] == .str("apply") }.count
        editor.begin(try await openItem("acme-2", in: folder), in: folder)
        editor.setTitle("   ")
        #expect(editor.save(actions, reload: {}) == nil)
        #expect(editor.open == nil && runtime.sent.filter { $0["command"] == .str("apply") }.count == sent)

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
        editor.begin(try await openItem("acme-1", in: folder), in: folder)
        editor.setTitle("Send the Acme invoice twice")
        runtime.answers["apply"] = { _ in #"{"ok":false,"error":"the binder needs a repair first"}"# }
        try await #require(editor.save(actions, reload: {})).value
        #expect(actions.message == "the binder needs a repair first")
        #expect(editor.title == "Send the Acme invoice twice")
        #expect(editor.isEditing(try await openItem("acme-1", in: folder), in: folder))
        #expect(try await openItem("acme-1", in: folder).title == "Send the Acme invoice")
    }

    @Test func openingAnotherRowKeepsWhatWasTypedIntoTheFirst() async throws {
        let (_, _, folder) = try await binder()
        let invoice = try await openItem("acme-1", in: folder)
        let call = try await openItem("acme-2", in: folder)
        let editor = ItemEditor()
        editor.begin(invoice, in: folder)
        editor.setTitle("Send the Acme invoice by post")
        editor.setDue(nil)
        // Edit chosen again on the open row changes nothing typed.
        editor.begin(invoice, in: folder)
        #expect(editor.title == "Send the Acme invoice by post" && editor.due == nil)

        editor.begin(call, in: folder)
        #expect(editor.isEditing(call, in: folder) && editor.title == "Call the Acme accountant")
        editor.begin(invoice, in: folder)
        #expect(editor.title == "Send the Acme invoice by post" && editor.due == nil)
        // Cancel drops it for good.
        editor.cancel()
        editor.begin(invoice, in: folder)
        #expect(editor.title == "Send the Acme invoice" && editor.due == CalendarDate(year: 2026, month: 12, day: 20))
    }

    @Test func anOpenRowIsSavedOrCancelledBeforeItCanBeClosed() async throws {
        let (actions, runtime, folder) = try await binder()
        await actions.load(folder, adopted: true)
        let editor = ItemEditor()
        let invoice = try await openItem("acme-1", in: folder)
        let row = ItemRow(item: invoice, bucket: .later, actions: actions, editor: editor, folder: folder, editable: true, reload: {})
        #expect(row.closable)
        editor.begin(invoice, in: folder)
        editor.setTitle("Send the Acme invoice by post")
        // A completion the runtime refused would otherwise have taken the typed title with it.
        #expect(!row.closable)
        row.close("complete")
        #expect(!runtime.sent.contains { $0["command"] == .str("apply") })
        #expect(editor.title == "Send the Acme invoice by post")
        editor.cancel()
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
        editor.begin(invoice, in: folder)
        editor.setTitle("Send the Acme invoice by email")
        let save = try #require(editor.save(actions, reload: {}))
        #expect(editor.saving != nil)
        // Nothing typed now could reach the binder, so nothing can be typed, and the row cannot close or move.
        #expect(!editor.setTitle("Send the Acme invoice by email today"))
        #expect(!editor.setDue(nil))
        #expect(!editor.cancel())
        #expect(!editor.begin(try await openItem("acme-2", in: folder), in: folder))
        #expect(editor.save(actions, reload: {}) == nil)
        #expect(editor.title == "Send the Acme invoice by email")

        open.yield()
        await save.value
        #expect(editor.saving == nil && editor.open == nil && actions.message == nil)
        #expect(try await openItem("acme-1", in: folder).title == "Send the Acme invoice by email")
        #expect(runtime.sent.filter { $0["command"] == .str("apply") }.count == 1)
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

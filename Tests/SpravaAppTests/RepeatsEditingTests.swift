import BinderFormat
import BinderStore
import Foundation
import Services
@testable import SpravaApp
import SpravaKit
import SpravaTestSupport
import Testing

/// Repeats in the app (decisions.md F3, 2026-11-15): the editor's Repeats choice, the row's line, and a Done that moves a
/// repeating to-do to its next date with an Undo that says where. The stand-in runtime hands requests to the real
/// command table over an invented binder.
@MainActor
@Suite struct RepeatsEditingTests {
    /// Far enough ahead that a Done always counts from the due date, not today.
    let due = CalendarDate(year: 2030, month: 3, day: 15)!

    func binder(files: [String: String] = [:]) async throws -> (BinderActions, StandInRuntime, URL) {
        let day = due.description
        let folder = try makeTeka(fixture: "sprava-v0", folderName: "acme-rent") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            guard case .object(var catalog) = try JSONParser.parse(Data(contentsOf: url)).value else { return }
            catalog.set("open_items", .array([
                .obj([("id", .str("rent-1")), ("title", .str("Pay the invented rent")), ("status", .str("open")),
                      ("priority", .str("normal")), ("due", .string(day))]),
            ]))
            try Data(JSONWriter.compact(.object(catalog)).utf8).write(to: url)
            for (name, text) in files { try Data(text.utf8).write(to: folder.appendingPathComponent(name)) }
        }
        let commands = Commands(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-repeat-\(UUID().uuidString)"),
                                deviceID: "invented-mac")
        let adopt = JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))]))
        #expect(try JSONParser.parse(await Task.detached { commands.handle(adopt) }.value).value["ok"] == .bool(true))
        let runtime = StandInRuntime()
        for name in ["apply", "undo", "history", "proposals", "binder_settings"] {
            runtime.answers[name] = { request in
                let text = JSONWriter.compact(request)
                return await Task.detached { commands.handle(text) }.value
            }
        }
        let actions = BinderActions(client: runtime.client)
        await actions.load(folder, adopted: true)
        return (actions, runtime, folder)
    }

    func item(in folder: URL) async throws -> Item {
        let page = await Task.detached { Teka.read(folder).nowPage(today: CalendarDate.today()) }.value
        return try #require(page.items.values.joined().first { $0.object?["id"] == .str("rent-1") })
    }

    func settle(_ actions: BinderActions) async throws {
        while actions.busy { try await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func monthlyOnTheFifteenthMovesOnAtDoneAndUndoBringsItBack() async throws {
        let (actions, _, folder) = try await binder()
        #expect(actions.repeatsOff == nil && ItemEditFields.repeatsOff(actions) == nil)
        let editor = ItemEditor()
        #expect(editor.begin(try await item(in: folder), in: folder, actions, reload: {}))
        // The menu offers monthly and yearly from the due date.
        let row = try #require(editor.row(in: folder))
        #expect(row.repeatOptions(offersNew: true).map(\.0) == ["Never", "Monthly on the 15th", "Yearly on March 15"])
        editor.setRepeat(.monthly, in: folder)
        #expect(editor.row(in: folder)?.change?["set"]?["recurrence"] == Recurrence.Rule.monthly(day: 15).json)
        editor.save(in: folder, actions, reload: {})
        try await settle(actions)
        #expect(actions.message == nil, "\(actions.message ?? "")")
        let repeating = try await item(in: folder)
        #expect(TodoLine.secondLine(repeating, bucket: .later) == "repeats monthly on the 15th")

        // Done moves it to April 15 and says so, with an Undo.
        actions.close(repeating, as: "complete", folder, reload: {})
        try await settle(actions)
        #expect(actions.message == nil, "\(actions.message ?? "")")
        #expect(try await item(in: folder).due == CalendarDate(year: 2030, month: 4, day: 15))
        let next = RepeatWords.next(CalendarDate(year: 2030, month: 4, day: 15)!, today: .today())
        #expect(actions.moved?.line == "Done: Pay the invented rent. " + next)
        actions.undoMoved(folder, reload: {})
        try await settle(actions)
        #expect(actions.moved == nil && actions.message == nil)
        #expect(try await item(in: folder).due == due)
    }

    @Test func aDoneAfterChangingTheDateNamesTheDateJustSaved() async throws {
        let (actions, _, folder) = try await binder()
        let editor = ItemEditor()
        editor.begin(try await item(in: folder), in: folder, actions, reload: {})
        editor.setRepeat(.monthly, in: folder)
        editor.save(in: folder, actions, reload: {})
        try await settle(actions)
        editor.begin(try await item(in: folder), in: folder, actions, reload: {})
        // The item keeps its own repeat when only its date changes.
        editor.setDue(CalendarDate(year: 2030, month: 3, day: 20), in: folder)
        #expect(editor.row(in: folder)?.recurrence == .monthly(day: 15))
        editor.close(as: "complete", in: folder, actions, reload: {})
        while editor.saving.contains(folder.standardizedFileURL) || actions.busy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(actions.message == nil, "\(actions.message ?? "")")
        #expect(try await item(in: folder).due == CalendarDate(year: 2030, month: 4, day: 15))
    }

    @Test func whereLifeprojCanReachTheBinderRepeatsAreOffBeforeThePersonTries() async throws {
        let (actions, _, folder) = try await binder(files: ["catalog_check.py": "# invented checker\n"])
        let off = try #require(actions.repeatsOff)
        #expect(off.contains("catalog_check.py") && ItemEditFields.repeatsOff(actions) == off)
        let editor = ItemEditor()
        editor.begin(try await item(in: folder), in: folder, actions, reload: {})
        // Only Never is offered on a to-do that does not repeat, so nothing is refused after the person chose it.
        #expect(try #require(editor.row(in: folder)).repeatOptions(offersNew: false).map(\.0) == ["Never"])
        // Until the settings are read, nothing is offered either.
        #expect(ItemEditFields.repeatsOff(BinderActions(client: StandInRuntime().client)) != nil)
    }

    @Test func aRepeatChosenInTheRowFollowsItsDateAndNeedsOne() {
        let item = Item(raw: .obj([("id", .str("rent-2")), ("title", .str("Renew the invented permit")), ("due", .str("2030-07-30"))]), index: 0)
        let folder = URL(fileURLWithPath: "/Invented/permits", isDirectory: true)
        let editor = ItemEditor()
        editor.begin(item, in: folder, BinderActions(client: StandInRuntime().client), reload: {})
        editor.setRepeat(.yearly, in: folder)
        #expect(editor.row(in: folder)?.recurrence == .yearly(month: 7, day: 30))
        editor.setDue(CalendarDate(year: 2030, month: 8, day: 2), in: folder)
        #expect(editor.row(in: folder)?.recurrence == .yearly(month: 8, day: 2))
        #expect(editor.row(in: folder)?.repeatOptions(offersNew: true).map(\.0) == ["Never", "Monthly on the 2nd", "Yearly on August 2"])
        editor.setDue(nil, in: folder)
        #expect(editor.row(in: folder)?.validation?.contains("needs a due date") == true)
        editor.setRepeat(.never, in: folder)
        #expect(editor.row(in: folder)?.validation == nil && editor.row(in: folder)?.change?["set"]?["recurrence"] == nil)
    }

    @Test func theWordsOfARepeat() {
        #expect([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 31].map(RepeatWords.ordinal)
            == ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "31st"])
        #expect(RepeatWords.line(.yearly(month: 7, day: 30)) == "repeats yearly on July 30")
        let today = CalendarDate(year: 2026, month: 11, day: 15)!
        #expect(RepeatWords.next(CalendarDate(year: 2026, month: 12, day: 15)!, today: today) == "Next: December 15.")
        #expect(RepeatWords.next(CalendarDate(year: 2027, month: 1, day: 15)!, today: today) == "Next: January 15, 2027.")
        #expect(TodoModel.closedLine("complete", "Pay the invented rent", reply: JSONObject([(key: "next_due", value: .str("2026-12-15"))]), today: today)
            == "Done: Pay the invented rent. Next: December 15.")
        #expect(TodoModel.closedLine("complete", "Pay the invented rent", reply: JSONObject(), today: today) == "Done: Pay the invented rent")
        // The Done a repeating to-do sends names its date; a one-off's does not.
        let repeating = Item(raw: .obj([("id", .str("r")), ("due", .str("2026-11-15")), ("recurrence", Recurrence.Rule.monthly(day: 15).json)]), index: 0)
        #expect(repeating.closeArgs("complete", at: "2026-11-15T10:00:00Z")?["occurrence_due"] == .str("2026-11-15"))
        #expect(repeating.closeArgs("drop", at: "2026-11-15T10:00:00Z")?["occurrence_due"] == nil)
        let once = Item(raw: .obj([("id", .str("o")), ("due", .str("2026-11-15"))]), index: 0)
        #expect(once.closeArgs("complete", at: "2026-11-15T10:00:00Z")?["occurrence_due"] == nil)
    }
}

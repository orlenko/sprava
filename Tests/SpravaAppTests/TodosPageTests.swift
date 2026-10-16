import BinderFormat
import Foundation
@testable import SpravaApp
import SpravaKit
import Testing

/// The To-dos page: every binder's open items in one board, grouped against a fixed today, counted, searched and
/// merged in the order of binder-v0 §5.2; and its changes, sent as the binder page sends them. Invented data only.
@MainActor
@Suite struct TodosPageTests {
    let today = CalendarDate(year: 2026, month: 10, day: 15)!
    let acme = URL(fileURLWithPath: "/Invented/acme", isDirectory: true)
    let harbor = URL(fileURLWithPath: "/Invented/harbor", isDirectory: true)

    func items(_ json: String) throws -> [Item] {
        try JSONParser.parse(json).value.arrayValue!.enumerated().map { Item(raw: $0.element, index: $0.offset) }
    }

    func source(_ name: String, _ folder: URL, writable: Bool = true, _ json: String) throws -> TodoBoard.Source {
        TodoBoard.Source(name: name, folder: folder, writable: writable,
                         page: NowPage(items: try items(json), log: [], today: today, timeZone: .current))
    }

    func board() throws -> TodoBoard {
        let a = try source("acme", acme, """
        [{"id":"acme-2026-001","title":"Send the Acme invoice","status":"open","priority":"normal","due":"2026-10-12"},
         {"id":"acme-2026-002","title":"Call the Acme accountant","status":"open","priority":"high","due":"2026-10-15","contexts":["@calls"],"tags":["tax"]},
         {"id":"acme-2026-003","title":"File the Acme return","status":"open","priority":"normal","due":"2026-10-20"},
         {"id":"acme-2026-004","title":"Wait for the Acme receipt","status":"waiting","priority":"normal","due":"2026-10-01",
          "waiting_on":"Acme office","follow_up_at":"2026-10-25"},
         {"id":"acme-2026-005","title":"Archive old Acme letters","status":"open","priority":"low","no_deadline":true},
         {"id":"acme-2026-006","title":"Hidden Acme item","status":"open","priority":"normal","due":"2026-10-10","dismissed":true}]
        """)
        let h = try source("harbor", harbor, writable: false, """
        [{"id":"harbor-2026-001","title":"Pay the Harbor slip fee","status":"open","priority":"normal","due":"2026-10-14"},
         {"id":"harbor-2026-002","title":"Pay the Harbor mooring fee","status":"open","priority":"normal","due":"2026-10-03"},
         {"id":"harbor-2026-003","title":"Buy Harbor rope","status":"open","priority":"normal","due":"2026-10-16","contexts":["@errands"]},
         {"id":"harbor-2026-004","title":"Chase the Harbor office","status":"blocked","priority":"normal",
          "waiting_on":"Harbor office","follow_up_at":"2026-10-15"},
         {"id":"harbor-2026-005","title":"Renew the Harbor permit","status":"open","priority":"normal","due":"2027-03-01"}]
        """)
        return TodoBoard([a, h], today: today)
    }

    func titles(_ entries: [TodoBoard.Entry]) -> [String] { entries.map(\.item.title) }

    @Test func itemsAreGroupedByDateAgainstToday() throws {
        let b = try board()
        #expect(titles(b.entries(.overdue)) == ["Pay the Harbor mooring fee", "Send the Acme invoice", "Pay the Harbor slip fee"])
        #expect(titles(b.entries(.today)) == ["Call the Acme accountant"])
        #expect(titles(b.entries(.next7)) == ["Buy Harbor rope", "File the Acme return"])
        // Waiting is not bucketed by due (binder-v0 §5.2 step 3); the one to chase today comes first.
        #expect(titles(b.entries(.waiting)) == ["Chase the Harbor office", "Wait for the Acme receipt"])
        #expect(b.entries(.waiting).map(\.bucket) == [.nudge, .waiting])
        #expect(titles(b.entries(.later)) == ["Renew the Harbor permit"])
        #expect(titles(b.entries(.noDeadline)) == ["Archive old Acme letters"])
    }

    @Test func countsLeaveOutDismissedItems() throws {
        let b = try board()
        #expect(b.openCount == 10)
        #expect(b.count(.overdue) == 3 && b.count(.today) == 1 && b.count(.next7) == 2 && b.count(.waiting) == 2)
        #expect(!b.groups.values.joined().contains { $0.item.title == "Hidden Acme item" })
    }

    @Test func ordersTiesByPriorityTitleThenBinder() throws {
        let a = try source("acme", acme, """
        [{"id":"acme-2026-010","title":"Same day task","status":"open","priority":"normal","due":"2026-10-17"},
         {"id":"acme-2026-011","title":"Urgent same day task","status":"open","priority":"high","due":"2026-10-17"}]
        """)
        let h = try source("harbor", harbor, """
        [{"id":"harbor-2026-010","title":"Same day task","status":"open","priority":"normal","due":"2026-10-17"}]
        """)
        let b = TodoBoard([h, a], today: today)
        #expect(b.entries(.next7).map { "\($0.binder) \($0.item.title)" }
                == ["acme Urgent same day task", "acme Same day task", "harbor Same day task"])
    }

    @Test func searchMatchesTitleTagBinderAndId() throws {
        let b = try board()
        func found(_ q: String) -> [String] {
            TodoBoard.Group.allCases.flatMap { b.entries($0, TodoBoard.Filter(query: q)) }.map(\.item.title)
        }
        #expect(found("invoice") == ["Send the Acme invoice"])
        #expect(found("#TAX") == ["Call the Acme accountant"])
        #expect(found("harbor-2026-005") == ["Renew the Harbor permit"])
        #expect(found("harbor pay").sorted() == ["Pay the Harbor mooring fee", "Pay the Harbor slip fee"])
        #expect(found("ACMÉ").count == 5)
        #expect(found("nothing like this").isEmpty)
    }

    @Test func highOnlyAndWhereAmIFilter() throws {
        let b = try board()
        let high = TodoBoard.Group.allCases.flatMap { b.entries($0, TodoBoard.Filter(highOnly: true)) }
        #expect(titles(high) == ["Call the Acme accountant"])
        #expect(b.contexts == ["@calls", "@errands"])
        // At the shops: errands, and everything that names no context; not the call.
        let errands = TodoBoard.Group.allCases.flatMap { b.entries($0, TodoBoard.Filter(context: "@errands")) }
        #expect(titles(errands).contains("Buy Harbor rope"))
        #expect(titles(errands).contains("Send the Acme invoice"))
        #expect(!titles(errands).contains("Call the Acme accountant"))
    }

    @Test func doneIsOfferedOnlyWhereTheBinderPageOffersIt() throws {
        let b = try board()
        #expect(b.entries(.today).allSatisfy { $0.closable })
        // harbor is not writable here (not adopted, or its writes blocked).
        #expect(b.entries(.overdue).filter { $0.binder == "harbor" }.allSatisfy { !$0.closable })
        let r = try source("acme", acme, """
        [{"id":"acme-2026-020","title":"Monthly Acme fee","status":"open","priority":"normal","due":"2026-10-14","recurrence":{"freq":"monthly","day":14}}]
        """)
        #expect(TodoBoard([r], today: today).entries(.overdue).allSatisfy { !$0.closable })
    }

    @Test func completingSendsTheBinderPagesOpAndUndoTakesItBack() async throws {
        let runtime = StandInRuntime()
        runtime.answers["apply"] = { _ in #"{"ok":true,"op":"0199ffff-0000-7000-8000-000000000001"}"# }
        runtime.answers["undo"] = { _ in #"{"ok":true,"op":"0199ffff-0000-7000-8000-000000000002"}"# }
        let model = TodoModel(client: runtime.client)
        let entry = try #require(try board().entries(.today).first)
        var reloads = 0
        await model.complete(entry, reload: { reloads += 1 })
        let sent = try #require(runtime.sent.last)
        #expect(sent["command"] == .str("apply") && sent["op"] == .str("complete") && sent["binder"] == .string(acme.path))
        #expect(sent["args"]?["id"] == .str("acme-2026-002") && sent["args"]?["source"] == .str("user"))
        #expect(model.lastChange?.opID == "0199ffff-0000-7000-8000-000000000001")
        #expect(model.closing.isEmpty && reloads == 1)
        await model.undo(reload: { reloads += 1 })
        #expect(runtime.sent.last?["command"] == .str("undo"))
        #expect(runtime.sent.last?["op_id"] == .str("0199ffff-0000-7000-8000-000000000001"))
        #expect(model.lastChange == nil && reloads == 2)
    }

    @Test func quickAddFilesStraightIntoTheChosenBinder() async throws {
        let runtime = StandInRuntime()
        runtime.answers["apply"] = { _ in #"{"ok":true,"op":"0199ffff-0000-7000-8000-000000000003"}"# }
        let model = TodoModel(client: runtime.client)
        let targets = [TodoModel.Target(folder: acme, label: "acme"), TodoModel.Target(folder: harbor, label: "harbor")]
        #expect(model.defaultBinder(targets) == acme)
        model.draft = "  Book the Harbor slip  "
        model.hasDue = true
        model.due = try #require(Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 12)))
        model.priority = .high
        model.context = "@calls"
        await model.add(to: targets[1], reload: {})
        let sent = try #require(runtime.sent.last)
        #expect(sent["binder"] == .string(harbor.path) && sent["op"] == .str("add_item"))
        let item = try #require(sent["args"]?["item"])
        #expect(item == TodoModel.newItem(title: "Book the Harbor slip", due: CalendarDate(year: 2026, month: 10, day: 20),
                                          priority: .high, context: "@calls"))
        #expect(item["id"] == .str("$new:1") && item["due"] == .str("2026-10-20") && item["no_deadline"] == nil)
        // The field clears, and the binder used is offered next.
        #expect(model.draft.isEmpty && !model.hasDue && model.priority == .normal && model.context == nil)
        #expect(model.defaultBinder(targets) == harbor)
        #expect(model.lastChange?.line == "Added to harbor.")
    }

    @Test func aRefusedAddKeepsTheTypedLine() async throws {
        let runtime = StandInRuntime()
        let model = TodoModel(client: runtime.client)
        model.draft = "Send the Acme invoice"
        await model.add(to: TodoModel.Target(folder: acme, label: "acme"), reload: {})
        #expect(model.draft == "Send the Acme invoice")
        #expect(model.message?.hasPrefix("The item was not added") == true)
        let undated = TodoModel.newItem(title: "Archive", due: nil, priority: .normal, context: nil)
        #expect(undated["no_deadline"] == .bool(true) && undated["due"] == nil && undated["contexts"] == nil)
    }
}

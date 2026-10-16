import BinderFormat
import Foundation
import SpravaKit

/// The item being edited in place on each binder's page. Each saved change is one `update_item` (binder-v0 §6.3),
/// sent through the runtime like every binder write; the runtime's store stays the only writer.
///
/// Each binder has at most one open row, and nothing typed is ever kept anywhere but in it: opening another row
/// saves the open one first, as an inline edit on the Mac does when the person clicks away, and Esc cancels. The
/// shared Shelf model owns the editor, so the open row survives page changes and is the same in every window.
@MainActor
final class ItemEditor: ObservableObject {
    /// The open row of one binder: the item as it was when the row opened, and what was typed.
    struct Row {
        let item: Item
        let id: JSONValue
        var title: String
        var due: CalendarDate?
        /// The change typed so far, as `update_item` args; nil when nothing changed.
        var change: JSONObject? { ItemEditor.change(of: item, title: title, due: due) }
    }

    /// The open row of each binder, by folder.
    @Published private(set) var rows: [URL: Row] = [:]
    /// The binders whose open row's change the runtime is carrying out. The request already holds what was typed,
    /// so nothing on the row changes, and no other row opens, until the runtime answers.
    @Published private(set) var saving: Set<URL> = []

    /// A removal with no open edit owns admission until its runtime request and refresh finish.
    private var removing: Set<URL> = []

    func beginRemoval(in folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        guard rows[folder] == nil, !saving.contains(folder), !removing.contains(folder) else { return false }
        removing.insert(folder)
        return true
    }

    func endRemoval(in folder: URL) { removing.remove(folder.standardizedFileURL) }

    /// The open row of this binder.
    func row(in folder: URL) -> Row? { rows[folder.standardizedFileURL] }

    /// This binder's open row when its item is no longer on the page: closed, hidden or changed elsewhere, for
    /// example drained from the hub while the person typed. The page shows it apart, with Save and Cancel, so what
    /// was typed stays in reach and the binder's other rows can open again once it is settled.
    func stranded(in folder: URL, shown page: NowPage) -> Row? {
        guard let row = row(in: folder) else { return nil }
        return page.items.values.contains { $0.contains { $0.object?["id"] == row.id } } ? nil : row
    }

    /// Whether this item's row is the one open, in this binder.
    func isEditing(_ item: Item, in folder: URL) -> Bool {
        guard let id = item.object?["id"] else { return false }
        return row(in: folder)?.id == id
    }

    /// Opens an item's row. The row already open in this binder is saved first when something was typed into it,
    /// and the new row opens once the runtime accepts that; when it refuses, the open row stays with its text and
    /// the page says why. False for an item without an id, which no op can name, and while a change is on its way.
    @discardableResult
    func begin(_ item: Item, in folder: URL, _ actions: BinderActions, reload: @escaping () -> Void) -> Bool {
        let folder = folder.standardizedFileURL
        guard !saving.contains(folder), !removing.contains(folder), let id = item.object?["id"] else { return false }
        if rows[folder]?.id == id { return true }
        if rows[folder]?.change != nil {
            return save(in: folder, actions, reload: reload, then: { [weak self] in self?.open(item, id, in: folder) }) != nil
        }
        open(item, id, in: folder)
        return true
    }

    private func open(_ item: Item, _ id: JSONValue, in folder: URL) {
        rows[folder] = Row(item: item, id: id, title: item.object?["title"]?.stringValue ?? "", due: item.due)
    }

    /// Closes this binder's open row and drops what was typed into it; false while its change is on its way.
    @discardableResult
    func cancel(in folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        guard !saving.contains(folder) else { return false }
        rows[folder] = nil
        return true
    }

    /// Changes the title being typed; false when no row is open or its change is on its way.
    @discardableResult
    func setTitle(_ value: String, in folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        guard !saving.contains(folder), rows[folder] != nil else { return false }
        rows[folder]?.title = value
        return true
    }

    /// Changes the due date being set (nil: no date); false when no row is open or its change is on its way.
    @discardableResult
    func setDue(_ value: CalendarDate?, in folder: URL) -> Bool {
        let folder = folder.standardizedFileURL
        guard !saving.contains(folder), rows[folder] != nil else { return false }
        rows[folder]?.due = value
        return true
    }

    /// Sends what changed as one `update_item`, with the row locked until the runtime answers, and closes the row
    /// once the runtime accepts it. A refused change keeps the row open with what was typed, and the page shows why.
    /// Nothing changed: the row just closes.
    @discardableResult
    func save(in folder: URL, _ actions: BinderActions, reload: @escaping () -> Void,
              then next: @escaping () -> Void = {}) -> Task<Void, Never>? {
        let folder = folder.standardizedFileURL
        guard !saving.contains(folder), !actions.busy, actions.serves(folder), let row = rows[folder] else { return nil }
        guard let args = row.change else { rows[folder] = nil; next(); return nil }
        saving.insert(folder)
        return actions.run("apply", folder, [("op", .str("update_item")), ("args", .object(args))], then: reload,
                           onSuccess: { [weak self] in self?.rows[folder] = nil },
                           onEnd: { [weak self] in
                               guard let self else { return }
                               saving.remove(folder)
                               if rows[folder] == nil { next() }
                           })
    }

    /// The `update_item` args for a new title and due date, or nil when neither changed. An empty title leaves the
    /// title as it was (binder-v0 §6.3: `title` cannot be removed). A due date replaces `no_deadline`, and "no
    /// date" replaces the due date with `no_deadline: true`, so the item keeps exactly one (binder-v0 §4.4).
    nonisolated static func change(of item: Item, title: String, due: CalendarDate?) -> JSONObject? {
        guard let object = item.object, let id = object["id"] else { return nil }
        var set = JSONObject()
        var unset: [JSONValue] = []
        // A title left as the row opened is not rewritten, even one with spaces at its ends.
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if object["title"] != .string(title), !typed.isEmpty, object["title"] != .string(typed) {
            set.set("title", .string(typed))
        }
        if let due, due != item.due {
            set.set("due", .string(due.description))
            if object["no_deadline"] != nil { unset.append(.str("no_deadline")) }
        } else if due == nil, item.due != nil {
            unset.append(.str("due"))
            set.set("no_deadline", .bool(true))
        }
        guard !set.entries.isEmpty || !unset.isEmpty else { return nil }
        var args = JSONObject([(key: "id", value: id)])
        if !set.entries.isEmpty { args.set("set", .object(set)) }
        if !unset.isEmpty { args.set("unset", .array(unset)) }
        return args
    }

    /// The one calendar both directions of the date picker go through, so a day comes back as it went in (before
    /// 1582 too, where Foundation's Gregorian calendar switches to Julian dates).
    nonisolated static var pickerCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// A calendar day as the date picker holds it: noon of that day here, so no time zone moves it a day.
    nonisolated static func date(_ day: CalendarDate) -> Date {
        pickerCalendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
    }

    /// The calendar day the picker shows, here.
    nonisolated static func day(_ date: Date) -> CalendarDate {
        let c = pickerCalendar.dateComponents([.year, .month, .day], from: date)
        return c.year.flatMap { y in c.month.flatMap { m in c.day.flatMap { CalendarDate(year: y, month: m, day: $0) } } }
            ?? CalendarDate.today()
    }
}

import BinderFormat
import Foundation
import SpravaKit

/// The one item being edited in place on a binder's page. Each saved change is one `update_item` (binder-v0 §6.3),
/// sent through the runtime like every binder write; the runtime's store stays the only writer.
@MainActor
final class ItemEditor: ObservableObject {
    /// Which row is open: the binder and the item's id as the catalog holds it.
    struct Key: Hashable {
        let folder: URL
        let id: JSONValue
    }

    /// What was typed into one row, against the item as it was when the row opened.
    struct Draft {
        let item: Item
        var title: String
        var due: CalendarDate?
    }

    @Published private(set) var open: Key?
    @Published private(set) var title = ""
    /// The due date being set; nil is "no date".
    @Published private(set) var due: CalendarDate?
    /// The row whose change the runtime is carrying out. The request already holds what was typed, so nothing on
    /// the editor changes until the runtime answers: words typed meanwhile would vanish when the row closes.
    @Published private(set) var saving: Key?
    /// The item as it was when the open row opened, which the change is computed against.
    private var item: Item?
    /// Rows left with unsaved changes when another row was opened, by key; opening one again brings them back.
    private var drafts: [Key: Draft] = [:]

    /// Whether this item's row is the one open, in this binder.
    func isEditing(_ item: Item, in folder: URL) -> Bool {
        guard let open, let id = item.object?["id"] else { return false }
        return open == Key(folder: folder.standardizedFileURL, id: id)
    }

    /// Opens a row for editing, setting aside what was typed into the row open before. False for an item without
    /// an id, which no op can name, and while a change is on its way. The row already open keeps what was typed.
    @discardableResult
    func begin(_ item: Item, in folder: URL) -> Bool {
        guard saving == nil, let id = item.object?["id"] else { return false }
        let key = Key(folder: folder.standardizedFileURL, id: id)
        if open == key { return true }
        if let open, let current = self.item, Self.change(of: current, title: title, due: due) != nil {
            drafts[open] = Draft(item: current, title: title, due: due)
        }
        let draft = drafts.removeValue(forKey: key)
            ?? Draft(item: item, title: item.object?["title"]?.stringValue ?? "", due: item.due)
        open = key
        self.item = draft.item
        title = draft.title
        due = draft.due
        return true
    }

    /// Closes the open row and drops what was typed into it; false while its change is on its way.
    @discardableResult
    func cancel() -> Bool {
        guard saving == nil else { return false }
        close()
        return true
    }

    private func close() {
        open = nil
        item = nil
        title = ""
        due = nil
    }

    /// Changes the title being typed; false when no row is open or its change is on its way.
    @discardableResult
    func setTitle(_ value: String) -> Bool {
        guard saving == nil, open != nil else { return false }
        title = value
        return true
    }

    /// Changes the due date being set (nil: no date); false when no row is open or its change is on its way.
    @discardableResult
    func setDue(_ value: CalendarDate?) -> Bool {
        guard saving == nil, open != nil else { return false }
        due = value
        return true
    }

    /// Sends what changed as one `update_item`, with the row locked until the runtime answers, and closes the row
    /// once the runtime accepts it. A refused change keeps the row open with what was typed, and the page shows why.
    /// Nothing changed: the row just closes.
    @discardableResult
    func save(_ actions: BinderActions, reload: @escaping () -> Void) -> Task<Void, Never>? {
        guard saving == nil, !actions.busy, let open, let item, actions.serves(open.folder) else { return nil }
        guard let args = Self.change(of: item, title: title, due: due) else { close(); return nil }
        saving = open
        return actions.run("apply", open.folder, [("op", .str("update_item")), ("args", .object(args))], then: reload,
                           onSuccess: { [weak self] in if self?.open == open { self?.close() } },
                           onEnd: { [weak self] in self?.saving = nil })
    }

    /// The `update_item` args for a new title and due date, or nil when neither changed. An empty title leaves the
    /// title as it was (binder-v0 §6.3: `title` cannot be removed). A due date replaces `no_deadline`, and "no
    /// date" replaces the due date with `no_deadline: true`, so the item keeps exactly one (binder-v0 §4.4).
    static func change(of item: Item, title: String, due: CalendarDate?) -> JSONObject? {
        guard let object = item.object, let id = object["id"] else { return nil }
        var set = JSONObject()
        var unset: [JSONValue] = []
        let typed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty, object["title"] != .string(typed) { set.set("title", .string(typed)) }
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

    /// A calendar day as the date picker holds it: noon of that day here, so no time zone moves it a day.
    static func date(_ day: CalendarDate) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: day.year, month: day.month, day: day.day, hour: 12)) ?? Date()
    }

    /// The calendar day the picker shows, here.
    static func day(_ date: Date) -> CalendarDate { CalendarDate(date, in: .current) ?? CalendarDate.today() }
}

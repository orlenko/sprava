import BinderFormat
import Foundation
import SpravaKit

/// The one item being edited in place on a binder's page. Each saved change is one `update_item` (binder-v0 §6.3),
/// sent through the runtime like every binder write; the runtime's store stays the only writer.
@MainActor
final class ItemEditor: ObservableObject {
    /// Which row is open: the binder and the item's id as the catalog holds it.
    struct Key: Equatable {
        let folder: URL
        let id: JSONValue
    }

    @Published private(set) var open: Key?
    @Published var title = ""
    /// The due date being set; nil is "no date".
    @Published var due: CalendarDate?
    /// The item as it was when the row opened, which the change is computed against.
    private var item: Item?

    /// Whether this item's row is the one open, in this binder.
    func isEditing(_ item: Item, in folder: URL) -> Bool {
        guard let open, let id = item.object?["id"] else { return false }
        return open == Key(folder: folder.standardizedFileURL, id: id)
    }

    /// Opens a row for editing, closing any other; false for an item without an id, which no op can name.
    @discardableResult
    func begin(_ item: Item, in folder: URL) -> Bool {
        guard let id = item.object?["id"] else { return false }
        open = Key(folder: folder.standardizedFileURL, id: id)
        self.item = item
        title = item.object?["title"]?.stringValue ?? ""
        due = item.due
        return true
    }

    func cancel() {
        open = nil
        item = nil
        title = ""
        due = nil
    }

    /// Sends what changed as one `update_item` and closes the row once the runtime accepts it. A refused change
    /// keeps the row open with what was typed, and the page shows why. Nothing changed: the row just closes.
    @discardableResult
    func save(_ actions: BinderActions, reload: @escaping () -> Void) -> Task<Void, Never>? {
        guard let open, let item, actions.serves(open.folder) else { cancel(); return nil }
        guard !actions.busy else { return nil }
        guard let args = Self.change(of: item, title: title, due: due) else { cancel(); return nil }
        return actions.run("apply", open.folder, [("op", .str("update_item")), ("args", .object(args))], then: reload,
                           onSuccess: { [weak self] in if self?.open == open { self?.cancel() } })
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

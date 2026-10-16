import BinderFormat
import Combine
import Foundation
import SpravaKit

/// The To-dos page's state: its filters, the quick-add row, and the changes it sends, each through the runtime with the
/// commands the binder page uses (`apply`, `undo`).
@MainActor
final class TodoModel: ObservableObject {
    /// A binder the quick-add row can file into.
    struct Target: Identifiable, Equatable {
        let folder: URL
        let label: String
        var id: URL { folder }
    }

    /// The last change made from the page, which Undo takes back.
    struct Change: Equatable {
        let line: String
        let folder: URL
        let opID: String
    }

    @Published var filter = TodoBoard.Filter()
    @Published var collapsed: Set<TodoBoard.Group> = []
    @Published var draft = ""
    @Published var hasDue = false
    @Published var due = Date()
    @Published var priority = Priority.normal
    @Published var context: String?
    /// The binder the next item goes to; the one used last until the person picks another.
    @Published var binder: URL?
    @Published private(set) var lastChange: Change?
    @Published var message: String?
    @Published private(set) var adding = false
    /// Items being closed: hidden until the refresh that no longer lists them.
    @Published private(set) var closing: Set<String> = []
    let client: RuntimeClient

    init(client: RuntimeClient = RuntimeClient()) {
        self.client = client
    }

    /// The binder offered first: the one chosen before, while it can still take items, else the first on the Shelf.
    func defaultBinder(_ targets: [Target]) -> URL? {
        if let binder, targets.contains(where: { $0.folder == binder }) { return binder }
        return targets.first?.folder
    }

    func toggle(_ group: TodoBoard.Group) {
        if collapsed.contains(group) { collapsed.remove(group) } else { collapsed.insert(group) }
    }

    /// The new item as `add_item` writes it (binder-v0 §4.4, in its key order); its id is minted by the runtime.
    static func newItem(title: String, due: CalendarDate?, priority: Priority, context: String?) -> JSONValue {
        var fields: [(String, JSONValue)] = [("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")),
                                             ("priority", .string(priority.rawValue))]
        if let due { fields.append(("due", .string(due.description))) } else { fields.append(("no_deadline", .bool(true))) }
        if let context { fields.append(("contexts", .array([.string(context)]))) }
        return .obj(fields)
    }

    /// Files the typed line straight into the chosen binder as the person's own item. The line stays in the field
    /// until the runtime has written it, and is cleared only if it is still the text sent.
    func add(to target: Target?, reload: @escaping () async -> Void) async {
        let typed = draft
        let title = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adding, !title.isEmpty else { return }
        guard let target else {
            message = "No binder can take a new item yet. Adopt a binder on its page first."
            return
        }
        adding = true
        defer { adding = false }
        let day = hasDue ? CalendarDate(due, in: .current) : nil
        let item = Self.newItem(title: title, due: day, priority: priority, context: context)
        do {
            let r = try await client.command("apply", binder: target.folder, [("op", .str("add_item")), ("args", .obj([("item", item)]))])
            binder = target.folder
            if draft == typed { draft = ""; hasDue = false; priority = .normal; context = nil }
            message = nil
            lastChange = r["op"]?.stringValue.map { Change(line: "Added to \(target.label).", folder: target.folder, opID: $0) }
        } catch {
            message = "The item was not added: \(error)"
        }
        await reload()
    }

    /// Completes an item as the binder page does (`apply` with `complete`), with Undo.
    func complete(_ entry: TodoBoard.Entry, reload: @escaping () async -> Void) async {
        guard entry.closable, let id = entry.item.object?["id"], !closing.contains(entry.id) else { return }
        closing.insert(entry.id)
        let at = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!)
        do {
            let r = try await client.command("apply", binder: entry.folder, [
                ("op", .str("complete")), ("args", .obj([("id", id), ("closed_at", .string(at)), ("source", .str("user"))])),
            ])
            message = nil
            lastChange = r["op"]?.stringValue.map { Change(line: "Done: \(entry.item.title)", folder: entry.folder, opID: $0) }
        } catch {
            message = "Not marked done: \(error)"
        }
        await reload()
        closing.remove(entry.id)
    }

    func undo(reload: @escaping () async -> Void) async {
        guard let change = lastChange else { return }
        lastChange = nil
        do {
            _ = try await client.command("undo", binder: change.folder, [("op_id", .string(change.opID))])
            message = nil
        } catch {
            if lastChange == nil { lastChange = change }
            message = "Could not undo: \(error)"
        }
        await reload()
    }
}

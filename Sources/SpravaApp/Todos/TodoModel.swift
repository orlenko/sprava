import BinderFormat
import Combine
import Foundation
import SpravaKit

/// The To-dos page's state: its filters, the quick-add row, and the changes it sends, each through the runtime with the
/// commands the binder page uses (`apply`, `undo`).
@MainActor
final class TodoModel: ObservableObject, DraftOwner {
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
    @Published var details = ""
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
    @Published private(set) var undoing = false
    var draftState: DraftState { DraftState(hasChanges: !draft.isEmpty || !details.isEmpty, saving: adding || !closing.isEmpty || undoing || itemActions.values.contains { $0.busy }) }
    @Published private(set) var editingTargets: [Target] = []
    private var itemActions: [URL: BinderActions] = [:]
    private var opening = Set<URL>()
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
    static func newItem(title: String, due: CalendarDate?, priority: Priority, context: String?, details: String = "") -> JSONValue {
        var fields: [(String, JSONValue)] = [("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")),
                                             ("priority", .string(priority.rawValue))]
        if let due { fields.append(("due", .string(due.description))) } else { fields.append(("no_deadline", .bool(true))) }
        if !details.isEmpty { fields.append(("details", .str(details))) }
        if let context { fields.append(("contexts", .array([.string(context)]))) }
        return .obj(fields)
    }

    /// Files the typed line straight into the chosen binder as the person's own item. The line stays in the field
    /// until the runtime has written it, and is cleared only if it is still the text sent.
    func add(to target: Target?, reload: @escaping () async -> Void) async {
        let typed = draft, submittedDetails = details
        let title = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adding, !title.isEmpty else { return }
        guard let target else {
            message = "No binder can take a new item yet. Adopt a binder on its page first."
            return
        }
        adding = true
        defer { adding = false }
        let day = hasDue ? CalendarDate(due, in: .current) : nil
        let item = Self.newItem(title: title, due: day, priority: priority, context: context, details: submittedDetails)
        do {
            let r = try await client.command("apply", binder: target.folder, [("op", .str("add_item")), ("args", .obj([("item", item)]))])
            binder = target.folder
            if draft == typed, details == submittedDetails { draft = ""; details = ""; hasDue = false; priority = .normal; context = nil }
            message = nil
            lastChange = r["op"]?.stringValue.map { Change(line: "Added to \(target.label).", folder: target.folder, opID: $0) }
        } catch {
            message = "The item was not added: \(error)"
        }
        await reload()
    }

    func actions(for folder: URL) -> BinderActions {
        let folder = folder.standardizedFileURL
        if let model = itemActions[folder] { return model }
        let model = BinderActions(client: client)
        itemActions[folder] = model
        return model
    }

    /// Reuses the window's ordinary item editor and writer; no model or capture route is involved (D25).
    func edit(_ entry: TodoBoard.Entry, editor: ItemEditor, reload: @escaping () async -> Void = {}) async {
        guard entry.closable, !opening.contains(entry.folder) else { return }
        opening.insert(entry.folder); defer { opening.remove(entry.folder) }
        let writer = actions(for: entry.folder)
        if !editingTargets.contains(where: { $0.folder == entry.folder }) {
            editingTargets.append(Target(folder: entry.folder, label: entry.binder))
        }
        await writer.load(entry.folder, adopted: true)
        editor.begin(entry.item, in: entry.folder, writer, reload: {
            Task { await writer.loadReview(entry.folder); await reload() }
        })
    }

    /// Completes an item as the binder page does (`apply` with `complete`), with Undo.
    func complete(_ entry: TodoBoard.Entry, editor: ItemEditor? = nil, reload: @escaping () async -> Void) async {
        await close(entry, operation: "complete", editor: editor, reload: reload)
    }
    func cancel(_ entry: TodoBoard.Entry, editor: ItemEditor? = nil, reload: @escaping () async -> Void) async {
        await close(entry, operation: "drop", editor: editor, reload: reload)
    }
    private func close(_ entry: TodoBoard.Entry, operation: String, editor: ItemEditor?, reload: @escaping () async -> Void) async {
        guard entry.closable, let id = entry.item.object?["id"], !closing.contains(entry.id) else { return }
        closing.insert(entry.id)
        defer { closing.remove(entry.id) }
        if let editor, editor.isEditing(entry.item, in: entry.folder) {
            if !editingTargets.contains(where: { $0.folder == entry.folder }) {
                editingTargets.append(Target(folder: entry.folder, label: entry.binder))
            }
            let writer = actions(for: entry.folder)
            if !writer.serves(entry.folder) { await writer.load(entry.folder, adopted: true) }
            guard editor.isEditing(entry.item, in: entry.folder) else {
                message = "The edited to-do changed. Check it before closing."; return
            }
            if let task = editor.close(as: operation, in: entry.folder, writer, reload: {}) { await task.value }
            // A dirty row saves first, then starts its closing op. Wait for that op too before refreshing.
            while editor.saving.contains(entry.folder.standardizedFileURL) {
                try? await Task.sleep(for: .milliseconds(10))
                await Task.yield()
            }
            await writer.loadReview(entry.folder)
            await reload()
            return
        }
        let at = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!)
        do {
            let r = try await client.command("apply", binder: entry.folder, [
                ("op", .str(operation)), ("args", .obj([("id", id), ("closed_at", .string(at)), ("source", .str("user"))])),
            ])
            message = nil
            lastChange = r["op"]?.stringValue.map { Change(line: (operation == "complete" ? "Done: " : "Cancelled: ") + entry.item.title, folder: entry.folder, opID: $0) }
        } catch {
            message = "The to-do was not closed: \(error)"
        }
        await reload()
    }

    func undo(reload: @escaping () async -> Void) async {
        guard !undoing, let change = lastChange else { return }
        undoing = true
        defer { undoing = false }
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

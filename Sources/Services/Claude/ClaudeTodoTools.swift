import BinderFormat
import BinderStore
import Brains
import Foundation
import SpravaKit

/// The binder writer, reached from a conversation turn. Every write goes through the one queue the app's commands use.
public final class ClaudeTodoWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var target: (commands: Commands, queue: DispatchQueue)?
    public init() {}
    public func attach(commands: Commands, queue: DispatchQueue) { lock.withLock { target = (commands, queue) } }
    var attached: Bool { lock.withLock { target != nil } }
    func perform<T>(_ work: (Commands) throws -> T) throws -> T {
        guard let target = lock.withLock({ target }) else { throw ClaudeTodoTools.Refusal.unavailable }
        return try target.queue.sync { try work(target.commands) }
    }
}

/// What the agent of a person's turn can do to this binder's to-dos (conversation.md 18.5, decisions.md D32): add, edit,
/// complete and remove, at once, each op naming the turn. The check is here, not in the model: a change applies only to a
/// to-do as this turn found it, so an edit the person made meanwhile is a refusal and not overwritten, and no turn makes
/// more than `maximumChanges`. A refusal changes nothing and comes back as a reason code the agent can tell the person.
final class ClaudeTodoTools: @unchecked Sendable {
    enum Refusal: Error, Equatable {
        case invalid(String), notFound, changedSince, tooMany, unavailable, refused
        var code: String {
            switch self {
            case .invalid: "invalid"
            case .notFound: "not_found"
            case .changedSince: "changed_since"
            case .tooMany: "too_many"
            case .unavailable, .refused: "not_saved"
            }
        }
        var message: String {
            switch self {
            case .invalid(let why): why
            case .notFound: "No open to-do has that id. It may be closed already. Nothing changed."
            case .changedSince: "This to-do changed since this turn started, probably by the person. Nothing changed; tell them."
            case .tooMany: "This turn has made as many to-do changes as one turn may (\(ClaudeTodoTools.maximumChanges)). Nothing more changed; tell the person."
            case .unavailable, .refused: "Sprava could not save this. Nothing changed; tell the person."
            }
        }
    }
    static let maximumChanges = 50
    static let model = "sonnet"

    private let folder: URL, record: ConversationTurnStore.Record, history: TurnHistory, writer: ClaudeTodoWriter
    private let lock = NSLock()
    /// Open to-dos by id, each as a hash of the record as this turn found or left it.
    private var known: [String: String]
    private var changes = 0

    /// Nil, and so no tools, when nothing can write or the to-dos cannot be read.
    init?(folder: URL, record: ConversationTurnStore.Record, history: TurnHistory, writer: ClaudeTodoWriter) {
        guard writer.attached, let items = Self.openItems(folder) else { return nil }
        self.folder = folder; self.record = record; self.history = history; self.writer = writer
        known = [:]
        for item in items {
            if let id = ItemID(item["id"])?.description, let hash = try? Canonical.hash(.object(item)) { known[id] = hash }
        }
    }

    private static func openItems(_ folder: URL) -> [JSONObject]? {
        Teka.read(folder).catalog?["open_items"]?.arrayValue?.compactMap(\.objectValue)
    }

    var appTools: ClaudeAppTools {
        ClaudeAppTools(tools: Self.tools) { [self] name, args in
            do { return .init(content: try handle(name, args)) }
            catch let refusal as Refusal { return .init(content: .obj([("error", .str(refusal.code)), ("message", .str(refusal.message))]), refused: true) }
            catch { return .init(content: .obj([("error", .str(Refusal.refused.code)), ("message", .str(Refusal.refused.message))]), refused: true) }
        }
    }

    private func handle(_ name: String, _ args: JSONObject) throws -> JSONValue {
        try lock.withLock {
            guard changes < Self.maximumChanges else { throw Refusal.tooMany }
            let result: JSONValue
            switch name {
            case "add_todo": result = try add(args)
            case "edit_todo": result = try edit(args)
            case "complete_todo": result = try close(args, op: "complete", verb: .completed)
            case "remove_todo": result = try close(args, op: "drop", verb: .removed)
            default: throw Refusal.invalid("No such tool.")
            }
            changes += 1
            return result
        }
    }

    // MARK: - The four changes

    private func add(_ args: JSONObject) throws -> JSONValue {
        let title = try Self.title(args["title"])
        var fields: [(String, JSONValue)] = [("id", .str("$new:1")), ("title", .str(title)), ("status", .str("open")), ("sensitivity", .str("private")),
                                             ("priority", .str(try Self.priority(args["priority"]) ?? "normal"))]
        if let details = try Self.details(args["details"]), !details.isEmpty { fields.append(("details", .str(details))) }
        if let due = try Self.due(args["due"]) { fields.append(("due", .str(due))) } else { fields.append(("no_deadline", .bool(true))) }
        let applied = try write("add_item", .init([(key: "item", value: .obj(fields))]), expect: nil, verb: .added, title: title)
        guard let id = applied.first?["args"]?["item"]?["id"], let shown = ItemID(id)?.description else { throw Refusal.refused }
        remember(shown)
        return .obj([("ok", .bool(true)), ("id", .str(shown)), ("title", .str(title))])
    }

    private func edit(_ args: JSONObject) throws -> JSONValue {
        let (id, item, hash) = try find(args["id"])
        var set = JSONObject(), unset: [JSONValue] = []
        if let value = args["title"] { set.set("title", .str(try Self.title(value))) }
        if let value = try Self.priority(args["priority"]) { set.set("priority", .str(value)) }
        if let value = args["details"] {
            let details = try Self.details(value) ?? ""
            if details.isEmpty { if item["details"] != nil { unset.append(.str("details")) } } else { set.set("details", .str(details)) }
        }
        if let value = args["due"] {
            if let due = try Self.due(value) {
                set.set("due", .str(due))
                if item["no_deadline"] != nil { unset.append(.str("no_deadline")) }
            } else {
                set.set("no_deadline", .bool(true))
                if item["due"] != nil { unset.append(.str("due")) }
            }
        }
        guard !set.entries.isEmpty || !unset.isEmpty else { throw Refusal.invalid("Name at least one field to change. Nothing changed.") }
        var change = JSONObject([(key: "id", value: id)])
        if !set.entries.isEmpty { change.set("set", .object(set)) }
        if !unset.isEmpty { change.set("unset", .array(unset)) }
        let title = set["title"]?.stringValue ?? item["title"]?.stringValue ?? "untitled"
        _ = try write("update_item", change, expect: hash, verb: .edited, title: title)
        if let shown = ItemID(id)?.description { remember(shown) }
        return .obj([("ok", .bool(true)), ("title", .str(title))])
    }

    private func close(_ args: JSONObject, op: String, verb: TurnHistory.TodoChange.Verb) throws -> JSONValue {
        let (id, item, hash) = try find(args["id"])
        let title = item["title"]?.stringValue ?? "untitled"
        _ = try write(op, .init([(key: "id", value: id)]), expect: hash, verb: verb, title: title)
        if let shown = ItemID(id)?.description { known[shown] = nil }
        return .obj([("ok", .bool(true)), ("title", .str(title))])
    }

    // MARK: - Reading and writing

    /// The open to-do with this id, by the catalog's own form of its id, and the hash this turn holds for it.
    private func find(_ given: JSONValue?) throws -> (id: JSONValue, item: JSONObject, hash: String) {
        guard let given, let wanted = given.stringValue ?? given.numberValue?.safeInteger.map(String.init) else { throw Refusal.invalid("Give the to-do's id from current_items. Nothing changed.") }
        guard let hash = known[wanted], let item = Self.openItems(folder)?.first(where: { ItemID($0["id"])?.description == wanted }), let id = item["id"] else { throw Refusal.notFound }
        guard (try? Canonical.hash(.object(item))) == hash else { throw Refusal.changedSince }
        return (id, item, hash)
    }

    private func remember(_ id: String) {
        if let item = Self.openItems(folder)?.first(where: { ItemID($0["id"])?.description == id }), let hash = try? Canonical.hash(.object(item)) { known[id] = hash }
    }

    private func write(_ op: String, _ args: JSONObject, expect: String?, verb: TurnHistory.TodoChange.Verb, title: String) throws -> [JSONObject] {
        let (folder, turn, request, history) = (self.folder, record.turnID, record.requestID, self.history)
        do {
            return try writer.perform { commands in
                let applied = try commands.applyTurnOp(op, args: args, expect: expect, folder: folder, model: Self.model, turn: turn, request: request)
                // The op has been written, so a line that cannot be kept does not make it a refusal.
                try? history.noteTodoChange(.init(verb: verb, title: title, opIDs: applied.compactMap { $0["id"]?.stringValue }), turn: turn)
                return applied
            }
        } catch let refusal as Refusal { throw refusal }
        catch { throw Refusal.refused }
    }

    /// Reverses a turn's to-do changes, newest first. Returns the titles of those that changed since and stayed; the turn counts
    /// as undone only when there are none.
    static func undo(turn: UUID, folder: URL, history: TurnHistory, writer: ClaudeTodoWriter) throws -> [String] {
        guard let record = try history.todoChanges(forTurn: turn), !record.undone else { return [] }
        return try writer.perform { commands in
            var left: [String] = []
            for change in record.changes.reversed() {
                for op in change.opIDs.reversed() where try !commands.undoTurnOp(op, folder: folder) {
                    left.append(change.title)
                }
            }
            if left.isEmpty { try history.markTodosUndone(forTurn: turn) }
            return left
        }
    }

    // MARK: - What a tool may be given

    private static func oneLine(_ text: String) -> Bool { !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) } }

    private static func title(_ value: JSONValue?) throws -> String {
        guard let text = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty, text.utf8.count <= 512, oneLine(text) else {
            throw Refusal.invalid("A title is one line of at most 512 bytes. Nothing changed.")
        }
        return text
    }
    private static func details(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue, text.utf8.count <= 8_192,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !["\n", "\t"].contains(String($0)) }) else {
            throw Refusal.invalid("Details are text of at most 8,192 bytes. Nothing changed.")
        }
        return text
    }
    private static func due(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue, CalendarDate.strict(text) != nil else { throw Refusal.invalid("A due date is YYYY-MM-DD. Nothing changed.") }
        return text
    }
    private static func priority(_ value: JSONValue?) throws -> String? {
        guard let value, value != .null else { return nil }
        guard let text = value.stringValue, ["high", "normal", "low"].contains(text) else { throw Refusal.invalid("Priority is high, normal or low. Nothing changed.") }
        return text
    }

    private static func schema(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
        .obj([("type", .str("object")), ("properties", .obj(properties)), ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
    }
    private static let id: (String, JSONValue) = ("id", .obj([("type", .array([.str("string"), .str("integer")])), ("description", .str("The to-do's id, from current_items or add_todo."))]))
    private static let fields: [(String, JSONValue)] = [
        ("title", .obj([("type", .str("string")), ("description", .str("One line."))])),
        ("details", .obj([("type", .str("string"))])),
        ("due", .obj([("type", .array([.str("string"), .str("null")])), ("description", .str("YYYY-MM-DD, or null for no date."))])),
        ("priority", .obj([("type", .str("string")), ("enum", .array([.str("high"), .str("normal"), .str("low")]))])),
    ]
    static let tools: [ClaudeAppTools.Tool] = [
        .init(name: "add_todo", description: "Adds one to-do to this binder at once. Returns its id.", schema: schema(fields, required: ["title"])),
        .init(name: "edit_todo", description: "Changes the named fields of one open to-do at once.", schema: schema([id] + fields, required: ["id"])),
        .init(name: "complete_todo", description: "Marks one open to-do done at once.", schema: schema([id], required: ["id"])),
        .init(name: "remove_todo", description: "Removes one open to-do from the list at once, recording it as cancelled.", schema: schema([id], required: ["id"])),
    ]
}

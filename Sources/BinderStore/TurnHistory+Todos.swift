import Foundation
import SpravaKit

/// What a conversation turn did to the binder's to-dos, kept beside the turn's file entry. The changes themselves are ops in
/// the binder's log; this names them, so the turn's line can say what changed and its Undo can reverse them.
extension TurnHistory {
    public struct TodoChange: Codable, Equatable, Sendable {
        public enum Verb: String, Codable, Sendable { case added, edited, completed, removed }
        public let verb: Verb
        public let title: String
        public let opIDs: [String]
        public init(verb: Verb, title: String, opIDs: [String]) { self.verb = verb; self.title = title; self.opIDs = opIDs }
    }

    public struct TurnTodos: Codable, Equatable, Sendable {
        public let at: Date
        public var changes: [TodoChange]
        public var undone = false

        /// One line for the conversation: each kind of change with its count, and up to three titles.
        public var summary: String {
            let kinds: [(TodoChange.Verb, String)] = [(.added, "Added"), (.edited, "Changed"), (.completed, "Marked done"), (.removed, "Removed")]
            return kinds.compactMap { verb, word -> String? in
                let titles = changes.filter { $0.verb == verb }.map(\.title)
                guard !titles.isEmpty else { return nil }
                let names = titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? ", …" : "")
                return "\(word) \(titles.count) to-do\(titles.count == 1 ? "" : "s"): \(names)"
            }.joined(separator: ". ")
        }
    }

    private var todos: URL { root.appendingPathComponent("todos", isDirectory: true) }
    private func todosFile(_ turn: UUID) -> URL { todos.appendingPathComponent("turn-\(turn.uuidString).json") }

    /// Written right after the op, on the binder's command queue.
    public func noteTodoChange(_ change: TodoChange, turn: UUID, now: Date = Date()) throws {
        try AtomicFile.makePrivateFolder(root); try AtomicFile.makePrivateFolder(todos)
        var record = try todoChanges(forTurn: turn) ?? TurnTodos(at: now, changes: [])
        if record.changes.isEmpty { pruneTodos(now: now) }
        record.changes.append(change)
        try AtomicFile.write(try JSONEncoder().encode(record), to: todosFile(turn))
    }

    public func todoChanges(forTurn turn: UUID) throws -> TurnTodos? {
        guard let data = try? Data(contentsOf: todosFile(turn)) else { return nil }
        guard let record = try? JSONDecoder().decode(TurnTodos.self, from: data) else { throw Refused.damaged }
        return record
    }

    public func markTodosUndone(forTurn turn: UUID) throws {
        guard var record = try todoChanges(forTurn: turn) else { return }
        record.undone = true
        try AtomicFile.write(try JSONEncoder().encode(record), to: todosFile(turn))
    }

    func pruneTodos(now: Date) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: todos.path)) ?? [] {
            let url = todos.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(TurnTodos.self, from: data),
                  now.timeIntervalSince(record.at) > TimeInterval(Self.keepDays * 86_400) else { continue }
            try? manager.removeItem(at: url)
        }
    }
}

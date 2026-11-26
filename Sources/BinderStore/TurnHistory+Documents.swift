import BinderFormat
import Foundation
import SpravaKit

/// What a conversation turn did to the binder's document records with Sprava's own tools (decisions.md D45), kept beside
/// the turn's file entry. The changes themselves are ops in the binder's log; this names them, so the turn's line can
/// say what changed and its Undo can reverse them. It also keeps the turn's file Undo working: a document change the
/// turn made itself is not "something was filed while it ran", and a file the turn moved with its record is the op's to
/// move back, not the file entry's.
extension TurnHistory {
    public struct DocumentChange: Codable, Equatable, Sendable {
        /// `logged` is a log entry the turn added: it records a fact and stays when the turn is undone (binder-v0 §6.10).
        public enum Verb: String, Codable, Sendable { case corrected, moved, filed, logged }
        public let verb: Verb
        public let title: String
        public let opIDs: [String]
        /// A move's two paths, as the op gave them.
        public let from: String?
        public let to: String?
        public init(verb: Verb, title: String, opIDs: [String], from: String? = nil, to: String? = nil) {
            self.verb = verb; self.title = title; self.opIDs = opIDs; self.from = from; self.to = to
        }
    }

    public struct TurnDocuments: Codable, Equatable, Sendable {
        public let at: Date
        public var changes: [DocumentChange]
        public var undone = false

        /// Whether Undo has anything to reverse here: a log entry stays.
        public var undoable: Bool { changes.contains { $0.verb != .logged } }

        /// One line for the conversation: each kind of change with its count, and up to three titles. A log entry is said
        /// to stay, so the turn's Undo promises nothing it does not do.
        public var summary: String {
            let kinds: [(DocumentChange.Verb, String)] = [(.filed, "Filed"), (.corrected, "Corrected"), (.moved, "Moved"), (.logged, "Logged")]
            return kinds.compactMap { verb, word -> String? in
                let titles = changes.filter { $0.verb == verb }.map(\.title)
                guard !titles.isEmpty else { return nil }
                let names = titles.prefix(3).joined(separator: ", ") + (titles.count > 3 ? ", …" : "")
                if verb == .logged { return "Logged \(titles.count) entr\(titles.count == 1 ? "y" : "ies"), which Undo keeps: \(names)" }
                return "\(word) \(titles.count) document\(titles.count == 1 ? "" : "s"): \(names)"
            }.joined(separator: ". ")
        }
    }

    private var documents: URL { root.appendingPathComponent("documents", isDirectory: true) }
    private func documentsFile(_ turn: UUID) -> URL { documents.appendingPathComponent("turn-\(turn.uuidString).json") }

    /// The catalog's documents as `record` stamps them, read before a tool's op so `noteDocumentChange` can tell whether
    /// anything else changed them. Nil when the catalog cannot be read.
    public func documentsStamp(_ folder: URL) -> Data? { try? Self.stamp(folder) }

    /// Written right after the op, on the binder's command queue. `stampBefore` is `documentsStamp` as read just before
    /// the op: when the last record's stamp still equals it, nothing but this turn's own tools changed the documents
    /// since, and the stamp moves on to the catalog as the op left it. Otherwise it stays, the turn's record finds the
    /// documents changed, and its file Undo is refused as before.
    public func noteDocumentChange(_ change: DocumentChange, turn: UUID, in folder: URL, stampBefore: Data?, now: Date = Date()) throws {
        try AtomicFile.makePrivateFolder(root); try AtomicFile.makePrivateFolder(documents)
        var record = try documentChanges(forTurn: turn) ?? TurnDocuments(at: now, changes: [])
        if record.changes.isEmpty { pruneDocuments(now: now) }
        record.changes.append(change)
        try AtomicFile.write(try JSONEncoder().encode(record), to: documentsFile(turn))
        // Only after the change is kept: a change with no line and no Undo must still stop the file Undo.
        if let stampBefore, (try? Data(contentsOf: catalogStamp)) == stampBefore, let after = try? Self.stamp(folder) {
            try AtomicFile.write(after, to: catalogStamp)
        }
    }

    public func documentChanges(forTurn turn: UUID) throws -> TurnDocuments? {
        guard let data = try? Data(contentsOf: documentsFile(turn)) else { return nil }
        guard let record = try? JSONDecoder().decode(TurnDocuments.self, from: data) else { throw Refused.damaged }
        return record
    }

    public func markDocumentsUndone(forTurn turn: UUID) throws {
        guard var record = try documentChanges(forTurn: turn) else { return }
        record.undone = true
        try AtomicFile.write(try JSONEncoder().encode(record), to: documentsFile(turn))
    }

    private func pruneDocuments(now: Date) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: documents.path)) ?? [] {
            let url = documents.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(TurnDocuments.self, from: data),
                  now.timeIntervalSince(record.at) > TimeInterval(Self.keepDays * 86_400) else { continue }
            try? manager.removeItem(at: url)
        }
    }

    /// A turn's file changes with its own document moves taken out, written as they stand once those moves are undone.
    /// The move's Undo is the op's: it takes the file back with its record. So a file the turn only moved is no change
    /// here, and one it also edited is a change at the path it came from. The turn's Undo reverses the document ops
    /// first; a move that could not go back leaves its file where this entry does not expect it, which is a conflict that
    /// changes nothing. A file the turn made and then moved (`existed`, the paths before the turn, does not hold where it
    /// came from) is a new file at the path it was made at, where the move's Undo puts it back. A pair that does not look
    /// like a plain move (something else now at the old path, or already at the new one before the turn) is left as it
    /// was recorded.
    static func withoutMoves(_ changes: [Change], moves: [(from: String, to: String)], existed: Set<String> = []) -> [Change] {
        // Where each moved file ended, by folded path, and the path it started from: a file moved twice is one move.
        var origin: [String: String] = [:]
        for move in moves {
            let first = origin.removeValue(forKey: DocumentPaths.fold(move.from)) ?? move.from
            origin[DocumentPaths.fold(move.to)] = first
        }
        var result = changes
        for (final, original) in origin.sorted(by: { $0.key < $1.key }) where DocumentPaths.fold(original) != final {
            guard let there = result.firstIndex(where: { DocumentPaths.fold($0.path) == final }), result[there].before == nil,
                  let after = result[there].after else { continue }
            guard let here = result.firstIndex(where: { DocumentPaths.fold($0.path) == DocumentPaths.fold(original) }) else {
                // Nothing changed at the path it came from. When nothing was there before the turn either, the turn made
                // the file there: it is a new file at that path.
                if !existed.contains(DocumentPaths.fold(original)) { result[there].path = original }
                continue
            }
            guard result[here].after == nil, let before = result[here].before else { continue }
            result[here].after = after
            let same = before.sameContent(as: after)
            result = result.enumerated().filter { $0.offset != there && !(same && $0.offset == here) }.map(\.element)
        }
        return result
    }
}

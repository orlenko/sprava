import Foundation
import SpravaKit

/// What a conversation turn did to the Notes section of `DASHBOARD.md`, which the turn's file entry does not cover: that file has
/// one writer, Sprava. Written before the change, so a change with no way back cannot happen.
extension TurnHistory {
    public struct TurnNotes: Codable, Equatable, Sendable {
        public let at: Date
        public let before: String
        public var after: String
        public var undone = false
    }

    private var notes: URL { root.appendingPathComponent("notes", isDirectory: true) }
    private func notesFile(_ turn: UUID) -> URL { notes.appendingPathComponent("turn-\(turn.uuidString).json") }

    /// A turn's first change sets what Undo goes back to; later ones only what it expects to find.
    public func noteNotesChange(before: String, after: String, turn: UUID, now: Date = Date()) throws {
        try AtomicFile.makePrivateFolder(root); try AtomicFile.makePrivateFolder(notes)
        var record = try notesChange(forTurn: turn)
        if record == nil { pruneNotes(now: now) }
        if record == nil { record = TurnNotes(at: now, before: before, after: after) } else { record?.after = after }
        try AtomicFile.write(try JSONEncoder().encode(record), to: notesFile(turn))
    }

    public func notesChange(forTurn turn: UUID) throws -> TurnNotes? {
        guard let data = try? Data(contentsOf: notesFile(turn)) else { return nil }
        guard let record = try? JSONDecoder().decode(TurnNotes.self, from: data) else { throw Refused.damaged }
        return record
    }

    public func markNotesUndone(forTurn turn: UUID) throws {
        guard var record = try notesChange(forTurn: turn) else { return }
        record.undone = true
        try AtomicFile.write(try JSONEncoder().encode(record), to: notesFile(turn))
    }

    private func pruneNotes(now: Date) {
        let manager = FileManager.default
        for name in (try? manager.contentsOfDirectory(atPath: notes.path)) ?? [] {
            let url = notes.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url), let record = try? JSONDecoder().decode(TurnNotes.self, from: data),
                  now.timeIntervalSince(record.at) > TimeInterval(Self.keepDays * 86_400) else { continue }
            try? manager.removeItem(at: url)
        }
    }
}

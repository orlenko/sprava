import Foundation
import SpravaKit

/// Runtime-authenticated app lines and their durable acceptance receipts (conversation.md §§3.2, 6.2).
/// Stored outside binders: a copied transcript or binder file cannot become an accepted app request.
/// This journal grants no binder admission, model consent or operation capability. Its caller must
/// already authenticate the app and resolve the current binder connection before every operation.
public final class ConversationTurnStore: Sendable {
    public enum Phase: String, Sendable { case accepted, running, replied, interrupted, failed }
    public enum Refused: Error, Equatable { case invalidLine, requestConflict, missingTurn, invalidTransition, historyFull, damagedState }

    public struct Record: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible {
        public let conversationID: UUID
        public let requestID: UUID
        public let turnID: UUID
        public let text: String
        public let reply: String?
        public let phase: Phase
        public let createdAt: Date
        public var description: String { "<private conversation turn>" }
        public var debugDescription: String { description }
    }

    public static let maximumLineBytes = 4 * 1024 * 1024
    public static let maximumHistoryBytes = 64 * 1024 * 1024
    public static let maximumTurns = 10_000
    private let state: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        """
        CREATE TABLE conversation_turns (
            ordinal INTEGER PRIMARY KEY AUTOINCREMENT,
            conversation_id TEXT NOT NULL,
            request_id TEXT NOT NULL,
            turn_id TEXT NOT NULL UNIQUE,
            text TEXT NOT NULL CHECK(length(CAST(text AS BLOB)) <= 4194304),
            reply TEXT CHECK(length(CAST(reply AS BLOB)) <= 4194304),
            phase TEXT NOT NULL CHECK(phase IN ('accepted', 'running', 'replied', 'interrupted', 'failed')),
            created_at TEXT NOT NULL,
            UNIQUE(conversation_id, request_id)
        ) STRICT
        """
    ])

    /// Production: binder-store/conversation.sqlite. Tests supply invented private support folders.
    public init(at url: URL) throws { state = try StateStore.open(url, schema: Self.schema) }

    /// Acceptance returns only after the exact line and stable turn id commit. A lost reply recovers
    /// that receipt; reusing the request id for different words refuses without changing the old line.
    public func accept(conversationID: UUID, requestID: UUID, text: String, now: Date = Date()) throws -> Record {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= Self.maximumLineBytes else { throw Refused.invalidLine }
        return try state.write { t in
            if let old = try Self.find(t, conversationID, requestID) {
                guard old.text == text else { throw Refused.requestConflict }
                return old
            }
            try Self.checkRoom(t, conversationID, adding: text.utf8.count, newTurn: true)
            let turn = UUID()
            try t.execute("""
                INSERT INTO conversation_turns (conversation_id, request_id, turn_id, text, phase, created_at)
                VALUES (?, ?, ?, ?, 'accepted', ?)
                """, .text(conversationID.uuidString), .text(requestID.uuidString), .text(turn.uuidString),
                .text(text), .text(ISOTime.string(now)))
            guard let saved = try Self.find(t, conversationID, requestID) else { throw Refused.damagedState }
            return saved
        }
    }

    /// Exactly one worker may start an accepted turn, even through independent SQLite connections.
    /// False recovers a running/finished receipt; it is never permission to launch the engine again.
    public func claim(conversationID: UUID, requestID: UUID) throws -> Bool {
        try state.write { t in
            guard let old = try Self.find(t, conversationID, requestID) else { throw Refused.missingTurn }
            guard old.phase == .accepted else { return false }
            return try t.execute("UPDATE conversation_turns SET phase = 'running' WHERE conversation_id = ? AND request_id = ? AND phase = 'accepted'",
                                 .text(conversationID.uuidString), .text(requestID.uuidString)) == 1
        }
    }

    /// Persist completion before showing a successful reply. Interrupted/failed output is discarded.
    /// Completing twice is idempotent only for the exact same outcome and text.
    public func finish(conversationID: UUID, requestID: UUID, phase: Phase, reply: String? = nil) throws -> Record {
        guard [.replied, .interrupted, .failed].contains(phase),
              phase == .replied ? reply.map({ !$0.isEmpty && $0.utf8.count <= Self.maximumLineBytes }) == true : reply == nil else {
            throw Refused.invalidTransition
        }
        return try state.write { t in
            guard let old = try Self.find(t, conversationID, requestID) else { throw Refused.missingTurn }
            if old.phase == phase, old.reply == reply { return old }
            guard old.phase == .running || (old.phase == .accepted && phase != .replied) else {
                throw Refused.invalidTransition
            }
            try Self.checkRoom(t, conversationID, adding: reply?.utf8.count ?? 0)
            try t.execute("UPDATE conversation_turns SET phase = ?, reply = ? WHERE conversation_id = ? AND request_id = ?",
                          .text(phase.rawValue), reply.map(StateValue.text) ?? .null,
                          .text(conversationID.uuidString), .text(requestID.uuidString))
            guard let saved = try Self.find(t, conversationID, requestID) else { throw Refused.damagedState }
            return saved
        }
    }

    public func record(conversationID: UUID, requestID: UUID) throws -> Record? {
        try state.read { try Self.find($0, conversationID, requestID) }
    }

    /// App-owned history only, never imported/Terminal transcript rows. Bounded per conversation.
    /// The runtime still filters what a current consent permits when preparing a replacement context.
    public func history(conversationID: UUID) throws -> [Record] {
        try state.read { t in
            try Self.checkRoom(t, conversationID, adding: 0)
            return try t.rows("SELECT \(Self.columns) FROM conversation_turns WHERE conversation_id = ? ORDER BY ordinal",
                              .text(conversationID.uuidString)).map(Self.decode)
        }
    }

    /// After fencing the previous runtime's workers: retained person lines stay visible as interrupted,
    /// never silently replayed. This method itself starts no engine and applies no binder operation.
    public func recoverInterrupted(conversationID: UUID) throws {
        _ = try state.write { try $0.execute("UPDATE conversation_turns SET phase = 'interrupted', reply = NULL WHERE conversation_id = ? AND phase = 'running'",
                                             .text(conversationID.uuidString)) }
    }

    /// The caller must hold its session/expunge barrier before clearing canonical app history.
    public func clear(conversationID: UUID) throws {
        _ = try state.write { try $0.execute("DELETE FROM conversation_turns WHERE conversation_id = ?", .text(conversationID.uuidString)) }
    }

    private static let columns = "conversation_id, request_id, turn_id, text, reply, phase, created_at"

    private static func find(_ t: Transaction, _ conversation: UUID, _ request: UUID) throws -> Record? {
        let rows = try t.rows("SELECT \(columns) FROM conversation_turns WHERE conversation_id = ? AND request_id = ? LIMIT 2",
                              .text(conversation.uuidString), .text(request.uuidString))
        guard rows.count <= 1 else { throw Refused.damagedState }
        return try rows.first.map(decode)
    }

    private static func checkRoom(_ t: Transaction, _ conversation: UUID, adding: Int, newTurn: Bool = false) throws {
        let rows = try t.rows("SELECT coalesce(sum(length(CAST(text AS BLOB)) + coalesce(length(CAST(reply AS BLOB)), 0)), 0), count(*) FROM conversation_turns WHERE conversation_id = ?",
                              .text(conversation.uuidString))
        guard let row = rows.first, row.count == 2, let bytes = row[0].integer, bytes >= 0,
              let count = row[1].integer, count >= 0 else { throw Refused.damagedState }
        guard count <= maximumTurns, !newTurn || count < maximumTurns,
              bytes <= maximumHistoryBytes, Int64(adding) <= Int64(maximumHistoryBytes) - bytes else { throw Refused.historyFull }
    }

    private static func decode(_ row: [StateValue]) throws -> Record {
        guard row.count == 7, let c = row[0].text.flatMap(UUID.init(uuidString:)),
              let r = row[1].text.flatMap(UUID.init(uuidString:)), let turn = row[2].text.flatMap(UUID.init(uuidString:)),
              let text = row[3].text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.utf8.count <= maximumLineBytes, let phase = row[5].text.flatMap(Phase.init(rawValue:)),
              let at = row[6].text.flatMap(ISOTime.date) else { throw Refused.damagedState }
        let reply = row[4].text
        guard phase == .replied ? reply.map({ !$0.isEmpty && $0.utf8.count <= maximumLineBytes }) == true : reply == nil else {
            throw Refused.damagedState
        }
        return Record(conversationID: c, requestID: r, turnID: turn, text: text, reply: reply, phase: phase, createdAt: at)
    }
}

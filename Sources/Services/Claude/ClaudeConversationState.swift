import Darwin
import Foundation
import SpravaKit

/// Runtime bookkeeping, never binder authority or imported history. Worker identity commits before
/// stdin; restart recovery must fence it before recovering an interrupted conversation receipt.
final class ClaudeConversationState: Sendable {
    struct Account: Sendable { let program: URL; let hash: String }
    struct Session: Sendable {
        let connection: UUID
        let generation: UUID
        let native: UUID
        let hash: String
        let resumed: Bool
        let worker: Int32?
        let started: Double?
    }
    enum Refused: Error { case damaged, workerStillPresent }
    private let store: StateStore
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE account (id INTEGER PRIMARY KEY CHECK(id = 1), program TEXT NOT NULL, hash TEXT NOT NULL) STRICT",
        "CREATE TABLE sessions (connection TEXT PRIMARY KEY, generation TEXT NOT NULL, native TEXT NOT NULL, hash TEXT NOT NULL, resumed INTEGER NOT NULL CHECK(resumed IN (0,1)), worker INTEGER, started REAL) STRICT"
    ])
    init(at url: URL) throws { store = try StateStore.open(url, schema: Self.schema) }
    func account() throws -> Account? {
        try store.read { t in
            let rows = try t.rows("SELECT program, hash FROM account")
            guard rows.count <= 1 else { throw Refused.damaged }
            guard let row = rows.first else { return nil }
            guard let path = row[0].text, path.hasPrefix("/"), !path.contains("\0"),
                  let hash = row[1].text, !hash.isEmpty, hash.utf8.count <= 256 else { throw Refused.damaged }
            return Account(program: URL(fileURLWithPath: path), hash: hash)
        }
    }
    func setAccount(_ value: Account?) throws {
        try store.write { t in
            try t.execute("DELETE FROM account")
            if let value {
                try t.execute("INSERT INTO account VALUES (1, ?, ?)", .text(value.program.path), .text(value.hash))
            }
        }
    }
    func allSessions() throws -> [Session] {
        try store.read { try $0.rows("SELECT connection, generation, native, hash, resumed, worker, started FROM sessions").map(Self.decode) }
    }
    func session(connection: UUID, generation: UUID, hash: String) throws -> Session {
        try store.write { t in
            let rows = try t.rows("SELECT connection, generation, native, hash, resumed, worker, started FROM sessions WHERE connection = ?", .text(connection.uuidString))
            guard rows.count <= 1 else { throw Refused.damaged }
            if let row = rows.first {
                let previous = try Self.decode(row)
                guard previous.worker == nil else { throw Refused.workerStillPresent }
                if previous.generation == generation && previous.hash == hash { return previous }
            }
            let native = UUID()
            try t.execute("INSERT OR REPLACE INTO sessions VALUES (?, ?, ?, ?, 0, NULL, NULL)",
                          .text(connection.uuidString), .text(generation.uuidString), .text(native.uuidString), .text(hash))
            return Session(connection: connection, generation: generation, native: native, hash: hash, resumed: false, worker: nil, started: nil)
        }
    }
    func spawned(_ session: Session, pid: Int32) throws {
        guard pid > 1, let time = ProcessCheck.startTime(pid: pid) else { throw Refused.damaged }
        try store.write { t in
            guard try t.execute("UPDATE sessions SET worker = ?, started = ? WHERE connection = ? AND generation = ? AND native = ? AND worker IS NULL",
                                .integer(Int64(pid)), .real(time.timeIntervalSince1970), .text(session.connection.uuidString),
                                .text(session.generation.uuidString), .text(session.native.uuidString)) == 1 else { throw Refused.damaged }
        }
    }
    /// Only called after the process owner confirmed exit. Failed/interrupted native context is discarded.
    func exited(_ session: Session, succeeded: Bool) throws {
        try store.write { t in
            if succeeded {
                guard try t.execute("UPDATE sessions SET worker = NULL, started = NULL, resumed = 1 WHERE connection = ? AND native = ?",
                                    .text(session.connection.uuidString), .text(session.native.uuidString)) == 1 else { throw Refused.damaged }
            } else {
                try t.execute("DELETE FROM sessions WHERE connection = ? AND native = ?", .text(session.connection.uuidString), .text(session.native.uuidString))
            }
        }
    }
    func forget(connection: UUID) throws {
        try store.write { t in
            guard try t.rows("SELECT 1 FROM sessions WHERE connection = ? AND worker IS NOT NULL", .text(connection.uuidString)).isEmpty else { throw Refused.workerStillPresent }
            try t.execute("DELETE FROM sessions WHERE connection = ?", .text(connection.uuidString))
        }
    }
    private static func decode(_ row: [StateValue]) throws -> Session {
        guard row.count == 7, let connection = row[0].text.flatMap(UUID.init(uuidString:)),
              let generation = row[1].text.flatMap(UUID.init(uuidString:)), let native = row[2].text.flatMap(UUID.init(uuidString:)),
              let hash = row[3].text, !hash.isEmpty, let resumed = row[4].integer, [0,1].contains(resumed) else { throw Refused.damaged }
        let worker: Int32?
        if let raw = row[5].integer { guard raw > 1, raw <= Int32.max else { throw Refused.damaged }; worker = Int32(raw) }
        else { guard row[5] == .null else { throw Refused.damaged }; worker = nil }
        let started: Double?
        if case .real(let value) = row[6] { guard value.isFinite, value > 0 else { throw Refused.damaged }; started = value }
        else { guard row[6] == .null else { throw Refused.damaged }; started = nil }
        guard (worker == nil) == (started == nil) else { throw Refused.damaged }
        return Session(connection: connection, generation: generation, native: native, hash: hash, resumed: resumed == 1, worker: worker, started: started)
    }
}

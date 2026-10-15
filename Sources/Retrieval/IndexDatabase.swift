import Foundation
import SQLite3
import SQLiteDefensive
import SpravaKit

/// One connection to an index file, with SQLite's defensive settings (binder-v0 §7.2): defensive mode, an untrusted
/// schema, cell size checks, no memory mapping. The file is rebuildable, so commits are not flushed one by one
/// (architecture 5.5); deleted text is overwritten (`secure_delete`).
final class IndexDatabase {
    private var db: OpaquePointer?

    init(path: String) throws {
        let opened = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil)
        guard opened == SQLITE_OK, let db else { close(); throw BinderIndex.Failure("the index cannot be opened (code \(opened))") }
        guard sprava_sqlite_defensive(db) == SQLITE_OK else { close(); throw BinderIndex.Failure("the index cannot be made defensive") }
        sqlite3_busy_timeout(db, 10_000)
        do {
            for pragma in ["trusted_schema=OFF", "cell_size_check=ON", "mmap_size=0", "journal_mode=DELETE", "synchronous=NORMAL",
                           "secure_delete=ON", "max_page_count=\(BinderIndex.maxFilePages)"] { _ = try rows("PRAGMA " + pragma) }
        } catch { close(); throw error }
    }

    deinit { close() }

    func close() { if let db { sqlite3_close_v2(db) }; db = nil }

    func execute(_ sql: String, _ values: StateValue...) throws { _ = try rows(sql, values) }

    func rows(_ sql: String, _ values: StateValue...) throws -> [[StateValue]] { try rows(sql, values) }

    /// Runs one statement with text and integer values; text comes back as text, integers as integers.
    func rows(_ sql: String, _ values: [StateValue]) throws -> [[StateValue]] {
        guard let db else { throw BinderIndex.Failure("the index is closed") }
        var statement: OpaquePointer?
        let prepared = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        guard prepared == SQLITE_OK, let statement else { throw failure("prepare", prepared) }
        defer { sqlite3_finalize(statement) }
        for (i, value) in values.enumerated() {
            let position = Int32(i + 1)
            let bound: Int32 = switch value {
            case .integer(let v): sqlite3_bind_int64(statement, position, v)
            // The byte count, not -1: a NUL inside the text would otherwise end it.
            case .text(let v): sqlite3_bind_text64(statement, position, v, UInt64(v.utf8.count), Self.transient, UInt8(SQLITE_UTF8))
            default: sqlite3_bind_null(statement, position)
            }
            guard bound == SQLITE_OK else { throw failure("bind", bound) }
        }
        var out: [[StateValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return out }
            guard code == SQLITE_ROW else { throw failure("step", code) }
            out.append((0..<sqlite3_column_count(statement)).map { i in
                switch sqlite3_column_type(statement, i) {
                case SQLITE_INTEGER: .integer(sqlite3_column_int64(statement, i))
                case SQLITE_TEXT: .text(String(decoding: UnsafeBufferPointer(start: sqlite3_column_text(statement, i),
                                                                             count: Int(sqlite3_column_bytes(statement, i))), as: UTF8.self))
                default: .null
                }
            })
        }
    }

    /// One transaction; a throw rolls it back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            if let db, sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            throw error
        }
    }

    var lastRowID: Int64 { db.map { sqlite3_last_insert_rowid($0) } ?? 0 }

    /// SQLite's generic message for the code, never a value.
    private func failure(_ step: String, _ code: Int32) -> BinderIndex.Failure {
        BinderIndex.Failure(code & 0xff == SQLITE_FULL ? "the index is full" : "the index failed to \(step) (\(String(cString: sqlite3_errstr(code))))")
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

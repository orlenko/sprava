import Darwin
import Foundation
import SQLite3

/// Sprava's own state in SQLite (decisions.md A13): one database per owning target in the support folder, in WAL
/// mode, every read-change-write inside one `BEGIN IMMEDIATE` transaction, so writers in several processes are
/// serialized by SQLite's lock and a crash leaves the last committed state. The database is opened inside a
/// validated `StateDirectory` (this user's, not writable by others), never through a link, and created private
/// (0600). A database that cannot be opened or read throws and is left as it is; nothing starts it over.
///
/// There are no migrations before the MVP ships (A14): a schema version other than the caller's throws, naming
/// the file, and the developer deletes it.
public final class StateStore: @unchecked Sendable {
    /// A database that cannot be opened, read or written. The description names the step and SQLite's generic
    /// message for the code, never a value.
    public struct Failure: Error, CustomStringConvertible {
        public let path: String
        public let step: String
        public let code: Int32
        public var description: String {
            "\(path): \(step) failed (\(String(cString: sqlite3_errstr(code))), code \(code)); it was left as it is"
        }
    }

    /// The caller's tables. `statements` run once, when the database is new; `version` is stored in the file.
    public struct Schema: Sendable {
        public let version: Int32
        public let statements: [String]

        public init(version: Int32, statements: [String]) {
            precondition(version > 0, "schema versions start at 1")
            self.version = version
            self.statements = statements
        }
    }

    public let url: URL
    private let db: OpaquePointer
    private let lock = NSLock()

    /// Waiting for another process's write; past this, a transaction throws rather than hangs.
    static let busyTimeoutMilliseconds: Int32 = 10_000

    private init(url: URL, db: OpaquePointer) {
        self.url = url
        self.db = db
    }

    deinit { sqlite3_close_v2(db) }

    /// Opens the database at `url`, creating it and its folder when missing. Throws when the folder is a link, is
    /// not this user's or is writable by others; when anything but a regular file stands at `url`; when the file
    /// is not a database or is damaged; and when its schema version is not `schema.version`.
    public static func open(_ url: URL, schema: Schema) throws -> StateStore {
        guard url.isFileURL else { throw Failure(path: url.path, step: "open", code: SQLITE_MISUSE) }
        guard let folder = try StateDirectory.open(url.deletingLastPathComponent(), create: true) else {
            throw Failure(path: url.path, step: "open the folder", code: SQLITE_CANTOPEN)
        }
        // SQLite refuses a link anywhere in the path; the validated folder's real path has none (a system link
        // such as /var -> /private/var above the support folder is resolved here, once).
        let path = try folder.realPath() + "/" + url.lastPathComponent
        try createPrivateFile(path, shown: url.path)
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_EXRESCODE
        let opened = sqlite3_open_v2(path, &handle, flags, nil)
        guard let handle else { throw Failure(path: url.path, step: "open", code: SQLITE_NOMEM) }
        guard opened == SQLITE_OK else {
            sqlite3_close_v2(handle)
            throw Failure(path: url.path, step: "open", code: opened)
        }
        let store = StateStore(url: url, db: handle)
        sqlite3_busy_timeout(handle, busyTimeoutMilliseconds)
        try store.configure()
        try store.prepareSchema(schema)
        return store
    }

    /// A transaction that may change the database: `BEGIN IMMEDIATE` takes the write lock first, so the reads
    /// inside it see the state the change is based on. A throw from `body` rolls everything back.
    public func write<T>(_ body: (Transaction) throws -> T) throws -> T {
        try transaction("BEGIN IMMEDIATE", body)
    }

    /// A read-only snapshot: everything `body` reads comes from one committed state.
    public func read<T>(_ body: (Transaction) throws -> T) throws -> T {
        try transaction("BEGIN DEFERRED", body)
    }

    private func transaction<T>(_ begin: String, _ body: (Transaction) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try exec(begin, step: "begin")
        let result: T
        do {
            result = try body(Transaction(store: self))
            try exec("COMMIT", step: "commit")
        } catch {
            if sqlite3_get_autocommit(db) == 0 { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) }
            throw error
        }
        return result
    }

    private func configure() throws {
        let mode = try transactionless("PRAGMA journal_mode=WAL", step: "set WAL mode")
        guard mode.first?.first?.text?.lowercased() == "wal" else {
            throw Failure(path: url.path, step: "set WAL mode", code: SQLITE_ERROR)
        }
        try exec("PRAGMA synchronous=FULL", step: "set synchronous")
        try exec("PRAGMA foreign_keys=ON", step: "enable foreign keys")
        try exec("PRAGMA trusted_schema=OFF", step: "distrust the schema")
    }

    private func prepareSchema(_ schema: Schema) throws {
        try write { t in
            let stored = try t.rows("PRAGMA user_version").first?.first?.integer ?? 0
            if stored == Int64(schema.version) { return }
            let tables = try t.rows("SELECT count(*) FROM sqlite_schema").first?.first?.integer ?? 0
            guard stored == 0, tables == 0 else {
                throw Failure(path: url.path, step: "match schema version \(schema.version) (found \(stored); "
                              + "there are no migrations before the MVP, decisions.md A14: delete the file)",
                              code: SQLITE_SCHEMA)
            }
            try t.execute(Transaction.documentsTable)
            for statement in schema.statements { try t.execute(statement) }
            try t.execute("PRAGMA user_version = \(schema.version)")
        }
    }

    /// The file is made here, private, so SQLite (which gives its -wal and -shm files the database's mode) never
    /// creates it with the umask's mode. An existing entry must be this user's regular file.
    private static func createPrivateFile(_ path: String, shown: String) throws {
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd >= 0 { close(fd); return }
        guard errno == EEXIST else { throw Failure(path: shown, step: "create", code: SQLITE_CANTOPEN) }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw Failure(path: shown, step: "open a regular file", code: SQLITE_CANTOPEN)
        }
    }

    fileprivate func exec(_ sql: String, step: String) throws {
        let code = sqlite3_exec(db, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw Failure(path: url.path, step: step, code: code) }
    }

    private func transactionless(_ sql: String, step: String) throws -> [[StateValue]] {
        try Transaction(store: self).rows(sql)
    }

    fileprivate func statement(_ sql: String, _ values: [StateValue]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v3(db, sql, -1, 0, &statement, nil)
        guard code == SQLITE_OK, let statement else { throw Failure(path: url.path, step: "prepare", code: code) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1), bound: Int32
            switch value {
            case .null: bound = sqlite3_bind_null(statement, position)
            case .integer(let v): bound = sqlite3_bind_int64(statement, position, v)
            case .real(let v): bound = sqlite3_bind_double(statement, position, v)
            case .text(let v):
                // The byte count, not -1: a NUL inside the text would otherwise end it.
                let bytes = Array(v.utf8)
                bound = bytes.isEmpty ? sqlite3_bind_text(statement, position, "", 0, Self.transient)
                    : bytes.withUnsafeBufferPointer { buffer in
                        buffer.withMemoryRebound(to: CChar.self) {
                            sqlite3_bind_text64(statement, position, $0.baseAddress, UInt64($0.count), Self.transient,
                                                UInt8(SQLITE_UTF8))
                        }
                    }
            case .blob(let v):
                bound = v.isEmpty ? sqlite3_bind_zeroblob(statement, position, 0) : v.withUnsafeBytes {
                    sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient)
                }
            }
            guard bound == SQLITE_OK else {
                sqlite3_finalize(statement)
                throw Failure(path: url.path, step: "bind", code: bound)
            }
        }
        return statement
    }

    fileprivate func failure(_ step: String, _ code: Int32) -> Failure { Failure(path: url.path, step: step, code: code) }

    fileprivate var changes: Int { Int(sqlite3_changes64(db)) }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

/// One value in a row or a parameter, in SQLite's own types.
public enum StateValue: Equatable, Sendable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    public var integer: Int64? { if case .integer(let v) = self { v } else { nil } }
    public var real: Double? { if case .real(let v) = self { v } else { nil } }
    public var text: String? { if case .text(let v) = self { v } else { nil } }
    public var blob: Data? { if case .blob(let v) = self { v } else { nil } }
}

/// The statements of one transaction. It is valid only inside the `read` or `write` closure that received it.
public struct Transaction {
    fileprivate let store: StateStore

    static let documentsTable = "CREATE TABLE sprava_documents (key TEXT PRIMARY KEY, value BLOB NOT NULL) WITHOUT ROWID"

    /// Runs one statement, ignoring any rows; returns the number of rows it changed.
    @discardableResult
    public func execute(_ sql: String, _ values: StateValue...) throws -> Int {
        let statement = try store.statement(sql, values)
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return store.changes }
            guard code == SQLITE_ROW else { throw store.failure("step", code) }
        }
    }

    /// Runs one query and returns its rows, each a list of column values in order.
    public func rows(_ sql: String, _ values: StateValue...) throws -> [[StateValue]] {
        try rows(sql, values)
    }

    func rows(_ sql: String, _ values: [StateValue]) throws -> [[StateValue]] {
        let statement = try store.statement(sql, values)
        defer { sqlite3_finalize(statement) }
        var result: [[StateValue]] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return result }
            guard code == SQLITE_ROW else { throw store.failure("step", code) }
            result.append((0..<sqlite3_column_count(statement)).map { Self.column(statement, $0) })
        }
    }

    private static func column(_ statement: OpaquePointer, _ index: Int32) -> StateValue {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: return .integer(sqlite3_column_int64(statement, index))
        case SQLITE_FLOAT: return .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_text(statement, index) else { return .text("") }
            return .text(String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self))
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            guard let bytes = sqlite3_column_blob(statement, index) else { return .blob(Data()) }
            return .blob(Data(bytes: bytes, count: count))
        default: return .null
        }
    }

    /// A Codable value kept whole under a key, for state that is read and replaced as one document (the way a
    /// JSON state file was). nil when the key is absent; a stored value that does not decode throws.
    public func document<T: Decodable>(_ type: T.Type, key: String, decoder: JSONDecoder = JSONDecoder()) throws -> T? {
        guard let data = try rows("SELECT value FROM sprava_documents WHERE key = ?", .text(key)).first?.first?.blob
        else { return nil }
        do { return try decoder.decode(T.self, from: data) }
        catch { throw store.failure("decode the document under \(key)", SQLITE_MISMATCH) }
    }

    public func setDocument<T: Encodable>(_ value: T, key: String, encoder: JSONEncoder = Transaction.encoder) throws {
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw store.failure("encode the document under \(key)", SQLITE_MISMATCH) }
        try execute("INSERT OR REPLACE INTO sprava_documents (key, value) VALUES (?, ?)", .text(key), .blob(data))
    }

    public func removeDocument(key: String) throws {
        try execute("DELETE FROM sprava_documents WHERE key = ?", .text(key))
    }

    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

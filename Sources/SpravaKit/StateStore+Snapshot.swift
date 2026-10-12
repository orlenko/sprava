import Darwin
import Foundation
import SQLite3

extension StateStore {
    /// A standalone, consistent copy of a live state database, including committed WAL pages (decisions.md A13).
    /// The source is opened read-only; the destination must be new. No sidecar is needed to restore the copy.
    public static func snapshot(_ source: URL, to destination: URL) throws {
        let sourcePath = try snapshotPath(source, create: false)
        var info = stat()
        guard lstat(sourcePath, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid() else {
            throw Failure(path: source.path, step: "snapshot a regular database", code: SQLITE_CANTOPEN)
        }
        let destinationPath = try snapshotPath(destination, create: true)
        let file = Darwin.open(destinationPath, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Failure(path: destination.path, step: "create a new snapshot", code: SQLITE_CANTOPEN) }
        close(file)
        var completed = false
        defer { if !completed { unlink(destinationPath) } }
        let input = try snapshotConnection(sourcePath, shown: source.path, flags: SQLITE_OPEN_READONLY)
        defer { sqlite3_close_v2(input) }
        let output = try snapshotConnection(destinationPath, shown: destination.path, flags: SQLITE_OPEN_READWRITE)
        defer { sqlite3_close_v2(output) }
        for statement in ["PRAGMA trusted_schema=OFF", "PRAGMA synchronous=FULL", "PRAGMA fullfsync=ON", "PRAGMA journal_mode=DELETE"] {
            let code = sqlite3_exec(output, statement, nil, nil, nil)
            guard code == SQLITE_OK else { throw Failure(path: destination.path, step: "configure snapshot", code: code) }
        }
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else {
            throw Failure(path: destination.path, step: "begin snapshot", code: sqlite3_errcode(output))
        }
        // One attempt with SQLite's busy timeout; no loop that a busy writer can keep restarting forever.
        let copied = sqlite3_backup_step(backup, -1)
        let finished = sqlite3_backup_finish(backup)
        guard copied == SQLITE_DONE, finished == SQLITE_OK else {
            throw Failure(path: destination.path, step: "copy snapshot", code: copied == SQLITE_DONE ? finished : copied)
        }
        completed = true
    }

    private static func snapshotPath(_ url: URL, create: Bool) throws -> String {
        guard url.isFileURL, let folder = try StateDirectory.open(url.deletingLastPathComponent(), create: create) else {
            throw Failure(path: url.path, step: "open snapshot folder", code: SQLITE_CANTOPEN)
        }
        return try folder.realPath() + "/" + url.lastPathComponent
    }

    private static func snapshotConnection(_ path: String, shown: String, flags: Int32) throws -> OpaquePointer {
        var database: OpaquePointer?
        let code = sqlite3_open_v2(path, &database, flags | SQLITE_OPEN_NOFOLLOW | SQLITE_OPEN_FULLMUTEX, nil)
        guard code == SQLITE_OK, let database else {
            if let database { sqlite3_close_v2(database) }
            throw Failure(path: shown, step: "open snapshot database", code: code)
        }
        sqlite3_busy_timeout(database, busyTimeoutMilliseconds)
        return database
    }
}

import Darwin
import Foundation

/// Whole-file writes that are either old or new, never torn: a same-folder temporary file created exclusively
/// under a random dotted name, flushed with `F_FULLFSYNC`, renamed into place, then the folder flushed
/// (binder-v0 §3.6, §4.9; architecture 3.4).
public enum AtomicFile {
    public struct Failure: Error, CustomStringConvertible {
        public let step: String
        public let code: Int32
        public var description: String { "\(step): \(String(cString: strerror(code)))" }

        package init(step: String, code: Int32) {
            self.step = step
            self.code = code
        }
    }

    /// The flushing system calls, replaceable in tests to make them fail.
    struct Flush: Sendable {
        var fullSync: @Sendable (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) }
        var sync: @Sendable (Int32) -> Int32 = { fsync($0) }
        var openFolder: @Sendable (String) -> Int32 = { open($0, O_RDONLY | O_CLOEXEC) }
    }

    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
        try write(data, to: url, mode: mode, flush: Flush())
    }

    /// Every flush is required: plain `fsync` does not reach stable storage on macOS, so a failed `F_FULLFSYNC`
    /// fails the write, and so does a folder that cannot be opened or flushed after the rename (binder-v0 §4.9).
    /// The one exception is a volume without `F_FULLFSYNC` (exFAT, FAT, SMB, AFP): there `fsync` is the best
    /// flush there is, and only its failure fails the write.
    static func write(_ data: Data, to url: URL, mode: mode_t, flush: Flush) throws {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw Failure(step: "create temp", code: errno) }
        var ok = false
        defer {
            if !ok { unlink(temp.path) }
        }
        do {
            defer { close(fd) }
            try data.withUnsafeBytes { buffer in
                var offset = 0
                while offset < buffer.count {
                    let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                    if n < 0 {
                        if errno == EINTR { continue }
                        throw Failure(step: "write", code: errno)
                    }
                    offset += n
                }
            }
            try flushToDisk(fd, step: "fsync", flush: flush)
        }
        guard rename(temp.path, url.path) == 0 else { throw Failure(step: "rename", code: errno) }
        ok = true
        try flushFolder(folder, step: "fsync folder", openStep: "open folder", open: flush.openFolder,
                        fullSync: flush.fullSync, sync: flush.sync)
    }

    private static func flushToDisk(_ fd: Int32, step: String, flush: Flush) throws {
        try flushToDisk(fd, step: step, fullSync: flush.fullSync, sync: flush.sync)
    }

    /// The one flush rule for every Sprava writer (binder-v0 §4.9, §6.9 step 3): `F_FULLFSYNC`, or `fsync` only
    /// when the volume does not support it (`ENOTSUP`, `EINVAL`, `ENOTTY`); an interrupted call is tried again,
    /// and any other failure throws. The system calls are replaceable for tests.
    package static func flushToDisk(_ fd: Int32, step: String,
                                    fullSync: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) },
                                    sync: (Int32) -> Int32 = { fsync($0) }) throws {
        while fullSync(fd) < 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == ENOTSUP || code == EINVAL || code == ENOTTY else { throw Failure(step: step, code: code) }
            try retrying(step) { sync(fd) }
            return
        }
    }

    /// Flushes a folder by the same rule, so a rename or a move in it survives a power loss (binder-v0 §4.9
    /// step 7). A folder that cannot be opened (`openStep`, or `step` when not given) or flushed throws.
    package static func flushFolder(_ url: URL, step: String, openStep: String? = nil,
                                    open openFolder: (String) -> Int32 = { open($0, O_RDONLY | O_CLOEXEC) },
                                    fullSync: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) },
                                    sync: (Int32) -> Int32 = { fsync($0) }) throws {
        var dirfd: Int32 = -1
        try retrying(openStep ?? step) {
            dirfd = openFolder(url.path)
            return dirfd
        }
        defer { close(dirfd) }
        try flushToDisk(dirfd, step: step, fullSync: fullSync, sync: sync)
    }

    /// Runs a call that returns -1 and sets `errno` on failure, again while it is interrupted.
    private static func retrying(_ step: String, _ call: () -> Int32) throws {
        while call() < 0 {
            let code = errno
            if code != EINTR { throw Failure(step: step, code: code) }
        }
    }

    /// Creates a private folder (0700) and its parents.
    public static func makePrivateFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    private static let logLock = NSLock()

    /// Appends one line to a log, rotating at `limit` bytes and keeping `keep` old files
    /// (`jobs.log`, `jobs.log.1` ...; architecture 2.3). One append at a time in this process, so two jobs never
    /// rotate together and drop the previous log.
    public static func appendLine(_ line: String, to url: URL, limit: Int = 10_000_000, keep: Int = 5) {
        logLock.lock()
        defer { logLock.unlock() }
        let fm = FileManager.default
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size >= limit {
            for i in stride(from: keep - 1, through: 1, by: -1) {
                let from = url.path + ".\(i)"
                if fm.fileExists(atPath: from) {
                    try? fm.removeItem(atPath: url.path + ".\(i + 1)")
                    try? fm.moveItem(atPath: from, toPath: url.path + ".\(i + 1)")
                }
            }
            try? fm.removeItem(atPath: url.path + ".1")
            try? fm.moveItem(atPath: url.path, toPath: url.path + ".1")
            try? fm.removeItem(atPath: url.path + ".\(keep + 1)")
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let bytes = Array((line.hasSuffix("\n") ? line : line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }
    }
}

/// ISO 8601 with the local offset, as the heartbeat schema's examples show.
public enum ISOTime {
    public static func string(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = timeZone
        return f.string(from: date)
    }

    public static func date(_ text: String?) -> Date? { text.flatMap(Timestamp.parse) }
}

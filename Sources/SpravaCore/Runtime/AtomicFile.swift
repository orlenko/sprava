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
    }

    public static func write(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
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
            if fcntl(fd, F_FULLFSYNC) != 0, fsync(fd) != 0 { throw Failure(step: "fsync", code: errno) }
        }
        guard rename(temp.path, url.path) == 0 else { throw Failure(step: "rename", code: errno) }
        ok = true
        let dirfd = open(folder.path, O_RDONLY | O_CLOEXEC)
        if dirfd >= 0 {
            fsync(dirfd)
            close(dirfd)
        }
    }

    /// Creates a private folder (0700) and its parents.
    public static func makePrivateFolder(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// Appends one line to a log, rotating at `limit` bytes and keeping `keep` old files
    /// (`jobs.log`, `jobs.log.1` ...; architecture 2.3).
    public static func appendLine(_ line: String, to url: URL, limit: Int = 10_000_000, keep: Int = 5) {
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

import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
import Shelf
import SpravaKit

/// The intake files a `file_document` op names, hashed off the command queue (architecture 7.2): the listener runs
/// every call on the queue the person's approvals share, so a large file must never be read there.
extension MCPServer {
    /// What identifies one state of a file: a file replaced or rewritten since it was hashed has another stamp.
    struct IntakeStamp: Equatable {
        let device: Int32, inode: UInt64, size: Int64
        let modified: timespec, changed: timespec

        init(_ st: stat) {
            device = st.st_dev
            inode = st.st_ino
            size = st.st_size
            modified = st.st_mtimespec
            changed = st.st_ctimespec
        }

        static func == (a: Self, b: Self) -> Bool {
            a.device == b.device && a.inode == b.inode && a.size == b.size
                && a.modified.tv_sec == b.modified.tv_sec && a.modified.tv_nsec == b.modified.tv_nsec
                && a.changed.tv_sec == b.changed.tv_sec && a.changed.tv_nsec == b.changed.tv_nsec
        }
    }

    /// The largest intake file a brain may file; a larger one is filed in the app.
    static let intakeSizeLimit = 512 << 20
    /// The largest intake file hashed on the command queue itself, when `prepare` did not hash it first.
    static let queuedHashLimit = 1 << 20
    /// How long `prepare` may hash the files of one call.
    static let prepareSeconds: TimeInterval = 5

    /// The intake file a `file_document` op names, open, with its stamp; nil when it may not be read. Every component
    /// is opened from the binder folder down without following a link, and only a plain file of this user is
    /// opened, so a link anywhere in `intake/` never lets a brain test guesses against a file outside the binder; a
    /// key or credential file is never opened at all (binder-v0 §3.3). The caller closes the descriptor.
    static func openIntake(_ relative: String, in folder: URL) -> (fd: Int32, stamp: IntakeStamp)? {
        guard DocumentPaths.isIntake(relative), !DocumentPaths.isKeyFile(relative) else { return nil }
        let segments = relative.split(separator: "/").map(String.init)
        var dir = open(folder.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dir >= 0 else { return nil }
        for segment in segments.dropLast() {
            let next = openat(dir, segment, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(dir)
            guard next >= 0 else { return nil }
            dir = next
        }
        let fd = openat(dir, segments[segments.count - 1], O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        close(dir)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { close(fd); return nil }
        return (fd, IntakeStamp(st))
    }

    /// The lowercase hex SHA-256 of an open file, or nil when it holds more than `limit` bytes (a sparse file
    /// counts by its length) or the deadline passes.
    static func hash(_ fd: Int32, stamp: IntakeStamp, limit: Int, deadline: Date) -> String? {
        guard stamp.size <= limit else { return nil }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        var total = 0
        while true {
            guard Date() < deadline else { return nil }
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR { continue }; return nil }
            if n == 0 { break }
            total += n
            guard total <= limit else { return nil }
            hasher.update(data: buffer[0..<n])
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// The digest of an intake file, read in full within the size limit; nil when it may not be read.
    static func intakeDigest(_ relative: String, in folder: URL, deadline: Date = .distantFuture) -> String? {
        guard let (fd, stamp) = openIntake(relative, in: folder) else { return nil }
        defer { close(fd) }
        return hash(fd, stamp: stamp, limit: intakeSizeLimit, deadline: deadline)
    }

    static func prehashKey(_ relative: String, in folder: URL) -> String { folder.standardizedFileURL.path + "#" + relative }

    /// Runs off the command queue just before `handle(line:)` for the same line: hashes the intake files a
    /// propose_ops call names, within the size limit and a deadline, in the binders this client may propose to.
    /// The shelf is not consulted here, off the queue; `handle` resolves the binder and checks everything again.
    public func prepare(line: String) {
        prehashed = [:]
        guard let msg = try? JSONParser.parse(line).value, msg["method"]?.stringValue == "tools/call",
              msg["params"]?["name"]?.stringValue == "propose_ops", case .array(let ops)? = msg["params"]?["arguments"]?["ops"],
              ops.count <= Self.maxOps else { return }
        let deadline = Date().addingTimeInterval(Self.prepareSeconds)
        let folders = client.binders.filter { $0.value == "propose" }.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
        for op in ops where op["op"] == .str("file_document") {
            guard let from = op["args"]?["from"]?.stringValue else { continue }
            for folder in folders {
                guard let (fd, stamp) = Self.openIntake(from, in: folder) else { continue }
                defer { close(fd) }
                if let digest = Self.hash(fd, stamp: stamp, limit: Self.intakeSizeLimit, deadline: deadline) {
                    prehashed[Self.prehashKey(from, in: folder)] = (stamp, digest)
                }
            }
        }
    }

    /// The digest of an intake file on the command queue: the one `prepare` took, while the file is unchanged since;
    /// else a fresh one of a small file only. A large file is never read here.
    func queuedIntakeDigest(_ relative: String, in folder: URL) -> String? {
        guard let (fd, stamp) = Self.openIntake(relative, in: folder) else { return nil }
        defer { close(fd) }
        if let p = prehashed[Self.prehashKey(relative, in: folder)], p.stamp == stamp { return p.digest }
        return Self.hash(fd, stamp: stamp, limit: Self.queuedHashLimit, deadline: .distantFuture)
    }
}

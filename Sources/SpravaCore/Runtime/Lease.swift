import Darwin
import Foundation

/// The single-instance lease: an exclusive, non-blocking `flock` on `runtime/lease`. It vanishes when the
/// process dies, so a crash never leaves a stale lease (architecture 3.2).
public final class Lease: @unchecked Sendable {
    public let url: URL
    public let inode: UInt64
    private let fd: Int32

    public enum Outcome {
        case acquired(Lease)
        case held(byPID: Int32?)
    }

    private init(url: URL, fd: Int32, inode: UInt64) {
        self.url = url
        self.fd = fd
        self.inode = inode
    }

    /// Tries once and never waits. When the lock is held, the holder's pid is read from the file if present.
    public static func acquire(at url: URL) throws -> Outcome {
        try AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open lease", code: errno) }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            var buffer = [UInt8](repeating: 0, count: 32)
            let n = pread(fd, &buffer, buffer.count, 0)
            close(fd)
            guard err == EWOULDBLOCK else { throw AtomicFile.Failure(step: "flock", code: err) }
            let text = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
            return .held(byPID: Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        var info = stat()
        fstat(fd, &info)
        // Record our pid for refusals to name; the lock itself is what matters.
        ftruncate(fd, 0)
        let pid = Array("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { pwrite(fd, $0.baseAddress!, $0.count, 0) }
        return .acquired(Lease(url: url, fd: fd, inode: UInt64(info.st_ino)))
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

import Darwin
import Foundation
import SpravaKit

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
        let folder = url.deletingLastPathComponent()
        var parent = stat()
        if lstat(folder.path, &parent) != 0 {
            guard errno == ENOENT else { throw AtomicFile.Failure(step: "inspect runtime directory", code: errno) }
            try AtomicFile.makePrivateFolder(folder)
        }
        guard SafeFile.isTrustedFolder(folder) else {
            throw AtomicFile.Failure(step: "runtime directory must be trusted", code: EPERM)
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open lease", code: errno) }
        var transferred = false
        defer { if !transferred { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AtomicFile.Failure(step: "inspect lease", code: errno) }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_nlink == 1,
              info.st_mode & 0o022 == 0 else {
            throw AtomicFile.Failure(step: "lease must be a private, unshared regular file", code: EPERM)
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let err = errno
            var buffer = [UInt8](repeating: 0, count: 32)
            let n = pread(fd, &buffer, buffer.count, 0)
            guard err == EWOULDBLOCK else { throw AtomicFile.Failure(step: "flock", code: err) }
            let text = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self) : ""
            return .held(byPID: Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        // Record our pid for refusals to name; the lock itself is what matters.
        while ftruncate(fd, 0) != 0 {
            guard errno == EINTR else { throw AtomicFile.Failure(step: "truncate lease", code: errno) }
        }
        let pid = Array("\(getpid())\n".utf8)
        try pid.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = pwrite(fd, bytes.baseAddress! + offset, bytes.count - offset, off_t(offset))
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFile.Failure(step: "write lease owner", code: errno)
                }
                guard written > 0 else { throw AtomicFile.Failure(step: "write lease owner", code: EIO) }
                offset += written
            }
        }
        transferred = true
        return .acquired(Lease(url: url, fd: fd, inode: UInt64(info.st_ino)))
    }

    deinit {
        flock(fd, LOCK_UN)
        close(fd)
    }
}

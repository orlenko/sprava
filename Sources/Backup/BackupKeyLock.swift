import Darwin
import Foundation
import SpravaKit

extension BackupKey.Keychain {
    /// Readers and writers share a bounded cross-process lock. A rollback journal under this lock belongs to a
    /// stopped writer; without it, a second setup could roll back a writer that is still changing the key.
    func withLock<T>(timeout: TimeInterval = 5, _ body: () throws -> T) throws -> T {
        try AtomicFile.makePrivateFolder(lockURL.deletingLastPathComponent())
        let fd = open(lockURL.path, O_WRONLY | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw BackupKey.Failure(message: "the backup-key lock cannot be opened; nothing was changed") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw BackupKey.Failure(message: "the backup-key lock is not a regular file; nothing was changed")
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno == EINTR { continue }
            guard errno == EWOULDBLOCK, ProcessInfo.processInfo.systemUptime < deadline else {
                throw BackupKey.Failure(message: "the backup key is busy or its lock failed; nothing was changed")
            }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

import Backup
import Foundation

/// Upload gates that may prevent a binder from leaving this Mac (docs/backup.md §3.4). Each call needs its own
/// fresh result; a timed-out scan is never used by a later offload. A stalled scan leaves one thread per repository,
/// while later calls return waiting immediately so the backup job and its state lock remain available.
final class BackupUploadGate: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    let ended = DispatchGroup()

    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var gates: [String: BackupUploadGate] = [:]

    static func of(_ repository: URL) -> BackupUploadGate {
        registryLock.lock()
        defer { registryLock.unlock() }
        let path = repository.standardizedFileURL.path
        if let gate = gates[path] { return gate }
        let gate = BackupUploadGate()
        gates[path] = gate
        return gate
    }

    static func bounded(_ backup: Backup, patience: TimeInterval = 120) -> Backup {
        backup.withUploadCheck { repository in
            of(repository).check(repository, scan: backup.uploadCheck, patience: patience)
        }
    }

    private final class Result: @unchecked Sendable {
        var upload: Backup.Upload?
    }

    /// An unfinished check supplies no proof of location or upload.
    func check(_ repository: URL, scan: @escaping @Sendable (URL) -> Backup.Upload, patience: TimeInterval) -> Backup.Upload {
        guard patience.isFinite, patience >= 0 else { return .notChecked }
        lock.lock()
        guard !running else { lock.unlock(); return .notChecked }
        running = true
        ended.enter()
        lock.unlock()
        let result = Result(), done = DispatchSemaphore(value: 0)
        Thread.detachNewThread { [self] in
            result.upload = scan(repository)
            lock.lock()
            running = false
            lock.unlock()
            done.signal()
            ended.leave()
        }
        guard done.wait(timeout: .now() + patience) == .success else { return .notChecked }
        return result.upload ?? .notChecked
    }
}

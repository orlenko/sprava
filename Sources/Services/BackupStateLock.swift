import BinderStore
import Foundation

/// One read, change and write of the backup's state (`backup/state.json`, and the settings beside it) at a time in
/// this process: the backup job's requests and its scheduled work, and the setup and second-backup commands. Each of
/// them reads the state, works for a while (restic runs) and saves what it read with its changes, so two at once would
/// lose one's records: an offload's record of a binder that left, saved over by a command that read the state before.
/// The job runs on a queue of its own and the commands on the repository queue (`RequestQueues`), so neither ever
/// holds up the command queue. Only the runtime writes this state; the app reads it (`HealthSnapshot`).
public final class BackupStateLock: @unchecked Sendable {
    private let lock = NSLock()

    private static let guardLock = NSLock()
    nonisolated(unsafe) private static var locks: [String: BackupStateLock] = [:]

    /// The lock for one support folder, the same for every caller in this process.
    public static func of(_ support: URL) -> BackupStateLock {
        guardLock.lock()
        defer { guardLock.unlock() }
        let key = support.standardizedFileURL.path
        if let held = locks[key] { return held }
        let made = BackupStateLock()
        locks[key] = made
        return made
    }

    /// How long a command waits for the backup job before it gives up: well inside its watchdog budget
    /// (`RequestQueues.budgets`), with the command's own restic runs still to come.
    public static let commandPatience: TimeInterval = 120

    /// The backup job's work: it waits as long as a command before it takes.
    public func job<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    /// A command's work: it waits up to `patience` for the backup job, then fails with nothing changed, so a long
    /// first backup never makes the command hang.
    public func command<T>(patience: TimeInterval = BackupStateLock.commandPatience, _ body: () throws -> T) throws -> T {
        guard lock.lock(before: Date().addingTimeInterval(patience)) else {
            throw Commands.Failure(message: "a backup is running; try again when it has finished; nothing was changed")
        }
        defer { lock.unlock() }
        return try body()
    }
}

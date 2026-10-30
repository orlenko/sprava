import Foundation
import ServiceManagement
import SpravaKit

/// The outside watcher has no keeper of its own (issue #523). After a change of signer, macOS keeps the watcher's old
/// launch constraint: launchd refuses each run, its own repair fails, and only a registration made after that repair
/// records the new constraint. The runtime recovers because `RuntimeKeeper` registers it again; the watcher is
/// registered again here, once the runtime is live and the watcher has missed two runs. A pure decision.
enum WatcherRepair {
    /// Two missed quarter-hour runs and some slack: the first refused run, then launchd's failed repair.
    static let stale: TimeInterval = 35 * 60
    /// At most one attempt an hour, so a watcher that cannot be repaired is never registered in a loop.
    static let retryAfter: TimeInterval = 60 * 60

    /// Whether to register the watcher again. The clock starts at the latest of its last run, the runtime's start
    /// and the last wake, so a fresh registration or a Mac just woken from sleep gets its two runs first.
    static func due(watchRanAt: Date?, runtimeStartedAt: Date?, lastWake: Date?, lastAttempt: Date?,
                    runtimeLive: Bool, watcherEnabled: Bool, now: Date) -> Bool {
        guard runtimeLive, watcherEnabled else { return false }
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryAfter { return false }
        guard let since = [watchRanAt, runtimeStartedAt, lastWake].compactMap({ $0 }).max() else { return false }
        return now.timeIntervalSince(since) > stale
    }

    /// `ran_at` from `runtime/watch.json` as the watcher wrote it; nil when it is missing or unreadable.
    static func ranAt(_ record: String?) -> Date? {
        guard let record, let value = try? JSONParser.parse(record).value else { return nil }
        return value["ran_at"]?.stringValue.flatMap(ISOTime.date)
    }
}

extension HealthModel {
    /// Registers the watcher again when `WatcherRepair` says it is due; off the main actor, at most one at a time.
    func repairWatcherIfDue() {
        guard watcherRepair == nil, beatGrade == .green, case .success(let beat) = heartbeat else { return }
        guard WatcherRepair.due(watchRanAt: WatcherRepair.ranAt(watchRecord), runtimeStartedAt: ISOTime.date(beat.started_at),
                                lastWake: [lastWake, ISOTime.date(beat.last_wake_at)].compactMap { $0 }.max(),
                                lastAttempt: lastWatcherRepair, runtimeLive: true, watcherEnabled: watchStatus == .enabled,
                                now: now) else { return }
        lastWatcherRepair = now
        let repair = reads.repairWatcher
        watcherRepair = Task {
            watcherRepairFailure = await Task.detached { repair() }.value
            watcherRepair = nil
        }
    }
}

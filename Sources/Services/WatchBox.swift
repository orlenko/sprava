import Foundation

/// What the watchdog reads: the tick and when each running job started, behind a lock of its own. Start times
/// are on a clock that stops while the Mac sleeps, so a job the Mac slept through is not counted as wedged.
public final class WatchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var tick: UInt64 = 0
    private var running: [String: Duration] = [:]
    private let budgets: [String: Duration]
    /// Awake time since an arbitrary origin (tests pass their own).
    private let awake: @Sendable () -> Duration

    public static let origin = SuspendingClock.now

    public init(budgets: [String: Duration], awake: @escaping @Sendable () -> Duration = { WatchBox.origin.duration(to: SuspendingClock.now) }) {
        self.budgets = budgets
        self.awake = awake
    }

    public func beat(_ t: UInt64) { lock.lock(); tick = t; lock.unlock() }
    public func started(_ key: String) { let now = awake(); lock.lock(); running[key] = now; lock.unlock() }
    public func finished(_ key: String) { lock.lock(); running[key] = nil; lock.unlock() }

    /// How long a running job has been running, in awake time.
    public func runningFor(_ key: String) -> Duration? {
        let now = awake()
        lock.lock()
        defer { lock.unlock() }
        return running[key].map { now - $0 }
    }

    /// The tick, and a job running longer than twice its budget plus 10 minutes of awake time.
    public func read() -> (UInt64, String?) {
        let now = awake()
        lock.lock()
        defer { lock.unlock() }
        for (key, start) in running {
            let budget = max(budgets[key] ?? .seconds(1), .seconds(1))
            if now - start > budget * 2 + .seconds(600) { return (tick, key) }
        }
        return (tick, nil)
    }
}


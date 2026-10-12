import Foundation

/// The watchdog's decision (architecture 3.3, 3.4), as a pure function of what it read: the runtime ends with
/// status 70 for launchd to restart it when the tick has not moved for 120 seconds of awake time, or when a job has
/// run past twice its budget plus ten minutes (`WatchBox.read`).
public enum Watchdog {
    public enum Verdict: Equatable, Sendable {
        case fine
        case stalled
        case wedged(job: String)
    }

    public static let exitStatus: Int32 = 70
    public static let stallAfter: Duration = .seconds(120)

    /// `sinceTickMoved` is the awake time since the tick last changed.
    public static func verdict(sinceTickMoved: Duration, wedged: String?) -> Verdict {
        if sinceTickMoved > stallAfter { return .stalled }
        if let wedged { return .wedged(job: wedged) }
        return .fine
    }
}

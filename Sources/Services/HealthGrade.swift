import Foundation
import SpravaKit

/// How the app grades the runtime and its jobs (architecture 3.3, 3.4).
public enum HealthGrade: Int, Sendable, Comparable {
    case green, waking, amber, red, unknown

    public static func < (lhs: HealthGrade, rhs: HealthGrade) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The beat's age is counted from the later of the last beat and the last wake. Under 2 minutes is green,
    /// from 2 minutes amber, from 5 minutes red; for the first 60 seconds after a wake it is "waking up", never red,
    /// whether or not the first beat after the wake has come (architecture 3.3).
    public static func beat(_ beatAt: Date, lastWake: Date?, now: Date, pidAlive: Bool) -> HealthGrade {
        if let wake = lastWake, now >= wake, now.timeIntervalSince(wake) < 60 { return .waking }
        guard pidAlive else { return .red }
        let since = max(beatAt, lastWake ?? .distantPast)
        let age = now.timeIntervalSince(since)
        if age < 120 { return .green }
        if age < 300 { return .amber }
        return .red
    }

    /// A job is red when its breaker is open or it is wedged, amber after a failure or when overdue: past twice its
    /// cadence amber and four times red, or the job's own thresholds (`overdue(key:cadence:)`). The clock starts at
    /// the latest of its last success, its last run with nothing set up to do, the last wake and the runtime's
    /// start, so a week with the lid closed, or a Mac with no hub, does not paint a job red.
    public static func job(_ job: Heartbeat.Job, key: String = "", startedAt: Date, lastWake: Date?, now: Date) -> HealthGrade {
        if job.breaker == "open" || job.wedged { return .red }
        let failed = job.consecutive_failures > 0 || ["error", "timeout"].contains(job.last_outcome)
        var grade: HealthGrade = failed ? .amber : .green
        if let cadence = job.expected_cadence_s {
            let base = [ISOTime.date(job.last_success), ISOTime.date(job.last_idle), lastWake, startedAt].compactMap { $0 }.max()!
            let age = now.timeIntervalSince(base)
            let (amber, red) = overdue(key: key, cadence: TimeInterval(cadence))
            if age > red { grade = .red } else if age > amber { grade = max(grade, .amber) }
        }
        return grade
    }

    /// When a job is amber and when red for being overdue. Backup, per binder (`backup:<id>`), carries its own:
    /// amber after 48 hours, red after 7 days (architecture 3.4, 9.3).
    public static func overdue(key: String, cadence: TimeInterval) -> (amber: TimeInterval, red: TimeInterval) {
        if key == "backup" || key.hasPrefix("backup:") { return (48 * 3600, 7 * 86_400) }
        return (2 * cadence, 4 * cadence)
    }
}

import Foundation
import SpravaKit

/// How the app grades the runtime and its jobs (architecture 3.3, 3.4).
public enum HealthGrade: Int, Sendable, Comparable {
    case green, waking, amber, red, unknown

    public static func < (lhs: HealthGrade, rhs: HealthGrade) -> Bool { lhs.rawValue < rhs.rawValue }

    /// The beat's age is counted from the later of the last beat and the last wake. Under 2 minutes is green,
    /// from 2 minutes amber, from 5 minutes red; within 60 seconds of a wake it is "waking up".
    public static func beat(_ beatAt: Date, lastWake: Date?, now: Date, pidAlive: Bool) -> HealthGrade {
        if let wake = lastWake, now.timeIntervalSince(wake) < 60, wake > beatAt { return .waking }
        guard pidAlive else { return .red }
        let since = max(beatAt, lastWake ?? .distantPast)
        let age = now.timeIntervalSince(since)
        if age < 120 { return .green }
        if age < 300 { return .amber }
        return .red
    }

    /// A job is red when its breaker is open or it is wedged, amber after a failure or when overdue by twice
    /// its cadence, red at four times. The clock starts at the latest of its last success, its last run with
    /// nothing set up to do, the last wake and the runtime's start, so a week with the lid closed, or a Mac with no
    /// hub, does not paint a job red.
    public static func job(_ job: Heartbeat.Job, startedAt: Date, lastWake: Date?, now: Date) -> HealthGrade {
        if job.breaker == "open" || job.wedged { return .red }
        var grade: HealthGrade = job.consecutive_failures > 0 ? .amber : .green
        if let cadence = job.expected_cadence_s {
            let base = [ISOTime.date(job.last_success), ISOTime.date(job.last_idle), lastWake, startedAt].compactMap { $0 }.max()!
            let age = now.timeIntervalSince(base)
            if age > 4 * Double(cadence) { grade = .red } else if age > 2 * Double(cadence) { grade = max(grade, .amber) }
        }
        return grade
    }
}

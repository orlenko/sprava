import Foundation
import SpravaKit

/// Which jobs are due at a tick (architecture 3.4), as a value the runtime feeds with the clock, so the whole
/// matrix is tested without timers. Interval jobs wait for a wall-clock deadline (so after the clock is set back
/// each is due at once instead of waiting out the jump), the summary for 08:00, the sentinel also runs again when
/// the date changes, and the rest are due at every tick. Whether a due job runs is still its record's to say
/// (`JobRecord.mayRun`, not while it runs).
public struct Scheduler: Sendable, Equatable {
    /// Every job's budget, cadence and breaker threshold.
    public static let specs: [String: JobSpec] = [
        "heartbeat": JobSpec(key: "heartbeat", budget: .seconds(1), expectedCadence: 30, breakerThreshold: 3),
        "sentinel": JobSpec(key: "sentinel", budget: .seconds(60), expectedCadence: 3600, breakerThreshold: 3),
        "summary": JobSpec(key: "summary", budget: .seconds(5), expectedCadence: 86_400, breakerThreshold: 2),
        "alerts": JobSpec(key: "alerts", budget: .seconds(5), expectedCadence: 3600, breakerThreshold: 3),
        "hub": JobSpec(key: "hub", budget: .seconds(30), expectedCadence: 300, breakerThreshold: 3),
        "capture": JobSpec(key: "capture", budget: .seconds(10), expectedCadence: 15, breakerThreshold: 3),
        "intake": JobSpec(key: "intake", budget: .seconds(600), expectedCadence: 30, breakerThreshold: 3),
        "clerk": JobSpec(key: "clerk", budget: .seconds(300), expectedCadence: nil, breakerThreshold: 3),
        "dashboard": JobSpec(key: "dashboard", budget: .seconds(30), expectedCadence: 60, breakerThreshold: 3),
        // A first backup of a large binder takes long; the job is never killed for that, only by restic's cutoff
        // after a stretch with no progress (docs/backup.md §3.3). Daily, graded by its own 48-hour and 7-day marks.
        "backup": JobSpec(key: "backup", budget: nil, expectedCadence: 86_400, breakerThreshold: 3),
    ]

    /// The jobs with a wall-clock period, in seconds.
    public static let intervals: [String: TimeInterval] = ["sentinel": 3600, "alerts": 3600, "hub": 300,
                                                           "dashboard": 60, "intake": 30]
    /// The jobs the scheduler starts, in the order a tick starts them. The heartbeat has its own timer.
    public static let order = ["sentinel", "alerts", "summary", "hub", "capture", "clerk", "dashboard", "backup", "intake"]

    public private(set) var deadlines: [String: Date]
    public private(set) var nextSummary: Date
    /// The day today's summary was sent and the day the sentinel last ran, as `runtime/state.json` keeps them.
    public private(set) var lastSummaryDate: String?
    public private(set) var lastSentinelDate: String?
    /// The person's calendar, following time-zone changes.
    let calendar: Calendar

    public init(now: Date, lastSummaryDate: String?, lastSentinelDate: String?, calendar: Calendar = .autoupdatingCurrent) {
        deadlines = Self.intervals.mapValues { _ in now }
        self.lastSummaryDate = lastSummaryDate
        self.lastSentinelDate = lastSentinelDate
        self.calendar = calendar
        // A summary missed while the Mac was asleep or the runtime down is sent on the next start that day, once
        // today's summary time has passed.
        nextSummary = Self.nextSummaryTime(now: now, lastSent: lastSummaryDate, calendar: calendar)
    }

    /// The jobs due at `now`, in `order`.
    public func due(now: Date, sentinelRunning: Bool = false) -> [String] {
        let today = CalendarDate.today(in: calendar.timeZone, now: now).description
        let dateChanged = lastSentinelDate != nil && lastSentinelDate != today && !sentinelRunning
        return Self.order.filter { key in
            if key == "summary" { return now >= nextSummary }
            if key == "sentinel", dateChanged { return true }
            return deadlines[key].map { now >= $0 } ?? true
        }
    }

    /// A job started at `now`: its next run is a period later, the summary's at the next 08:00.
    public mutating func started(_ key: String, now: Date) {
        if key == "summary" {
            nextSummary = Self.nextClockTime(hour: 8, minute: 0, after: now, calendar: calendar)
        } else if let period = Self.intervals[key] {
            deadlines[key] = now.addingTimeInterval(period)
        }
    }

    public mutating func summarySent(day: String) { lastSummaryDate = day }
    public mutating func sentinelRan(day: String) { lastSentinelDate = day }

    /// The wall clock or the time zone changed: every deadline is due now, and the summary is due again if today's
    /// has not been sent and its time has passed in the new zone.
    public mutating func clockChanged(now: Date) {
        deadlines = Self.intervals.mapValues { _ in now }
        nextSummary = Self.nextSummaryTime(now: now, lastSent: lastSummaryDate, calendar: calendar)
    }

    /// The Mac woke: the sentinel runs at once (the day may have moved on), and a summary due during sleep now.
    public mutating func woke(now: Date) {
        deadlines["sentinel"] = now
        if nextSummary < now { nextSummary = now }
    }

    /// The first time at `hour:minute` strictly after `now` (architecture 3.4).
    public static func nextClockTime(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
        var parts = calendar.dateComponents([.year, .month, .day], from: now)
        parts.hour = hour
        parts.minute = minute
        parts.second = 0
        let candidate = calendar.date(from: parts)!
        return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)!
    }

    /// The next daily summary: now when today's has not been sent and today's 08:00 has passed (after a time-zone
    /// change, a late start or sleep), else the next 08:00.
    public static func nextSummaryTime(now: Date, lastSent: String?, calendar: Calendar = .current) -> Date {
        let today = CalendarDate.today(in: calendar.timeZone, now: now).description
        let todays = nextClockTime(hour: 8, minute: 0, after: calendar.startOfDay(for: now), calendar: calendar)
        if lastSent != today, now >= todays { return now }
        return nextClockTime(hour: 8, minute: 0, after: now, calendar: calendar)
    }
}

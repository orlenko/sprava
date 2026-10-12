import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The deadline sentinel's result for one day: counts per binder under opaque ids, never titles
/// (architecture 3.4, `deadline sentinel`). It is an optimization and a record; the app can always compute
/// buckets itself.
public struct SentinelReport: Codable, Sendable, Equatable {
    public struct Counts: Codable, Sendable, Equatable {
        public var state: String
        public var overdue = 0
        public var today = 0
        public var nudge = 0
        public var next7 = 0
    }

    public var date: String
    public var computed_at: String
    public var binders: [String: Counts]

    public var totals: Counts {
        binders.values.reduce(into: Counts(state: "")) { sum, c in
            sum.overdue += c.overdue
            sum.today += c.today
            sum.nudge += c.nudge
            sum.next7 += c.next7
        }
    }

    public static func compute(rows: [ShelfRow], ids: inout BinderIDs, today: CalendarDate, now: Date,
                               timeZone: TimeZone = .current) -> SentinelReport {
        var binders: [String: Counts] = [:]
        for row in rows {
            let page = row.teka.nowPage(today: today, timeZone: timeZone)
            var counts = Counts(state: row.teka.state.label.replacingOccurrences(of: " ", with: "_"))
            counts.overdue = page.count(.overdue)
            counts.today = page.count(.today)
            counts.nudge = page.count(.nudge)
            counts.next7 = page.count(.next7)
            binders[ids.id(for: row.folder)] = counts
        }
        return SentinelReport(date: today.description, computed_at: ISOTime.string(now, timeZone: timeZone),
                              binders: binders)
    }

    /// The daily summary's text: counts only, safe on a locked screen (architecture 3.7).
    public var summaryText: String? {
        let t = totals
        var parts: [String] = []
        if t.today > 0 { parts.append("\(t.today) due today") }
        if t.overdue > 0 { parts.append("\(t.overdue) overdue") }
        if t.nudge > 0 { parts.append("\(t.nudge) to follow up") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// What the daily summary does when today's sentinel report is missing: compute it itself, unless the
/// sentinel's breaker is open, which a direct call would get around (and a wedge there would be blamed on the
/// summary).
public enum SummaryFallback: Equatable, Sendable {
    case useReport, runSentinel, stale

    public static func decide(reportFresh: Bool, sentinelBreaker: String?) -> SummaryFallback {
        if reportFresh { return .useReport }
        return sentinelBreaker == "open" ? .stale : .runSentinel
    }
}

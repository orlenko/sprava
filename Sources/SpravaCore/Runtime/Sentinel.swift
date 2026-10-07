import Foundation

/// Opaque binder ids (`b1`, `b2`, ...), kept in Sprava's own state. Logs, the heartbeat and notifications name
/// binders only by these, never by `meta.name` or the folder name (architecture 3.7).
public struct BinderIDs: Codable, Sendable {
    public var byPath: [String: String] = [:]
    public var next = 1

    public init() {}

    public static func load(_ url: URL) -> BinderIDs {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BinderIDs.self, from: $0) } ?? BinderIDs()
    }

    public mutating func id(for folder: URL) -> String {
        let path = folder.standardizedFileURL.path
        if let id = byPath[path] { return id }
        let id = "b\(next)"
        next += 1
        byPath[path] = id
        return id
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: url)
    }
}

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

/// When the clock-time jobs fire next (architecture 3.4): the first time at `hour:minute` strictly after `now`.
public func nextClockTime(hour: Int, minute: Int, after now: Date, calendar: Calendar = .current) -> Date {
    var parts = calendar.dateComponents([.year, .month, .day], from: now)
    parts.hour = hour
    parts.minute = minute
    parts.second = 0
    let candidate = calendar.date(from: parts)!
    return candidate > now ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate)!
}

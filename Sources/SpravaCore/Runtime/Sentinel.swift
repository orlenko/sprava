import Foundation

/// Opaque binder ids (`b1`, `b2`, ...), kept in Sprava's own state. Logs, the heartbeat and notifications name
/// binders only by these, never by `meta.name` or the folder name (architecture 3.7).
public struct BinderIDs: Codable, Sendable {
    public var byPath: [String: String] = [:]
    public var next = 1

    public init() {}

    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "\(path) exists but cannot be read; it was left as it is" }
    }

    /// The ids. A missing file is a fresh mapping; one that exists but cannot be read or decoded throws, so new
    /// ids are never handed out over the old ones (b1 must keep naming the same binder).
    public static func load(_ url: URL) throws -> BinderIDs {
        guard FileManager.default.fileExists(atPath: url.path) else { return BinderIDs() }
        guard let data = try? Data(contentsOf: url), let ids = try? JSONDecoder().decode(BinderIDs.self, from: data) else {
            throw Unreadable(path: url.path)
        }
        return ids
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

/// The next daily summary: now when today's has not been sent and today's 08:00 has passed (after a time-zone
/// change, a late start or sleep), else the next 08:00.
public func nextSummaryTime(now: Date, lastSent: String?, calendar: Calendar = .current) -> Date {
    let today = CalendarDate.today(in: calendar.timeZone, now: now).description
    let todays = nextClockTime(hour: 8, minute: 0, after: calendar.startOfDay(for: now), calendar: calendar)
    if lastSent != today, now >= todays { return now }
    return nextClockTime(hour: 8, minute: 0, after: now, calendar: calendar)
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

extension ShelfStore {
    /// The Shelf as a job reads it: a shelf.json, or a registry the Shelf shows, that exists but cannot be read
    /// throws, so a job fails instead of reporting an empty Shelf as all done (the app's display path keeps `rows`).
    public func rowsForJobs() throws -> [ShelfRow] {
        let picked = try readFolders()
        return Shelf.rows(registry: try registryForShelf(), picked: picked)
    }
}

/// Outside edits reach the op log when a background reader sees them, not only on Sprava's next write
/// (architecture 4.5): a hand edit followed by no write still becomes an `external_edit`.
public enum OutsideEdits {
    /// Settles each adopted binder this Mac owns. Returns the cards absorbing wrote ("an outside edit undid N
    /// changes"), by folder, for the caller to trust, and the folders that could not be settled.
    public static func settle(_ rows: [ShelfRow], deviceID: String, now: Date = Date()) -> (cards: [(URL, [String])], failed: [URL]) {
        var cards: [(URL, [String])] = []
        var failed: [URL] = []
        for row in rows where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            let store = TekaStore(folder: row.folder)
            do {
                try store.settle(now: now)
                if !store.createdProposals.isEmpty { cards.append((row.folder, store.createdProposals)) }
            } catch {
                failed.append(row.folder)
            }
        }
        return (cards, failed)
    }
}

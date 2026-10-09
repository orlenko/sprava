import BinderStore
import Foundation
import Shelf
import SpravaKit

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

extension OutsideEdits {
    /// One settling pass: binders settled, cards written and trusted, and what failed (counts only).
    public struct Settled: Sendable, Equatable {
        public var cards = 0
        /// Binders that could not be settled.
        public var unsettled = 0
        /// Cards Sprava wrote whose digests could not be recorded yet, these and earlier ones; `TrustBacklog` keeps
        /// them for the next pass.
        public var untrusted = 0

        public init() {}
    }

    /// Settles each binder this Mac owns, then trusts the cards that wrote, together with any held back before, on
    /// the command queue (`onCommandQueue`), where the commands that read the record run. A trust that fails is a
    /// failure of the job, never dropped: the card would otherwise wait forever and could not be approved.
    public static func settleAndTrust(_ rows: [ShelfRow], commands: Commands, backlog: TrustBacklog, now: Date = Date(),
                                      onCommandQueue: (() -> Void) -> Void) -> Settled {
        let settled = settle(rows, deviceID: commands.deviceID, now: now)
        var out = Settled()
        out.unsettled = settled.failed.count
        out.cards = settled.cards.count
        var failed = false
        onCommandQueue {
            do { try backlog.retry(commands: commands) } catch { failed = true }
            for (folder, ids) in settled.cards {
                do { try backlog.trust(ids, in: folder, commands: commands) } catch { failed = true }
            }
        }
        // A backlog file that cannot be read holds an unknown number: at least one.
        if failed { out.untrusted = max(1, backlog.count) }
        return out
    }
}

/// Cards Sprava itself wrote (a recovery card from an outside edit, a hub completion's card) whose digests could not
/// be recorded, because `runtime/proposal-digests.json` could not be read or written (architecture 4.6). Each is kept
/// by the digest it had right after Sprava wrote it, in memory and in `runtime/trust-backlog.json`, and recorded on
/// the next pass. Never by what the file holds by then: a card another program changed in between stays untrusted.
public final class TrustBacklog: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    /// Record key (`<folder>#<id>`) to the digest Sprava wrote.
    private var held: [String: String] = [:]

    public init(support: URL) {
        url = support.appendingPathComponent("runtime/trust-backlog.json")
    }

    /// How many cards wait to be trusted (those in memory; the file's are counted when it is read).
    public var count: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    /// Trusts `ids`, which Sprava just wrote in `folder`, by their digests now. Throws when they or earlier ones could
    /// not be recorded; they are kept for `retry`.
    public func trust(_ ids: [String], in folder: URL, commands: Commands) throws {
        let wanted = Set(ids)
        var fresh: [String: String] = [:]
        for (p, digest) in ProposalStore.list(in: folder) where wanted.contains(p.id) { fresh[commands.key(folder, p.id)] = digest }
        try record(fresh, commands: commands)
    }

    /// Records the cards held back earlier. Throws while they still cannot be recorded.
    public func retry(commands: Commands) throws { try record([:], commands: commands) }

    private func record(_ fresh: [String: String], commands: Commands) throws {
        lock.lock()
        defer { lock.unlock() }
        var pending = held.merging(fresh) { _, new in new }
        // A backlog file that cannot be read is left as it is and reported; what is in memory is still recorded.
        var backlogError: Error?
        do {
            let saved = try StateFile.read([String: String].self, from: url) ?? [:]
            pending.merge(saved) { mine, _ in mine }
        } catch {
            backlogError = error
        }
        if !pending.isEmpty {
            do {
                var digests = try commands.loadDigests()
                for (key, digest) in pending { digests[key] = digest }
                try AtomicFile.makePrivateFolder(commands.digestsURL.deletingLastPathComponent())
                try AtomicFile.write(try JSONEncoder().encode(digests), to: commands.digestsURL)
            } catch {
                held = pending
                if backlogError == nil, let data = try? JSONEncoder().encode(pending) {
                    try? AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
                    try? AtomicFile.write(data, to: url)
                }
                throw error
            }
            held = [:]
            if backlogError == nil { unlink(url.path) }
        }
        if let backlogError { throw backlogError }
    }
}

/// The dashboard job's pass over the Shelf (binder-v0 §7.1): each switched DASHBOARD.md this Mac owns is refreshed
/// on its own, so one binder that fails never stops the others. Counts only.
public enum DashboardJob {
    public struct Result: Sendable, Equatable {
        public var rendered = 0
        public var editedOutsideNotes = 0
        public var failed = 0
        /// Failures because Sprava's record of a dashboard could not be read (`StateFile.Unreadable`).
        public var unreadable = 0

        public init() {}
    }

    /// `refresh` is `DashboardKeeper.refresh` for one folder (tests pass their own).
    public static func run(_ rows: [ShelfRow], deviceID: String,
                           refresh: (URL) throws -> DashboardKeeper.Refresh) -> Result {
        var out = Result()
        for row in rows where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            do {
                if case .rendered(let edited) = try refresh(row.folder) {
                    out.rendered += 1
                    if edited { out.editedOutsideNotes += 1 }
                }
            } catch is StateFile.Unreadable {
                out.failed += 1
                out.unreadable += 1
            } catch {
                out.failed += 1
            }
        }
        return out
    }

    /// The job's outcome: a record that cannot be read first, then cards left untrusted, then any other failure.
    public static func outcome(_ result: Result, settled: OutsideEdits.Settled) -> JobOutcome {
        if result.unreadable > 0 { return .error(code: "dashboard_state_unreadable", culprit: "\(result.unreadable) binder(s)") }
        if settled.untrusted > 0 { return .error(code: "trust_failed", culprit: "\(settled.untrusted) card(s)") }
        let failed = result.failed + settled.unsettled
        return failed > 0 ? .error(code: "dashboard_failed", culprit: "\(failed) binder(s)") : .ok
    }
}

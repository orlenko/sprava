import Foundation
import SpravaKit

/// A job's static description: name, budget, cadence and breaker threshold (architecture 3.4).
public struct JobSpec: Sendable {
    public let key: String
    public let budget: Duration
    /// nil for jobs that run on events or on demand; those are graded by their errors only.
    public let expectedCadence: Int?
    public let breakerThreshold: Int

    public init(key: String, budget: Duration, expectedCadence: Int?, breakerThreshold: Int) {
        self.key = key
        self.budget = budget
        self.expectedCadence = expectedCadence
        self.breakerThreshold = breakerThreshold
    }
}

public enum JobOutcome: Sendable, Equatable {
    case ok
    /// The run did nothing on purpose; never counted as a success (architecture 3.5).
    case skipped
    /// Nothing to do because the feature is not set up here (no hub spool, an empty Shelf). Not a success either,
    /// but a job that keeps finding nothing to do is not overdue.
    case idle
    case error(code: String, culprit: String?)
    case timeout
}

/// Persisted per-job state: breakers, failures, watchdog exits and recent durations survive a restart
/// (`runtime/breakers.json`; architecture 3.4).
public struct JobRecord: Codable, Sendable, Equatable {
    public var lastStart: Date?
    public var lastSuccess: Date?
    /// The last run that found nothing set up to do (`JobOutcome.idle`).
    public var lastIdle: Date?
    public var lastOutcome = "none"
    public var lastErrorAt: Date?
    public var lastErrorCode: String?
    public var lastErrorCulprit: String?
    public var consecutiveFailures = 0
    public var breaker = "closed"
    public var breakerOpenedAt: Date?
    public var backoffStep = 0
    public var watchdogExits = 0
    public var durationsMS: [Int] = []
    public var running = false

    public init() {}

    /// Backoff after the breaker opens: 1, 5, 15, then 60 minutes (architecture 3.5).
    public static let backoff: [TimeInterval] = [60, 300, 900, 3600]

    /// Whether the job may run now. An open breaker past its backoff becomes half-open for one trial.
    public mutating func mayRun(now: Date) -> Bool {
        switch breaker {
        case "open":
            // Bounded on both sides: a step that did not come from this code never indexes outside the table.
            let wait = Self.backoff[max(0, min(backoffStep, Self.backoff.count - 1))]
            guard let opened = breakerOpenedAt, now.timeIntervalSince(opened) >= wait else { return false }
            breaker = "half_open"
            return true
        default:
            return true
        }
    }

    public mutating func start(at now: Date) {
        lastStart = now
        running = true
    }

    public mutating func finish(_ outcome: JobOutcome, at now: Date, durationMS: Int, threshold: Int) {
        running = false
        durationsMS.append(durationMS)
        if durationsMS.count > 20 { durationsMS.removeFirst(durationsMS.count - 20) }
        switch outcome {
        case .skipped:
            // A run that did nothing on purpose is never a success: failures and the breaker stay as they were.
            lastOutcome = "skipped"
        case .idle:
            // Shown as skipped, the heartbeat schema's word (architecture Appendix A); only the clock moves.
            lastOutcome = "skipped"
            lastIdle = now
        case .ok:
            lastOutcome = "ok"
            lastSuccess = now
            consecutiveFailures = 0
            watchdogExits = 0
            if breaker != "closed" {
                breaker = "closed"
                breakerOpenedAt = nil
                backoffStep = 0
            }
        case .error(let code, let culprit):
            lastOutcome = "error"
            recordFailure(code: code, culprit: culprit, at: now, threshold: threshold)
        case .timeout:
            lastOutcome = "timeout"
            recordFailure(code: "timeout", culprit: nil, at: now, threshold: threshold)
        }
    }

    /// The watchdog ended the process because this job was wedged. After 2 such exits the breaker opens, so a job
    /// that wedges every time stops restarting the runtime (architecture 3.4).
    public mutating func recordWatchdogExit(at now: Date) {
        running = false
        watchdogExits += 1
        lastOutcome = "error"
        lastErrorAt = now
        lastErrorCode = "wedged"
        consecutiveFailures += 1
        if breaker == "half_open" {
            breaker = "open"
            breakerOpenedAt = now
            backoffStep = min(backoffStep + 1, Self.backoff.count - 1)
        } else if breaker == "closed", watchdogExits >= 2 {
            breaker = "open"
            breakerOpenedAt = now
            backoffStep = 0
        }
    }

    mutating func recordFailure(code: String, culprit: String?, at now: Date, threshold: Int) {
        lastErrorAt = now
        lastErrorCode = code
        lastErrorCulprit = culprit.map { String($0.prefix(200)) }
        consecutiveFailures += 1
        if breaker == "half_open" {
            breaker = "open"
            breakerOpenedAt = now
            backoffStep = min(backoffStep + 1, Self.backoff.count - 1)
        } else if breaker == "closed", consecutiveFailures >= threshold {
            breaker = "open"
            breakerOpenedAt = now
            backoffStep = 0
        }
    }

    public var medianMS: Int? {
        guard !durationsMS.isEmpty else { return nil }
        return durationsMS.sorted()[durationsMS.count / 2]
    }

    public func heartbeatJob(spec: JobSpec, now: Date, wedged: Bool) -> Heartbeat.Job {
        var due: Date?
        if let cadence = spec.expectedCadence {
            due = ([lastSuccess, lastIdle].compactMap { $0 }.max() ?? lastStart).map { $0.addingTimeInterval(TimeInterval(cadence)) }
        }
        return Heartbeat.Job(
            last_start: lastStart.map { ISOTime.string($0) },
            last_success: lastSuccess.map { ISOTime.string($0) },
            last_idle: lastIdle.map { ISOTime.string($0) },
            last_outcome: running ? "running" : lastOutcome,
            last_error: lastErrorAt.map { Heartbeat.JobError(at: ISOTime.string($0), code: lastErrorCode ?? "error",
                                                             culprit: lastErrorCulprit) },
            consecutive_failures: consecutiveFailures,
            breaker: breaker,
            breaker_opened_at: breakerOpenedAt.map { ISOTime.string($0) },
            expected_cadence_s: spec.expectedCadence,
            due_since: due.flatMap { $0 < now ? ISOTime.string($0) : nil },
            wedged: wedged,
            watchdog_exits: watchdogExits,
            median_ms: medianMS,
            slowest_of_twenty_ms: durationsMS.max()
        )
    }
}

/// The store behind `runtime/breakers.json`.
public struct JobRecords: Codable, Sendable {
    public var jobs: [String: JobRecord] = [:]

    public init() {}

    public static func load(_ url: URL) -> JobRecords {
        (try? read(url)) ?? JobRecords()
    }

    /// The records; a missing file is none, and a file that exists but cannot be read or decoded throws.
    static func read(_ url: URL) throws -> JobRecords {
        guard FileManager.default.fileExists(atPath: url.path) else { return JobRecords() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), var records = try? decoder.decode(JobRecords.self, from: data) else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: url.path])
        }
        // A job recorded as running when the process died is not running now.
        for key in records.jobs.keys { records.jobs[key]?.running = false }
        return records
    }

    /// The runtime's start. Breakers that cannot be read are not reset to closed, which would let a job that
    /// wedges restart the runtime again: the file is kept aside as `breakers.json.unreadable-<time>`, and every job
    /// starts half-open, so each gets one trial run and its breaker opens again on a failure. Starting never fails,
    /// which would bring back the launchd restart loop. Returns where the file was put, when it was.
    public static func loadAtStart(_ url: URL, jobs: [String], now: Date = Date()) -> (JobRecords, setAside: URL?) {
        if let records = try? read(url) { return (records, nil) }
        let stamp = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
        let aside = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".unreadable-" + stamp)
        try? FileManager.default.moveItem(at: url, to: aside)
        var records = JobRecords()
        for key in jobs { records.jobs[key, default: JobRecord()].breaker = "half_open" }
        return (records, aside)
    }

    /// Records a watchdog exit straight to disk, without the runtime's state queue, which may be the thing that hung.
    public static func recordWatchdogExit(job: String, url: URL, now: Date = Date()) {
        // An unreadable file is left for the next start to set aside, never saved over.
        guard var records = try? read(url) else { return }
        records.jobs[job, default: JobRecord()].recordWatchdogExit(at: now)
        try? records.save(url)
    }

    public func save(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(self), to: url)
    }
}

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

// Missing keys take their defaults, so a field added later never resets every breaker.
extension JobRecord {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastStart = try c.decodeIfPresent(Date.self, forKey: .lastStart)
        lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
        lastIdle = try c.decodeIfPresent(Date.self, forKey: .lastIdle)
        lastOutcome = try c.decodeIfPresent(String.self, forKey: .lastOutcome) ?? "none"
        lastErrorAt = try c.decodeIfPresent(Date.self, forKey: .lastErrorAt)
        lastErrorCode = try c.decodeIfPresent(String.self, forKey: .lastErrorCode)
        lastErrorCulprit = try c.decodeIfPresent(String.self, forKey: .lastErrorCulprit)
        consecutiveFailures = try c.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
        breaker = try c.decodeIfPresent(String.self, forKey: .breaker) ?? "closed"
        breakerOpenedAt = try c.decodeIfPresent(Date.self, forKey: .breakerOpenedAt)
        backoffStep = try c.decodeIfPresent(Int.self, forKey: .backoffStep) ?? 0
        watchdogExits = try c.decodeIfPresent(Int.self, forKey: .watchdogExits) ?? 0
        durationsMS = try c.decodeIfPresent([Int].self, forKey: .durationsMS) ?? []
        running = try c.decodeIfPresent(Bool.self, forKey: .running) ?? false
        // A record this code could never have written is unreadable, so the start sets the file aside and every job
        // gets a half-open trial (`JobRecords.loadAtStart`): an out-of-range step would crash every launch, and an
        // open breaker with no opening time would pause its job for good.
        guard ["closed", "open", "half_open"].contains(breaker), Self.backoff.indices.contains(backoffStep),
              consecutiveFailures >= 0, watchdogExits >= 0, breaker != "open" || breakerOpenedAt != nil else {
            throw DecodingError.dataCorruptedError(forKey: .breaker, in: c, debugDescription: "breaker state out of range")
        }
    }
}

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

/// When the interval jobs run next. Wall-clock dates, so after the clock is set back every one of them is due at
/// once, instead of waiting out the jump.
public struct JobDeadlines: Sendable, Equatable {
    public var sentinel: Date
    public var alerts: Date
    public var hub: Date
    public var intake: Date
    public var dashboard: Date

    public init(now: Date = Date()) {
        sentinel = now; alerts = now; hub = now; intake = now; dashboard = now
    }

    public mutating func clockChanged(now: Date) { self = JobDeadlines(now: now) }
}

/// Small persisted counters that are not job state (`runtime/state.json`): starts and lease refusals today, and the
/// days the summary and the sentinel last ran.
public struct RuntimeState: Codable, Sendable, Equatable {
    public var day: String = ""
    public var startsToday = 0
    public var refusalsToday = 0
    public var lastSummaryDate: String?
    public var lastSentinelDate: String?

    public init() {}

    public static func url(_ dir: URL) -> URL { dir.appendingPathComponent("state.json") }

    /// The state, with today's counters reset on a new day. A missing file is a fresh state; one that exists but
    /// cannot be read or decoded throws `StateFile.Unreadable`, so nothing saves over it.
    public static func read(_ dir: URL, today: String = CalendarDate.today().description) throws -> RuntimeState {
        var state = try StateFile.read(RuntimeState.self, from: url(dir)) ?? RuntimeState()
        if state.day != today {
            state.day = today
            state.startsToday = 0
            state.refusalsToday = 0
        }
        return state
    }

    /// The runtime's start, as for the breakers: a file that cannot be read is kept aside as
    /// `state.json.unreadable-<time>` and the state starts fresh, so starting never fails and the original is never
    /// saved over. Today's summary then counts as sent: a lost marker may skip one day's summary, never repeat it.
    /// Returns where the file was put, when it was.
    public static func loadAtStart(_ dir: URL, now: Date = Date()) -> (RuntimeState, setAside: URL?) {
        let today = CalendarDate.today(now: now).description
        if let state = try? read(dir, today: today) { return (state, nil) }
        let stamp = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
        let aside = dir.appendingPathComponent("state.json.unreadable-" + stamp)
        try? FileManager.default.moveItem(at: url(dir), to: aside)
        var state = RuntimeState()
        state.day = today
        state.lastSummaryDate = today
        return (state, aside)
    }

    /// Reads, changes and saves. A file that cannot be read is left for the next start to set aside and the change
    /// is dropped; returns whether it was saved.
    @discardableResult
    public static func update(_ dir: URL, _ change: (inout RuntimeState) -> Void) -> Bool {
        guard var state = try? read(dir) else { return false }
        change(&state)
        guard let data = try? JSONEncoder().encode(state), (try? AtomicFile.write(data, to: url(dir))) != nil else { return false }
        return true
    }

    @discardableResult public static func recordStart(_ dir: URL) -> Bool { update(dir) { $0.startsToday += 1 } }
    @discardableResult public static func recordRefusal(_ dir: URL) -> Bool { update(dir) { $0.refusalsToday += 1 } }
}

// Missing keys take their defaults, so a field added later never makes the file unreadable.
extension RuntimeState {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decodeIfPresent(String.self, forKey: .day) ?? ""
        startsToday = try c.decodeIfPresent(Int.self, forKey: .startsToday) ?? 0
        refusalsToday = try c.decodeIfPresent(Int.self, forKey: .refusalsToday) ?? 0
        lastSummaryDate = try c.decodeIfPresent(String.self, forKey: .lastSummaryDate)
        lastSentinelDate = try c.decodeIfPresent(String.self, forKey: .lastSentinelDate)
    }
}

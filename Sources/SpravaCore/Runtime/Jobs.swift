import Foundation

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
    case error(code: String, culprit: String?)
    case timeout
}

/// Persisted per-job state: breakers, failures, watchdog exits and recent durations survive a restart
/// (`runtime/breakers.json`; architecture 3.4).
public struct JobRecord: Codable, Sendable, Equatable {
    public var lastStart: Date?
    public var lastSuccess: Date?
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
            let wait = Self.backoff[min(backoffStep, Self.backoff.count - 1)]
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
        case .ok, .skipped:
            lastOutcome = outcome == .ok ? "ok" : "skipped"
            if outcome == .ok { lastSuccess = now }
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
            due = (lastSuccess ?? lastStart).map { $0.addingTimeInterval(TimeInterval(cadence)) }
        }
        return Heartbeat.Job(
            last_start: lastStart.map { ISOTime.string($0) },
            last_success: lastSuccess.map { ISOTime.string($0) },
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
        guard let data = try? Data(contentsOf: url) else { return JobRecords() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records = (try? decoder.decode(JobRecords.self, from: data)) ?? JobRecords()
        // A job recorded as running when the process died is not running now.
        for key in records.jobs.keys { records.jobs[key]?.running = false }
        return records
    }

    /// Records a watchdog exit straight to disk, without the runtime's state queue, which may be the thing that hung.
    public static func recordWatchdogExit(job: String, url: URL, now: Date = Date()) {
        var records = load(url)
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
    /// its cadence, red at four times. The clock starts at the latest of its last success, the last wake and
    /// the runtime's start, so a week with the lid closed does not paint every job red.
    public static func job(_ job: Heartbeat.Job, startedAt: Date, lastWake: Date?, now: Date) -> HealthGrade {
        if job.breaker == "open" || job.wedged { return .red }
        var grade: HealthGrade = job.consecutive_failures > 0 ? .amber : .green
        if let cadence = job.expected_cadence_s {
            let base = [ISOTime.date(job.last_success), lastWake, startedAt].compactMap { $0 }.max()!
            let age = now.timeIntervalSince(base)
            if age > 4 * Double(cadence) { grade = .red } else if age > 2 * Double(cadence) { grade = max(grade, .amber) }
        }
        return grade
    }
}

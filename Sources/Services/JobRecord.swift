import Foundation
import SpravaKit

/// A job's static description: name, budget, cadence and breaker threshold (architecture 3.4).
public struct JobSpec: Sendable {
    public let key: String
    /// The longest one run may take; nil for a job never stopped for taking long, only by its own cutoff after a
    /// stretch with no progress (backup, docs/backup.md §3.3), so neither its deadline nor the watchdog times it.
    public let budget: Duration?
    /// nil for jobs that run on events or on demand; those are graded by their errors only.
    public let expectedCadence: Int?
    public let breakerThreshold: Int

    public init(key: String, budget: Duration?, expectedCadence: Int?, breakerThreshold: Int) {
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

    /// Whether the job may run now: never while a run is still going, so a job is never started twice at once. An
    /// open breaker past its backoff becomes half-open for one trial.
    public mutating func mayRun(now: Date) -> Bool {
        guard !running else { return false }
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

    /// The watchdog ended the process because this job was wedged. It counts as a failure; after 2 such exits the
    /// breaker opens even below the job's threshold, so a job that wedges every time stops restarting the runtime
    /// (architecture 3.4).
    public mutating func recordWatchdogExit(at now: Date, threshold: Int) {
        running = false
        watchdogExits += 1
        lastOutcome = "error"
        lastErrorAt = now
        lastErrorCode = "wedged"
        lastErrorCulprit = nil   // an earlier failure's culprit is not this one's
        consecutiveFailures += 1
        // A wedge on an open breaker (a run that timed out and kept running) is a new failed trial: its backoff
        // starts again, longer, so the restart that follows does not let the same job straight back in.
        if breaker == "half_open" || breaker == "open" {
            breaker = "open"
            breakerOpenedAt = now
            backoffStep = min(backoffStep + 1, Self.backoff.count - 1)
        } else if breaker == "closed", watchdogExits >= 2 || consecutiveFailures >= threshold {
            breaker = "open"
            breakerOpenedAt = now
            backoffStep = 0
        }
    }

    mutating func recordFailure(code: String, culprit: String?, at now: Date, threshold: Int) {
        lastErrorAt = now
        lastErrorCode = code
        // At most 200 characters as the heartbeat schema counts them (Unicode scalars).
        lastErrorCulprit = culprit.map { String(String.UnicodeScalarView($0.unicodeScalars.prefix(200))) }
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

    /// The job's line in the heartbeat. A job that has never succeeded nor idled is due a cadence after `anchor`
    /// (the runtime's start), not after its last attempt, which every failed retry would push back.
    public func heartbeatJob(spec: JobSpec, now: Date, wedged: Bool, anchor: Date? = nil) -> Heartbeat.Job {
        var due: Date?
        if let cadence = spec.expectedCadence {
            due = ([lastSuccess, lastIdle].compactMap { $0 }.max() ?? anchor ?? lastStart).map { $0.addingTimeInterval(TimeInterval(cadence)) }
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
        // So is anything the heartbeat would refuse (an unknown outcome, an error code it cannot carry) and any count
        // the next increment could overflow.
        let counts = 0...1_000_000
        guard ["closed", "open", "half_open"].contains(breaker), Self.backoff.indices.contains(backoffStep),
              counts.contains(consecutiveFailures), counts.contains(watchdogExits), breaker != "open" || breakerOpenedAt != nil,
              ["none", "ok", "error", "timeout", "skipped"].contains(lastOutcome),
              lastErrorCode.map({ $0.wholeMatch(of: /[a-z_]+/) != nil }) ?? true,
              (lastErrorCulprit?.unicodeScalars.count ?? 0) <= 200,
              durationsMS.count <= 20, durationsMS.allSatisfy({ (0...86_400_000).contains($0) }) else {
            throw DecodingError.dataCorruptedError(forKey: .breaker, in: c, debugDescription: "breaker state out of range")
        }
    }
}


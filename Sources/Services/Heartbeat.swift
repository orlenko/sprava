import Foundation
import SpravaKit

/// `runtime/heartbeat.json` (architecture Appendix A). Times are ISO 8601 strings with an offset.
public struct Heartbeat: Codable, Sendable, Equatable {
    public struct LeaseInfo: Codable, Sendable, Equatable {
        public var inode: UInt64
        public var duplicates_refused_today: Int
        public init(inode: UInt64, duplicates_refused_today: Int) {
            self.inode = inode
            self.duplicates_refused_today = duplicates_refused_today
        }
    }

    public struct Alerts: Codable, Sendable, Equatable {
        public var authorized: Bool
        public var checked_at: String
        public init(authorized: Bool, checked_at: String) {
            self.authorized = authorized
            self.checked_at = checked_at
        }
    }

    public struct Model: Codable, Sendable, Equatable {
        public var availability: String
        public var context_size: Int?
        public var variant: String?
        public var last_success: String?
        public var errors_24h: [String: Int]?
        public init(availability: String, context_size: Int? = nil, variant: String? = nil,
                    last_success: String? = nil, errors_24h: [String: Int]? = nil) {
            self.availability = availability
            self.context_size = context_size
            self.variant = variant
            self.last_success = last_success
            self.errors_24h = errors_24h
        }
    }

    public struct JobError: Codable, Sendable, Equatable {
        public var at: String
        public var code: String
        public var culprit: String?
        public init(at: String, code: String, culprit: String? = nil) {
            self.at = at
            self.code = code
            self.culprit = culprit
        }
    }

    public struct Job: Codable, Sendable, Equatable {
        enum CodingKeys: String, CodingKey {
            case last_start, last_success, last_idle, last_outcome, last_error, consecutive_failures, breaker
            case breaker_opened_at, expected_cadence_s, due_since, wedged, watchdog_exits, median_ms
            case slowest_of_twenty_ms
        }

        /// The schema requires these keys even when empty, so they are written as null, never left out.
        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(last_start, forKey: .last_start)
            try c.encode(last_success, forKey: .last_success)
            try c.encodeIfPresent(last_idle, forKey: .last_idle)
            try c.encode(last_outcome, forKey: .last_outcome)
            try c.encode(last_error, forKey: .last_error)
            try c.encode(consecutive_failures, forKey: .consecutive_failures)
            try c.encode(breaker, forKey: .breaker)
            try c.encode(breaker_opened_at, forKey: .breaker_opened_at)
            try c.encode(expected_cadence_s, forKey: .expected_cadence_s)
            try c.encodeIfPresent(due_since, forKey: .due_since)
            try c.encode(wedged, forKey: .wedged)
            try c.encodeIfPresent(watchdog_exits, forKey: .watchdog_exits)
            try c.encodeIfPresent(median_ms, forKey: .median_ms)
            try c.encodeIfPresent(slowest_of_twenty_ms, forKey: .slowest_of_twenty_ms)
        }

        public var last_start: String?
        public var last_success: String?
        /// The last run with nothing set up to do (no hub, an empty Shelf); not in Appendix A's schema, which
        /// allows unknown fields.
        public var last_idle: String?
        public var last_outcome: String
        public var last_error: JobError?
        public var consecutive_failures: Int
        public var breaker: String
        public var breaker_opened_at: String?
        public var expected_cadence_s: Int?
        public var due_since: String?
        public var wedged: Bool
        public var watchdog_exits: Int?
        public var median_ms: Int?
        public var slowest_of_twenty_ms: Int?

        public init(last_start: String? = nil, last_success: String? = nil, last_idle: String? = nil, last_outcome: String = "none",
                    last_error: JobError? = nil, consecutive_failures: Int = 0, breaker: String = "closed",
                    breaker_opened_at: String? = nil, expected_cadence_s: Int? = nil, due_since: String? = nil,
                    wedged: Bool = false, watchdog_exits: Int? = nil, median_ms: Int? = nil,
                    slowest_of_twenty_ms: Int? = nil) {
            self.last_start = last_start
            self.last_success = last_success
            self.last_idle = last_idle
            self.last_outcome = last_outcome
            self.last_error = last_error
            self.consecutive_failures = consecutive_failures
            self.breaker = breaker
            self.breaker_opened_at = breaker_opened_at
            self.expected_cadence_s = expected_cadence_s
            self.due_since = due_since
            self.wedged = wedged
            self.watchdog_exits = watchdog_exits
            self.median_ms = median_ms
            self.slowest_of_twenty_ms = slowest_of_twenty_ms
        }
    }

    public var format_version = "0"
    public var pid: Int32
    public var started_at: String
    public var beat_at: String
    public var last_wake_at: String?
    public var build: String
    public var xpc_protocol: Int
    public var lease: LeaseInfo
    public var restarts_today: Int?
    public var alerts: Alerts?
    public var runtime_key: String?
    public var stage_crashes: [String: Int]?
    public var model: Model?
    public var outbound_today: [String: Int]?
    public var jobs: [String: Job]

    public init(pid: Int32, started_at: String, beat_at: String, last_wake_at: String?, build: String,
                xpc_protocol: Int, lease: LeaseInfo, restarts_today: Int?, alerts: Alerts?, runtime_key: String?,
                stage_crashes: [String: Int]?, model: Model?, outbound_today: [String: Int]?, jobs: [String: Job]) {
        self.pid = pid
        self.started_at = started_at
        self.beat_at = beat_at
        self.last_wake_at = last_wake_at
        self.build = build
        self.xpc_protocol = xpc_protocol
        self.lease = lease
        self.restarts_today = restarts_today
        self.alerts = alerts
        self.runtime_key = runtime_key
        self.stage_crashes = stage_crashes
        self.model = model
        self.outbound_today = outbound_today
        self.jobs = jobs
    }

    public static let fileName = "heartbeat.json"

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// Reads and validates the file. A file that is missing fields, has wrong types or impossible values is
    /// "health data unreadable", never green (architecture 3.3).
    public static func read(_ url: URL) -> Result<Heartbeat, ReadError> {
        guard let data = try? Data(contentsOf: url) else { return .failure(.missing) }
        guard let beat = try? JSONDecoder().decode(Heartbeat.self, from: data) else { return .failure(.invalid) }
        guard beat.isValid else { return .failure(.invalid) }
        return .success(beat)
    }

    public enum ReadError: Error, Equatable { case missing, invalid }

    /// The checks the schema makes beyond what decoding enforces.
    public var isValid: Bool {
        let outcomes: Set<String> = ["ok", "error", "timeout", "skipped", "running", "none"]
        let breakers: Set<String> = ["closed", "open", "half_open"]
        let keyPattern = /^[a-z_]+(:[a-z0-9]+)?$/
        let codePattern = /^[a-z_]+$/
        guard format_version == "0", pid >= 1, xpc_protocol >= 1, !build.isEmpty, lease.inode >= 1,
              lease.duplicates_refused_today >= 0,
              ISOTime.date(started_at) != nil, ISOTime.date(beat_at) != nil else { return false }
        if let key = runtime_key, !["readable", "locked", "missing"].contains(key) { return false }
        for (key, job) in jobs {
            guard key.wholeMatch(of: keyPattern) != nil, outcomes.contains(job.last_outcome),
                  breakers.contains(job.breaker), job.consecutive_failures >= 0 else { return false }
            if let e = job.last_error, e.code.wholeMatch(of: codePattern) == nil || (e.culprit?.count ?? 0) > 200 {
                return false
            }
            if let c = job.expected_cadence_s, c < 1 { return false }
        }
        return true
    }
}

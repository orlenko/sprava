import Foundation
import SpravaKit

/// The heartbeat schema's rules beyond what decoding enforces (architecture Appendix A): a file that breaks any
/// of them is "health data unreadable", never green.
extension Heartbeat {
    public var isValid: Bool {
        let codePattern = /^[a-z_]+$/
        guard format_version == "0", pid >= 1, xpc_protocol >= 1, !build.isEmpty, lease.inode >= 1,
              lease.duplicates_refused_today >= 0, ISOTime.date(started_at) != nil, ISOTime.date(beat_at) != nil,
              Self.time(last_wake_at), (restarts_today ?? 0) >= 0, Self.time(alerts?.checked_at) else { return false }
        if let key = runtime_key, !["readable", "locked", "missing"].contains(key) { return false }
        if let crashes = stage_crashes, crashes.contains(where: { $0.key.wholeMatch(of: codePattern) == nil || $0.value < 0 }) {
            return false
        }
        if let model, !model.isValid { return false }
        if let outbound = outbound_today, outbound.values.contains(where: { $0 < 0 }) { return false }
        return jobs.allSatisfy { key, job in key.wholeMatch(of: /^[a-z_]+(:[a-z0-9]+)?$/) != nil && job.isValid }
    }

    /// A date-time when present.
    static func time(_ text: String?) -> Bool { text.map { ISOTime.date($0) != nil } ?? true }

    /// Members the schema lets a file leave out but never set to null; decoding alone reads both as absent.
    static let neverNull = (top: ["restarts_today", "alerts", "runtime_key", "stage_crashes", "model", "outbound_today"],
                            model: ["context_size", "variant", "errors_24h"],
                            job: ["watchdog_exits", "median_ms", "slowest_of_twenty_ms"])

    static func hasNoMisplacedNull(_ data: Data) -> Bool {
        guard case .object(let top)? = try? JSONParser.parse(data).value else { return false }
        func clean(_ object: JSONObject, _ keys: [String]) -> Bool { keys.allSatisfy { object[$0] != .null } }
        guard clean(top, neverNull.top) else { return false }
        if case .object(let model)? = top["model"], !clean(model, neverNull.model) { return false }
        guard case .object(let jobs)? = top["jobs"] else { return true }
        return jobs.entries.allSatisfy { entry in
            guard case .object(let job) = entry.value else { return true }
            if case .object(let error)? = job["last_error"], error["culprit"] == .null { return false }
            return clean(job, neverNull.job)
        }
    }
}

extension Heartbeat.Model {
    static let availabilities: Set<String> = ["available", "deviceNotEligible", "appleIntelligenceNotEnabled",
                                              "modelNotReady", "fallback"]

    var isValid: Bool {
        Self.availabilities.contains(availability) && (context_size ?? 1) >= 1 && Heartbeat.time(last_success)
            && !(errors_24h ?? [:]).values.contains(where: { $0 < 0 })
    }
}

extension Heartbeat.Job {
    var isValid: Bool {
        guard ["ok", "error", "timeout", "skipped", "running", "none"].contains(last_outcome),
              ["closed", "open", "half_open"].contains(breaker), consecutive_failures >= 0,
              (expected_cadence_s ?? 1) >= 1, (watchdog_exits ?? 0) >= 0, (median_ms ?? 0) >= 0,
              (slowest_of_twenty_ms ?? 0) >= 0 else { return false }
        guard [last_start, last_success, last_idle, breaker_opened_at, due_since].allSatisfy(Heartbeat.time) else { return false }
        if let e = last_error, e.code.wholeMatch(of: /^[a-z_]+$/) == nil || (e.culprit?.count ?? 0) > 200
            || ISOTime.date(e.at) == nil { return false }
        return true
    }

    /// The schema requires these keys even when their value is null; a job without one is unreadable, so a file
    /// that leaves out `expected_cadence_s` can never hide an overdue job.
    static let requiredKeys: [CodingKeys] = [.last_start, .last_success, .last_outcome, .last_error,
                                             .consecutive_failures, .breaker, .expected_cadence_s, .wedged]

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        for key in Self.requiredKeys where !c.contains(key) {
            throw DecodingError.keyNotFound(key, .init(codingPath: c.codingPath, debugDescription: "required by the schema"))
        }
        self.init(last_start: try c.decode(String?.self, forKey: .last_start),
                  last_success: try c.decode(String?.self, forKey: .last_success),
                  last_idle: try c.decodeIfPresent(String.self, forKey: .last_idle),
                  last_outcome: try c.decode(String.self, forKey: .last_outcome),
                  last_error: try c.decode(Heartbeat.JobError?.self, forKey: .last_error),
                  consecutive_failures: try c.decode(Int.self, forKey: .consecutive_failures),
                  breaker: try c.decode(String.self, forKey: .breaker),
                  breaker_opened_at: try c.decodeIfPresent(String.self, forKey: .breaker_opened_at),
                  expected_cadence_s: try c.decode(Int?.self, forKey: .expected_cadence_s),
                  due_since: try c.decodeIfPresent(String.self, forKey: .due_since),
                  wedged: try c.decode(Bool.self, forKey: .wedged),
                  watchdog_exits: try c.decodeIfPresent(Int.self, forKey: .watchdog_exits),
                  median_ms: try c.decodeIfPresent(Int.self, forKey: .median_ms),
                  slowest_of_twenty_ms: try c.decodeIfPresent(Int.self, forKey: .slowest_of_twenty_ms))
    }
}

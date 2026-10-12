import Foundation
import SpravaKit

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
    /// Returns where the file was put, when it could be.
    public static func loadAtStart(_ dir: URL, now: Date = Date()) -> (RuntimeState, setAside: URL?) {
        let today = CalendarDate.today(now: now).description
        if let state = try? read(dir, today: today) { return (state, nil) }
        var state = RuntimeState()
        state.day = today
        state.lastSummaryDate = today
        return (state, UnreadableStateFile.setAside(url(dir), now: now))
    }

    /// Reads, changes and saves. A file that cannot be read is left for the next start to set aside and the change
    /// is dropped; returns whether it was saved.
    @discardableResult
    public static func update(_ dir: URL, _ change: (inout RuntimeState) -> Void) -> Bool {
        guard var state = try? read(dir) else { return false }
        change(&state)
        guard let data = try? JSONEncoder().encode(state), (try? StateFile.write(data, to: url(dir))) != nil else { return false }
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

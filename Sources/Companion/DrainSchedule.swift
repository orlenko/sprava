import Foundation
import SpravaKit

/// companion-v0 §§9.1–9.2: ephemeral fairness and device backoff, driven only by the Mac's clock.
/// The drain owns this value and records a turn only after its decisions have durably committed.
public struct CompanionDrainSchedule: Sendable {
    private struct Retry: Sendable {
        var minutes: Int
        var after: Date
    }
    private var retries: [String: Retry] = [:]
    private var active = Set<String>()
    private var previousStart: String?

    public init() {}

    /// Rotate the nominal start before filtering retries: a blocked starting device never holds others up.
    public mutating func plan(activeDevices: [String], now: String) throws -> [String] {
        let time = try macTime(now)
        guard activeDevices.count <= 20, activeDevices.allSatisfy(CompanionWire.isID),
              Set(activeDevices).count == activeDevices.count else { throw CompanionRelayError.invalid }
        let ordered = activeDevices.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let members = Set(ordered)
        retries = retries.filter { members.contains($0.key) }
        active = members
        guard !ordered.isEmpty else { previousStart = nil; return [] }
        let start: Int
        if let previousStart {
            start = ordered.firstIndex { previousStart.utf8.lexicographicallyPrecedes($0.utf8) } ?? 0
        } else { start = 0 }
        previousStart = ordered[start]
        let rotated = Array(ordered[start...]) + Array(ordered[..<start])
        return rotated.filter { retries[$0].map { $0.after <= time } ?? true }
    }

    /// Idle drains retain the failure chain; any committed decision resets it, even before a later failure.
    public mutating func recordTurn(deviceID: String, decisionsCommitted: Int,
                                    retryableFailure: Bool, now: String) throws {
        let time = try macTime(now)
        guard active.contains(deviceID), (0...500).contains(decisionsCommitted) else { throw CompanionRelayError.invalid }
        if decisionsCommitted > 0 { retries.removeValue(forKey: deviceID) }
        guard retryableFailure else { return }
        let minutes = min(60, (retries[deviceID]?.minutes ?? 0) * 2)
        let delay = max(1, minutes)
        retries[deviceID] = Retry(minutes: delay, after: time.addingTimeInterval(TimeInterval(delay * 60)))
    }

    private func macTime(_ now: String) throws -> Date {
        guard CompanionOwnerRelay.time(now), let date = Timestamp.parse(now) else { throw CompanionRelayError.invalid }
        return date
    }
}

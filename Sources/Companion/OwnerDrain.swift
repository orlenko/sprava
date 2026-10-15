import Foundation

/// The higher adapter holds the device decision lock, recovers pending decisions first, then collects,
/// decides in sequence order, commits each exact effect, and only then deletes its relay request (§9.2).
/// It returns all consumed costs and committed decisions, including work before a retryable device failure.
public struct CompanionDeviceDrainTurn: Sendable {
    public let downloadedBytes: Int
    public let fetches: Int
    public let checkedRequests: Int
    public let decisionsCommitted: Int
    public let needsRetry: Bool
    /// A job failure stops every device, while retaining this turn's consumed costs and committed progress.
    public let jobFailure: (any Error)?
    public init(downloadedBytes: Int = 0, fetches: Int = 0, checkedRequests: Int = 0,
                decisionsCommitted: Int = 0, needsRetry: Bool = false, jobFailure: (any Error)? = nil) {
        self.downloadedBytes = downloadedBytes; self.fetches = fetches
        self.checkedRequests = checkedRequests; self.decisionsCommitted = decisionsCommitted
        self.needsRetry = needsRetry
        self.jobFailure = jobFailure
    }
}
public struct CompanionDrainReport: Sendable {
    public let visitedDevices: [String]
    public let downloadedBytes: Int
    public let fetches: Int
    public let checkedRequests: Int
    public let decisionsCommitted: Int
}

/// companion-v0 §§9.1–9.2: one bounded drain, fair device turns, and outcomes even after a job failure.
/// This coordinator performs no binder reads/effects. Network and lock ownership belong to its adapters.
public actor CompanionOwnerDrain {
    private var schedule = CompanionDrainSchedule()
    private var busy = false
    public init() {}

    /// `now` supplies the Mac's canonical UTC clock at planning and at each completed turn.
    /// Device failures return `needsRetry`; transport, owner-token and disk failures throw and stop turns.
    /// The outcomes callback publishes only dirty outcomes and obeys current owner admission/revocation.
    public func drain(activeDevices: [String], now: @Sendable () -> String,
                      turn: @Sendable (String, CompanionCollectionAllowance) async throws -> CompanionDeviceDrainTurn,
                      publishOutcomes: @Sendable (String) async throws -> Void) async throws -> CompanionDrainReport {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        let planned = try schedule.plan(activeDevices: activeDevices, now: now())
        busy = true; defer { busy = false }
        var visited: [String] = []
        var bytes = 0, fetches = 0, checked = 0, committed = 0
        var failure: (any Error)?
        do {
            for device in planned {
                guard bytes < 8388608, fetches < 100, checked < 100 else { break }
                try Task.checkCancellation()
                let remaining = try CompanionCollectionAllowance(downloadBytes: 8388608 - bytes,
                    fetches: 100 - fetches, checkedRequests: 100 - checked)
                visited.append(device)
                let result = try await turn(device, remaining)
                // Check before arithmetic: bad adapter counters cannot overflow or give a later device extra budget.
                guard (0...remaining.downloadBytes).contains(result.downloadedBytes),
                      (0...min(25, remaining.fetches)).contains(result.fetches),
                      (0...min(25, remaining.checkedRequests)).contains(result.checkedRequests),
                      (0...500).contains(result.decisionsCommitted) else { throw CompanionRelayError.invalid }
                bytes += result.downloadedBytes; fetches += result.fetches
                checked += result.checkedRequests; committed += result.decisionsCommitted
                try schedule.recordTurn(deviceID: device, decisionsCommitted: result.decisionsCommitted,
                                        retryableFailure: result.needsRetry, now: now())
                if let failure = result.jobFailure { throw failure }
            }
        } catch { failure = error }
        // Dirty outcomes may belong to a backed-off or unvisited device. One publishing failure never suppresses others.
        for device in activeDevices.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            do { try await publishOutcomes(device) }
            catch { if failure == nil { failure = error } }
        }
        if let failure { throw failure }
        return CompanionDrainReport(visitedDevices: visited, downloadedBytes: bytes, fetches: fetches,
                                    checkedRequests: checked, decisionsCommitted: committed)
    }
}

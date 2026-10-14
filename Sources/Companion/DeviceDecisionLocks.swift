import Foundation

/// companion-v0 §§4.4, 9.2, 9.9: shared exclusion across a device's decisions, revocation and outcomes.
/// Services owns one instance per profile and uses it for every such operation, including network awaits.
/// Contention refuses the new operation immediately; it never queues unbounded work or runs its callback.
public actor CompanionDeviceDecisionLocks {
    private var held: Set<String> = []
    public init() {}

    public func withLock<Result: Sendable>(deviceID: String,
        operation: @Sendable () async throws -> Result) async throws -> Result {
        guard CompanionWire.isID(deviceID) else { throw CompanionRelayError.invalid }
        try Task.checkCancellation()
        // Only twenty devices can be active. Bound even callers that supply other canonical ids.
        guard held.count < 20, !held.contains(deviceID) else { throw CompanionOwnerConnectionError.busy }
        held.insert(deviceID)
        defer { held.remove(deviceID) }
        return try await operation()
    }
}

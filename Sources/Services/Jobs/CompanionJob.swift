import Companion

/// companion-v0 §§6, 9.2: admit one bounded companion run only after owner recovery succeeds.
/// The injected work owns reconciliation, bounded draining and publication through lower interfaces.
/// Every device operation uses the session's shared locks and rechecks admission after awaits (§9.3).
/// Timer registration and binder adapters stay outside.
public actor CompanionJob {
    private let session: CompanionOwnerSession
    private let work: @Sendable (CompanionDeviceDecisionLocks) async throws -> Void
    private var running = false

    public init(session: CompanionOwnerSession,
                work: @escaping @Sendable (CompanionDeviceDecisionLocks) async throws -> Void) {
        self.session = session; self.work = work
    }

    public func run() async -> JobOutcome {
        guard !running else { return .skipped }
        running = true; defer { running = false }
        do {
            try Task.checkCancellation()
            let status = try await session.recoverClaim()
            try Task.checkCancellation()
            switch status {
            case .notConfigured: return .idle
            case .claim(.claimed):
                try await work(session.deviceDecisionLocks)
                return .ok
            case .claim(.pending): return .error(code: "companion_claim_pending", culprit: nil)
            case .claim(.checkingRefusal): return .error(code: "companion_owner_refused", culprit: nil)
            case .claim(.needsReset): return .error(code: "companion_needs_reset", culprit: nil)
            case .claim(.instanceChanged): return .error(code: "companion_instance_changed", culprit: nil)
            }
        } catch CompanionOwnerConnectionError.busy {
            return .skipped
        } catch is CancellationError {
            return .skipped
        } catch {
            // Error descriptions may contain file paths, relay bodies or binder content.
            return .error(code: "companion_failed", culprit: nil)
        }
    }
}

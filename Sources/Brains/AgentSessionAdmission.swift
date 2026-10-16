import Foundation

/// Runtime-owned admission for conversation.md §§10–11.1: one driver per session, separate process caps.
/// Share ONE instance across all runtime drivers. This does not replace the external-session/start-up check.
/// Reservations count before spawning. Retirement requests never free a slot: only a confirmed process exit
/// (including a failed spawn that created no process) does. The caller durably queues work on refusal.
public actor AgentSessionAdmission {
    public enum Kind: Sendable { case conversation, task }
    public enum Failure: Error { case invalidLimits }
    public struct Lease: Sendable, Equatable {
        public let sessionID: UUID
        fileprivate let generation: UUID
    }
    public enum Admission: Sendable, Equatable {
        case reserved(Lease)
        case occupied
        /// A candidate is idle, never starting or in a turn. It is still reserved and must be retired.
        case capacity(idleCandidate: Lease?)
    }
    private enum Phase { case starting, idle, working, retiring }
    private struct Entry {
        let lease: Lease
        let kind: Kind
        var phase: Phase
        var idleOrder: UInt64
    }
    private let conversationLimit: Int
    private let taskLimit: Int
    private var entries: [UUID: Entry] = [:]
    private var order: UInt64 = 0

    /// Limits are runtime configuration, not values supplied by a model or binder.
    public init(conversationLimit: Int, taskLimit: Int) throws {
        guard conversationLimit > 0, taskLimit > 0 else { throw Failure.invalidLimits }
        self.conversationLimit = conversationLimit; self.taskLimit = taskLimit
    }

    public func reserve(sessionID: UUID, kind: Kind) -> Admission {
        guard entries[sessionID] == nil else { return .occupied }
        let sameKind = entries.values.filter { $0.kind == kind }
        let limit = kind == .conversation ? conversationLimit : taskLimit
        guard sameKind.count < limit else {
            let candidate = sameKind.filter { $0.phase == .idle }.min { $0.idleOrder < $1.idleOrder }
            return .capacity(idleCandidate: candidate?.lease)
        }
        let lease = Lease(sessionID: sessionID, generation: UUID())
        entries[sessionID] = Entry(lease: lease, kind: kind, phase: .starting, idleOrder: 0)
        return .reserved(lease)
    }

    /// Called after a successful spawn and all fail-closed start-up checks, before any turn is submitted.
    @discardableResult public func started(_ lease: Lease) -> Bool {
        guard var entry = matching(lease), entry.phase == .starting else { return false }
        order &+= 1; entry.phase = .idle; entry.idleOrder = order; entries[lease.sessionID] = entry
        return true
    }

    @discardableResult public func beginTurn(_ lease: Lease) -> Bool {
        guard var entry = matching(lease), entry.phase == .idle else { return false }
        entry.phase = .working; entries[lease.sessionID] = entry; return true
    }

    /// Only a genuine engine terminal result completes a turn; stream EOF alone is not success.
    @discardableResult public func finishedTurn(_ lease: Lease) -> Bool {
        guard var entry = matching(lease), entry.phase == .working else { return false }
        order &+= 1; entry.phase = .idle; entry.idleOrder = order; entries[lease.sessionID] = entry
        return true
    }

    /// Atomically rechecks an idle candidate; it may have begun a turn since capacity was reported.
    /// Returns true once, so the driver sends one retirement request. A running turn is never evicted.
    @discardableResult public func retireIdle(_ lease: Lease) -> Bool {
        guard var entry = matching(lease), entry.phase == .idle else { return false }
        entry.phase = .retiring; entries[lease.sessionID] = entry; return true
    }

    /// Stop/offload may retire an active turn. Late completion cannot reopen admission afterward.
    @discardableResult public func stop(_ lease: Lease) -> Bool {
        guard var entry = matching(lease), entry.phase != .retiring else { return false }
        entry.phase = .retiring; entries[lease.sessionID] = entry; return true
    }

    /// The process owner must have confirmed death, or confirmed that a failed start spawned nothing.
    /// SIGTERM/SIGKILL, cancellation, a result event and dropping the UI stream are not proof of death.
    /// A stale exit callback can never release a replacement driver's reservation.
    @discardableResult public func confirmedExit(_ lease: Lease) -> Bool {
        guard matching(lease) != nil else { return false }
        entries.removeValue(forKey: lease.sessionID); return true
    }

    private func matching(_ lease: Lease) -> Entry? {
        guard let entry = entries[lease.sessionID], entry.lease == lease else { return nil }
        return entry
    }
}

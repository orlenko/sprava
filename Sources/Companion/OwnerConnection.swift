import Foundation
import SpravaKit

public enum CompanionOwnerClaimState: String, Sendable {
    case pending, claimed
    case checkingRefusal = "checking-refusal"
    case needsReset = "needs-reset"
    case instanceChanged = "instance-changed"
    var terminal: Bool { self == .needsReset || self == .instanceChanged }
}
public enum CompanionOwnerConnectionError: Error, Equatable {
    case busy
    case relayRejected(Int)
}

// The concrete transport bounds each call to 30 seconds. No retry loop or network under a SQLite transaction.
protocol OwnerClaimTransport: Sendable {
    func health() async throws -> CompanionRelayReply<CompanionRelayHealth>
    func claim(_ body: Data) async throws -> Int
}
extension CompanionOwnerRelay: OwnerClaimTransport {}

extension CompanionProfile {
    /// companion-v0 §6: a refused token must survive restart before checking public health.
    public func ownerClaimState() throws -> CompanionOwnerClaimState {
        try store.read { try claimState($0) }
    }
    func claimState(_ t: Transaction) throws -> CompanionOwnerClaimState {
        guard try epoch(t) != nil else { throw CompanionCredentialError.unavailable }
        let rows = try t.rows("SELECT claim_state FROM profile WHERE slot = 1")
        guard rows.count == 1, let raw = rows[0].first?.text,
              let state = CompanionOwnerClaimState(rawValue: raw) else { throw CompanionCredentialError.invalid }
        return state
    }
    @discardableResult
    func recordClaimState(_ state: CompanionOwnerClaimState,
                          expected: CompanionOwnerClaimState? = nil) throws -> CompanionOwnerClaimState {
        try store.write { t in
            let current = try claimState(t)
            // A stale success from another connection can never reopen a retired claim.
            if current.terminal { return current }
            if let expected, current != expected { return current }
            try t.execute("UPDATE profile SET claim_state = ? WHERE slot = 1", .text(state.rawValue))
            return state
        }
    }
}

/// companion-v0 §§6, 9.3: restartable owner claim admission; no binder access or automatic reconfiguration.
/// Prepare the vault and account explicitly first. This initializer performs no network calls.
public actor CompanionOwnerConnection {
    private let profile: CompanionProfile
    private let credentials: CompanionOwnerCredentials
    private let transport: any OwnerClaimTransport
    private var busy = false

    public init(profile: CompanionProfile) throws {
        guard let credentials = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay),
              try profile.currentAccount() != nil else { throw CompanionCredentialError.unavailable }
        self.profile = profile; self.credentials = credentials
        transport = try CompanionOwnerRelay(relay: profile.relay, token: credentials.ownerToken)
    }
    init(profile: CompanionProfile, transport: any OwnerClaimTransport) throws {
        guard let credentials = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay),
              try profile.currentAccount() != nil else { throw CompanionCredentialError.unavailable }
        self.profile = profile; self.credentials = credentials; self.transport = transport
    }

    /// One bounded attempt (at most health, claim, health). A pending result needs a later caller retry.
    /// Even a retired claim may check health; it never sends another claim or owner request.
    public func recoverClaim() async throws -> CompanionOwnerClaimState {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        busy = true; defer { busy = false }
        return try await recover()
    }

    /// Call after any authenticated endpoint returns 401, before retrying any owner operation.
    public func ownerTokenRefused() async throws -> CompanionOwnerClaimState {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        busy = true; defer { busy = false }
        try profile.recordClaimState(.checkingRefusal)
        return try await recover()
    }

    private func health() async throws -> CompanionRelayHealth {
        let reply = try await transport.health()
        guard reply.status == 200, let value = reply.value else {
            throw CompanionOwnerConnectionError.relayRejected(reply.status)
        }
        return value
    }
    private func recover() async throws -> CompanionOwnerClaimState {
        _ = try profile.ownerClaimState() // Refuse missing/unreadable local state before sending anything.
        let health = try await health()
        let state = try profile.ownerClaimState()
        if state.terminal { return state }
        guard health.instance == profile.relay.instance else {
            return try profile.recordClaimState(.instanceChanged)
        }
        if state == .checkingRefusal && health.claimed {
            return try profile.recordClaimState(.needsReset)
        }
        if state == .claimed && health.claimed { return state }
        // Health alone does not prove ownership. A pending claim needs its own 204 and subsequent health.
        let pending = try profile.recordClaimState(.pending, expected: state)
        if pending != .pending { return pending }
        let status = try await transport.claim(credentials.claimBody)
        if status == 409 { return try profile.recordClaimState(.needsReset) }
        guard status == 204 else { throw CompanionOwnerConnectionError.relayRejected(status) }
        let after = try await self.health()
        guard after.instance == profile.relay.instance else {
            return try profile.recordClaimState(.instanceChanged)
        }
        return try profile.recordClaimState(after.claimed ? .claimed : .pending, expected: .pending)
    }
}

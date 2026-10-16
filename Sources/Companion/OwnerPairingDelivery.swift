import Foundation

public enum CompanionPairingDeliveryProgress: Sendable {
    case waiting(retryAt: String)
    case acknowledged
    case notConfirmed
}
public enum CompanionPairingDeliveryError: Error, Equatable { case conflict(Int) }
protocol OwnerDeliveryTransport: Sendable {
    func putObject(name: String, bytes: Data) async throws -> Int
    func deliverKey(pairingID: String, bytes: Data) async throws -> Int
    func pairingState(_ id: String) async throws -> CompanionRelayReply<CompanionRelayPairing.State>
}
extension CompanionOwnerRelay: OwnerDeliveryTransport {}

/// companion-v0 §5.2 steps 4, 6: exact recorded bytes, signed keys first, state-only polls and durable cleanup.
/// Each step makes at most three bounded calls. The caller schedules the returned next-at time.
public actor CompanionOwnerPairingDelivery {
    private let profile: CompanionProfile
    private let connection: CompanionOwnerConnection
    private let transport: any OwnerDeliveryTransport
    private let now: @Sendable () -> String
    private let recoverRefusals: Bool
    private var busy = false
    /// Phone actions defer refused-token recovery to a separate claim action after recording admission closed.
    /// The default preserves automatic recovery for existing background callers (§6).
    public init(profile: CompanionProfile, recoverRefusals: Bool = true) throws {
        guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else { throw CompanionCredentialError.unavailable }
        self.recoverRefusals = recoverRefusals
        self.profile = profile; connection = try CompanionOwnerConnection(profile: profile)
        transport = try CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken)
        now = { Date().ISO8601Format() }
    }
    init(profile: CompanionProfile, connection: CompanionOwnerConnection, transport: any OwnerDeliveryTransport,
         now: @escaping @Sendable () -> String, recoverRefusals: Bool = true) {
        self.profile = profile; self.connection = connection; self.transport = transport; self.now = now
        self.recoverRefusals = recoverRefusals
    }
    private func admit() throws {
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
    }
    private func status(_ status: Int, deviceID: String) async throws {
        if status == 204 { return }
        if status == 401 {
            try profile.recordClaimState(.checkingRefusal)
            if recoverRefusals { _ = try await connection.ownerTokenRefused() }
        }
        if status == 409 || status == 410 {
            try profile.blockDelivery(deviceID, status: status)
            throw CompanionPairingDeliveryError.conflict(status)
        }
        throw CompanionPairingFlowError.relayRejected(status)
    }
    private func expired(_ id: String) throws -> Bool {
        do { _ = try profile.checkPairingLifetime(id, now: now()); return false }
        catch CompanionOwnerPairingError.expired { return true }
    }

    public func step(deviceID: String) async throws -> CompanionPairingDeliveryProgress {
        guard !busy else { throw CompanionPairingFlowError.busy }
        busy = true; defer { busy = false }
        guard let delivery = try profile.pairingDelivery(deviceID: deviceID) else { throw CompanionOwnerPairingError.invalid }
        if delivery.acknowledged {
            try profile.finishPairingSecrets(deviceID: deviceID); return .acknowledged
        }
        // Expiry cleans up locally even when claim admission is suspended, retaining the active device's Kd.
        if try expired(deviceID) { return .notConfirmed }
        try admit()
        let attempt = try profile.reserveDeliveryAttempt(deviceID, now: now())
        if let blocked = attempt.schedule.blocked { throw CompanionPairingDeliveryError.conflict(blocked) }
        if !attempt.send { return .waiting(retryAt: attempt.retryAt) }
        if !attempt.schedule.keysUploaded {
            let reply = try await transport.putObject(name: delivery.keysName, bytes: delivery.deviceKeys)
            try await status(reply, deviceID: deviceID)
            try profile.recordDeliveryUpload(deviceID, wrapped: false)
            if try expired(deviceID) { return .notConfirmed }
            try admit()
        }
        if !attempt.schedule.wrappedUploaded {
            let reply = try await transport.deliverKey(pairingID: delivery.pairingID, bytes: delivery.wrappedKey)
            if reply == 404, try expired(deviceID) { return .notConfirmed }
            try await status(reply, deviceID: deviceID)
            try profile.recordDeliveryUpload(deviceID, wrapped: true)
            if try expired(deviceID) { return .notConfirmed }
            try admit()
        }
        let reply = try await transport.pairingState(delivery.pairingID)
        if reply.status == 401 {
            try profile.recordClaimState(.checkingRefusal)
            guard recoverRefusals else { throw CompanionPairingFlowError.relayRejected(401) }
            _ = try await connection.ownerTokenRefused()
        }
        if try expired(deviceID) { return .notConfirmed }
        try admit()
        guard reply.status == 200, let state = reply.value else { throw CompanionPairingFlowError.relayRejected(reply.status) }
        if state == .acknowledged {
            try profile.acknowledgePairing(deviceID: deviceID); return .acknowledged
        }
        let next = try profile.paceAcknowledgmentPoll(deviceID, now: now())
        return .waiting(retryAt: next)
    }
}

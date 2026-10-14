import Foundation
import SpravaKit

public struct CompanionPairingStart: Sendable {
    public let deviceID: String
    public let ownerPublicKey: Data
    /// Secret link material, for the QR screen only; never log this value.
    public let created: CompanionCreatedPairing
    public let deadline: String
}
public enum CompanionPairingPoll: Sendable {
    case waiting(retryAt: String)
    case confirmation(CompanionPairingApproval)
}
public enum CompanionPairingFlowError: Error, Equatable {
    case busy
    case ownerUnavailable(CompanionOwnerClaimState)
    case relayRejected(Int)
}
protocol OwnerPairingTransport: Sendable {
    func createPairing(deviceID: String, publicKey: Data) async throws -> CompanionRelayReply<CompanionCreatedPairing>
    func pairing(_ id: String) async throws -> CompanionRelayReply<CompanionRelayPairing>
}
extension CompanionOwnerRelay: OwnerPairingTransport {}

/// companion-v0 §5.2 steps 1–4: create once, recover a known link, poll at most every two seconds, await approval.
/// Confirmation commits local delivery only; uploading those exact bytes belongs to delivery orchestration.
public actor CompanionOwnerPairingFlow {
    private let profile: CompanionProfile
    private let connection: CompanionOwnerConnection
    private let transport: any OwnerPairingTransport
    private let now: @Sendable () -> String
    private var busy = false

    public init(profile: CompanionProfile) throws {
        guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else { throw CompanionCredentialError.unavailable }
        self.profile = profile
        connection = try CompanionOwnerConnection(profile: profile)
        transport = try CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken)
        now = { Date().ISO8601Format() }
    }
    init(profile: CompanionProfile, connection: CompanionOwnerConnection, transport: any OwnerPairingTransport,
         now: @escaping @Sendable () -> String) {
        self.profile = profile; self.connection = connection; self.transport = transport; self.now = now
    }
    private func admit() throws {
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
    }
    private func rejected(_ status: Int) async throws -> Never {
        if status == 401 { _ = try await connection.ownerTokenRefused() }
        throw CompanionPairingFlowError.relayRejected(status)
    }

    public func start() async throws -> CompanionPairingStart {
        guard !busy else { throw CompanionPairingFlowError.busy }
        busy = true; defer { busy = false }
        try admit()
        let reserved = try profile.reservePairing()
        try profile.startPairingSchedule(reserved.deviceID, now: now())
        let attempt = try profile.beginPairingCreation(deviceID: reserved.deviceID)
        let reply: CompanionRelayReply<CompanionCreatedPairing>
        do { reply = try await transport.createPairing(deviceID: attempt.deviceID, publicKey: attempt.ownerPublicKey) }
        catch { try profile.abandonPairing(deviceID: attempt.deviceID); throw error }
        guard reply.status == 200, let created = reply.value else {
            if reply.status == 401 { try profile.recordClaimState(.checkingRefusal) }
            try profile.abandonPairing(deviceID: attempt.deviceID)
            try await rejected(reply.status)
        }
        // A failed protected write/reference is recovered by resume, never by repeating POST for D.
        try profile.captureCreatedPairing(deviceID: attempt.deviceID, created: created)
        try profile.boundPairingSchedule(attempt.deviceID, expires: created.expiresAt)
        let deadline = try profile.checkPairingLifetime(attempt.deviceID, now: now())
        try admit()
        return CompanionPairingStart(deviceID: attempt.deviceID, ownerPublicKey: attempt.ownerPublicKey, created: created, deadline: deadline)
    }

    /// Local restart recovery only. An attempted creation without a known result is abandoned, never repeated.
    public func resume(deviceID: String) throws -> CompanionPairingStart? {
        guard !busy else { throw CompanionPairingFlowError.busy }
        try admit()
        guard CompanionWire.isID(deviceID) else { throw CompanionOwnerPairingError.invalid }
        let r = try profile.store.read { try profile.record(deviceID, $0) }
        guard let r, r.state == .pairing else { return nil }
        guard r.creationAttempted, let created = try profile.createdPairing(deviceID: deviceID) else {
            try profile.abandonPairing(deviceID: deviceID); return nil
        }
        try profile.boundPairingSchedule(deviceID, expires: created.expiresAt)
        let deadline = try profile.checkPairingLifetime(deviceID, now: now())
        let reservation = try profile.preparePairingReservation(deviceID: deviceID)
        return CompanionPairingStart(deviceID: deviceID, ownerPublicKey: reservation.ownerPublicKey, created: created, deadline: deadline)
    }

    /// One poll, with a durable next-at time. The caller schedules another turn; there is no background retry loop.
    public func poll(deviceID: String) async throws -> CompanionPairingPoll {
        guard !busy else { throw CompanionPairingFlowError.busy }
        busy = true; defer { busy = false }
        try admit()
        _ = try profile.checkPairingLifetime(deviceID, now: now())
        guard let created = try profile.createdPairing(deviceID: deviceID) else { throw CompanionOwnerPairingError.invalid }
        let slot = try profile.reservePairingPoll(deviceID, now: now())
        if !slot.send { return .waiting(retryAt: slot.retryAt) }
        let reply = try await transport.pairing(created.id)
        if reply.status == 401 {
            try profile.recordClaimState(.checkingRefusal)
            try await rejected(reply.status)
        }
        _ = try profile.checkPairingLifetime(deviceID, now: now())
        try admit()
        if reply.status == 404 {
            try profile.abandonPairing(deviceID: deviceID)
            throw CompanionOwnerPairingError.expired
        }
        guard reply.status == 200, let response = reply.value else { try await rejected(reply.status) }
        if let approval = try profile.observePairing(deviceID: deviceID, response: response) { return .confirmation(approval) }
        return .waiting(retryAt: slot.retryAt)
    }

    /// companion-v0 §5.2 steps 3–4: restore the same code after restart without polling or activating the phone.
    public func approval(deviceID: String) throws -> CompanionPairingApproval? {
        guard !busy else { throw CompanionPairingFlowError.busy }
        try admit()
        _ = try profile.checkPairingLifetime(deviceID, now: now())
        return try profile.recordedPairingApproval(deviceID: deviceID)
    }

    /// Called only after the person compares both screens and approves this opaque confirmation context.
    public func confirm(_ approval: CompanionPairingApproval) throws -> CompanionPairingDelivery {
        guard !busy else { throw CompanionPairingFlowError.busy }
        try admit()
        _ = try profile.checkPairingLifetime(approval.deviceID, now: now())
        guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else { throw CompanionCredentialError.unavailable }
        return try profile.confirmPairing(approval, credentials: owner, now: now())
    }
}

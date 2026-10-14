import Foundation
import SpravaKit

public struct CompanionAbandonedPairing: Sendable, Equatable {
    public let deviceID: String
    public let pairingID: String
}

extension CompanionProfile {
    /// companion-v0 §5.2: an abandoned device retains its known pairing ID until relay deletion is acknowledged.
    /// This keyless page excludes active devices and unknown create results; D is never reused.
    public func abandonedPairings(limit: Int = 20, after: String? = nil) throws -> [CompanionAbandonedPairing] {
        guard (1...20).contains(limit) else { throw CompanionOwnerPairingError.invalid }
        if let after, !CompanionWire.isID(after) { throw CompanionOwnerPairingError.invalid }
        return try store.read { t in
            try t.rows("""
                SELECT d.device, p.pairing FROM devices d JOIN pairings p ON p.device = d.device
                WHERE d.state = 'abandoned' AND d.device > ? ORDER BY d.device LIMIT ?
                """, .text(after ?? ""), .integer(Int64(limit))).map { row in
                guard row.count == 2, let d = row[0].text, CompanionWire.isID(d),
                      let p = row[1].text, CompanionWire.isID(p) else { throw CompanionOwnerPairingError.invalid }
                return CompanionAbandonedPairing(deviceID: d, pairingID: p)
            }
        }
    }
    func abandonedPairing(deviceID: String) throws -> CompanionAbandonedPairing? {
        guard CompanionWire.isID(deviceID) else { throw CompanionOwnerPairingError.invalid }
        return try store.read { t in
            guard try record(deviceID, t)?.state == .abandoned else { return nil }
            guard let row = try t.rows("SELECT pairing FROM pairings WHERE device = ?", .text(deviceID)).first else { return nil }
            guard row.count == 1, let p = row[0].text, CompanionWire.isID(p) else { throw CompanionOwnerPairingError.invalid }
            return CompanionAbandonedPairing(deviceID: deviceID, pairingID: p)
        }
    }
    func acknowledgeAbandonedPairing(_ pending: CompanionAbandonedPairing) throws {
        try store.write { t in
            guard try record(pending.deviceID, t)?.state == .abandoned else { throw CompanionOwnerPairingError.invalid }
            guard let row = try t.rows("SELECT pairing FROM pairings WHERE device = ?", .text(pending.deviceID)).first else { return }
            guard row.count == 1, row[0].text == pending.pairingID else { throw CompanionOwnerPairingError.invalid }
            try t.execute("DELETE FROM pairings WHERE device = ?", .text(pending.deviceID))
            // Keep the device ID and any pending protected-key cleanup; these records do not need P.
        }
    }
}

protocol OwnerPairingCleanupTransport: Sendable {
    func deletePairing(_ id: String) async throws -> Int
}
extension CompanionOwnerRelay: OwnerPairingCleanupTransport {}

public enum CompanionPairingCleanupProgress: Sendable, Equatable { case nothingPending, deleted }

/// One bounded owner DELETE per turn (§5.2). A lost reply or restart leaves the same durable ID pending.
/// Claim recovery stays in the shared owner lane; a 401 suspends admission before another cleanup call.
public actor CompanionOwnerPairingCleanup {
    private let profile: CompanionProfile
    private let transport: @Sendable () throws -> any OwnerPairingCleanupTransport
    private var busy = false

    /// Construction is keyless. Owner credentials are loaded only for an admitted, recorded cleanup.
    public init(profile: CompanionProfile) {
        self.profile = profile
        transport = {
            guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else {
                throw CompanionCredentialError.unavailable
            }
            return try CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken)
        }
    }
    init(profile: CompanionProfile, transport: any OwnerPairingCleanupTransport) {
        self.profile = profile; self.transport = { transport }
    }
    public func step(deviceID: String) async throws -> CompanionPairingCleanupProgress {
        guard !busy else { throw CompanionPairingFlowError.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        guard let pending = try profile.abandonedPairing(deviceID: deviceID) else { return .nothingPending }
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
        let status = try await transport().deletePairing(pending.pairingID)
        if status == 401 { try profile.recordClaimState(.checkingRefusal) }
        guard status == 204 || status == 404 else { throw CompanionPairingFlowError.relayRejected(status) }
        try profile.acknowledgeAbandonedPairing(pending)
        return .deleted
    }
}

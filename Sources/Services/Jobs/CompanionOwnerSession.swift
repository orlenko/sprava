import Companion
import Foundation

public enum CompanionOwnerRuntimeStatus: Sendable, Equatable {
    case notConfigured
    case claim(CompanionOwnerClaimState)
}

/// Runtime owns one session per profile and shares its device locks with decisions, publication and removal.
/// Explicit paths/backends only. Status reads keyless metadata and remains available during network recovery.
/// The profile is reopened lazily so setup performed after startup is visible without restarting (§6).
public actor CompanionOwnerSession {
    public let deviceDecisionLocks = CompanionDeviceDecisionLocks()
    private let database: URL
    private let secrets: any CompanionCredentialStorage
    private let recover: @Sendable (CompanionProfile) async throws -> CompanionOwnerClaimState
    private let prepare: @Sendable (String, String, String?) async throws -> CompanionProfile
    /// Pairing steps for one opened profile; tests replace the relay-backed flow and delivery.
    nonisolated let pairing: @Sendable (CompanionProfile) throws -> CompanionPairingSteps
    /// One bounded removal/rotation step for an opened profile (§4.4); tests replace the relay.
    nonisolated let rotation: @Sendable (CompanionProfile) -> @Sendable () async throws -> CompanionRotationProgress
    private var recovering = false
    static let relayRotation: @Sendable (CompanionProfile) -> @Sendable () async throws -> CompanionRotationProgress = { profile in
        let worker = CompanionOwnerRotation(profile: profile)
        return { try await worker.step() }
    }

    public init(database: URL, secrets: any CompanionCredentialStorage) {
        self.database = database; self.secrets = secrets
        recover = { try await CompanionOwnerConnection(profile: $0).recoverClaim() }
        prepare = { origin, code, web in
            try await CompanionOwnerSetup.prepare(database: database, origin: origin, setupCode: code,
                                                  webOrigin: web, secrets: secrets)
        }
        pairing = CompanionPairingSteps.relay
        rotation = Self.relayRotation
    }
    init(database: URL, secrets: any CompanionCredentialStorage,
         recover: @escaping @Sendable (CompanionProfile) async throws -> CompanionOwnerClaimState,
         prepare: (@Sendable (String, String, String?) async throws -> CompanionProfile)? = nil,
         pairing: (@Sendable (CompanionProfile) throws -> CompanionPairingSteps)? = nil,
         rotation: (@Sendable (CompanionProfile) -> @Sendable () async throws -> CompanionRotationProgress)? = nil) {
        self.database = database; self.secrets = secrets; self.recover = recover
        self.prepare = prepare ?? { origin, code, web in
            try await CompanionOwnerSetup.prepare(database: database, origin: origin, setupCode: code,
                                                  webOrigin: web, secrets: secrets)
        }
        self.pairing = pairing ?? CompanionPairingSteps.relay
        self.rotation = rotation ?? Self.relayRotation
    }
    /// Setup and background claim recovery share one admission slot, while keyless status stays readable.
    /// Preparation stores the immutable identity; a separate claim action performs owner admission (§6).
    public func configure(origin: String, setupCode: String, webOrigin: String?) async throws -> CompanionOwnerRuntimeStatus {
        guard !recovering else { throw CompanionOwnerConnectionError.busy }
        try Task.checkCancellation()
        recovering = true; defer { recovering = false }
        let profile = try await prepare(origin, setupCode, webOrigin)
        try Task.checkCancellation()
        return .claim(try profile.ownerClaimState())
    }
    /// Other owner actions share setup/recovery admission, without blocking keyless status while awaiting I/O.
    /// The callback owns domain admission (including whether a refused claim permits local recovery),
    /// bounded relay calls and any per-device decision lock. The profile is reopened for each action (§6).
    func withConfiguredProfile<Result: Sendable>(
        _ action: @Sendable (CompanionProfile) async throws -> Result
    ) async throws -> Result? {
        guard !recovering else { throw CompanionOwnerConnectionError.busy }
        try Task.checkCancellation()
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return nil }
        recovering = true; defer { recovering = false }
        let result = try await action(profile)
        try Task.checkCancellation()
        return result
    }
    /// Keyless and local, like status: labels and confirmation states without network or admission (§5.2).
    /// The reader must not load a key or call the relay.
    func readProfile<Result: Sendable>(_ reader: (CompanionProfile) throws -> Result) throws -> Result? {
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return nil }
        return try reader(profile)
    }
    public func snapshot() throws -> CompanionOwnerRuntimeStatus {
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return .notConfigured }
        return .claim(try profile.ownerClaimState())
    }
    /// One bounded owner-connection attempt, with its durable claim/admission behavior owned by Companion.
    /// Disabled sessions do no network/key work. Errors propagate and always release the recovery slot.
    public func recoverClaim() async throws -> CompanionOwnerRuntimeStatus {
        guard !recovering else { throw CompanionOwnerConnectionError.busy }
        try Task.checkCancellation()
        guard let profile = try CompanionProfile.openConfigured(database: database, secrets: secrets) else { return .notConfigured }
        recovering = true; defer { recovering = false }
        return .claim(try await recover(profile))
    }
}

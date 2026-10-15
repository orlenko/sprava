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
    private var recovering = false

    public init(database: URL, secrets: any CompanionCredentialStorage) {
        self.database = database; self.secrets = secrets
        recover = { try await CompanionOwnerConnection(profile: $0).recoverClaim() }
        prepare = { origin, code, web in
            try await CompanionOwnerSetup.prepare(database: database, origin: origin, setupCode: code,
                                                  webOrigin: web, secrets: secrets)
        }
    }
    init(database: URL, secrets: any CompanionCredentialStorage,
         recover: @escaping @Sendable (CompanionProfile) async throws -> CompanionOwnerClaimState,
         prepare: (@Sendable (String, String, String?) async throws -> CompanionProfile)? = nil) {
        self.database = database; self.secrets = secrets; self.recover = recover
        self.prepare = prepare ?? { origin, code, web in
            try await CompanionOwnerSetup.prepare(database: database, origin: origin, setupCode: code,
                                                  webOrigin: web, secrets: secrets)
        }
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

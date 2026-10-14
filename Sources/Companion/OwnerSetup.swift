import Foundation
import SpravaKit

public enum CompanionOwnerSetupError: Error, Equatable {
    case invalid, relayUnavailable, alreadyClaimed, reconfigurationRequired
}

/// companion-v0 §6: discover the binding, then persist the immutable claim identity before any claim POST.
/// Setup does not claim, reset, or replace an account. The caller supplies a vault backend and explicit path.
public enum CompanionOwnerSetup {
    public static func prepare(database: URL, origin: String, setupCode: String, webOrigin: String? = nil,
                               secrets: any CompanionCredentialStorage) async throws -> CompanionProfile {
        try await prepare(database: database, origin: origin, setupCode: setupCode, webOrigin: webOrigin,
                          secrets: secrets, discover: { origin in
            let response = try await CompanionOwnerRelay.health(origin: origin)
            guard response.status == 200, let health = response.value else {
                throw CompanionOwnerSetupError.relayUnavailable
            }
            return health
        })
    }

    static func prepare(database: URL, origin: String, setupCode: String, webOrigin: String? = nil,
                        secrets: any CompanionCredentialStorage,
                        discover: @Sendable (String) async throws -> CompanionRelayHealth) async throws -> CompanionProfile {
        guard CompanionRelayIdentity.validOrigin(origin), CompanionOwnerVault.validSetupCode(setupCode),
              webOrigin.map(CompanionRelayIdentity.validOrigin) ?? true else { throw CompanionOwnerSetupError.invalid }
        try Task.checkCancellation()
        let existing = try CompanionProfile.openConfigured(database: database, secrets: secrets)
        if let existing {
            guard existing.relay.origin == origin else { throw CompanionOwnerSetupError.reconfigurationRequired }
            if let saved = try existing.webOrigin(), let webOrigin, saved != webOrigin {
                throw CompanionOwnerSetupError.reconfigurationRequired
            }
        }
        let health = try await discover(origin)
        try Task.checkCancellation()
        let identity = try CompanionRelayIdentity(origin: origin, instance: health.instance)
        if let existing, existing.relay.instance != identity.instance {
            try existing.recordClaimState(.instanceChanged)
            throw CompanionOwnerSetupError.reconfigurationRequired
        }
        let vault = CompanionOwnerVault(backend: secrets)
        let credentials = try vault.load(identity)
        if existing != nil && credentials == nil { throw CompanionCredentialError.unavailable }
        if health.claimed && credentials == nil { throw CompanionOwnerSetupError.alreadyClaimed }
        let selected = try credentials ?? vault.prepare(identity, setupCode: setupCode)
        if try CompanionWire.parse(selected.claimBody, limit: 4096)["setup_code"]?.stringValue != setupCode {
            throw CompanionOwnerSetupError.reconfigurationRequired
        }
        let profile = try existing ?? CompanionProfile(database: database, relay: identity, secrets: secrets)
        _ = try profile.prepareAccount(beforeCommit: {}, webOrigin: webOrigin)
        return profile
    }
}

extension CompanionProfile {
    /// Optional override for the QR target. Nil leaves selection of the shared build to the application.
    /// It contains no credential and is read without accessing the vault.
    public func webOrigin() throws -> String? {
        try store.read { t in
            guard try epoch(t) != nil else { return nil }
            let rows = try t.rows("SELECT web_origin FROM profile WHERE slot = 1")
            guard rows.count == 1, rows[0].count == 1 else { throw CompanionCredentialError.invalid }
            guard let origin = rows[0][0].text else {
                guard rows[0][0] == .null else { throw CompanionCredentialError.invalid }
                return nil
            }
            guard CompanionRelayIdentity.validOrigin(origin) else { throw CompanionCredentialError.invalid }
            return origin
        }
    }
}

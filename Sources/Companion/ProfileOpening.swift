import Foundation
import SpravaKit

extension CompanionProfile {
    /// companion-v0 §§6, 9.1: reopen the persisted relay binding without minting or accessing credentials.
    /// Absent state creates the owning empty private schema and returns nil until an account is prepared.
    /// Existing unreadable or invalid state throws; it is never reset or treated as unconfigured.
    public static func openConfigured(database: URL, secrets: any CompanionCredentialStorage) throws -> CompanionProfile? {
        let store = try StateStore.open(database, schema: schema)
        let identity: CompanionRelayIdentity? = try store.read { t in
            let rows = try t.rows("SELECT origin, instance, epoch FROM profile LIMIT 2")
            guard !rows.isEmpty else { return nil }
            guard rows.count == 1, rows[0].count == 3, let origin = rows[0][0].text,
                  let instance = rows[0][1].text, let epoch = rows[0][2].integer,
                  (1...JSONNumber.maxSafeInteger).contains(epoch) else { throw CompanionCredentialError.invalid }
            return try CompanionRelayIdentity(origin: origin, instance: instance)
        }
        guard let identity else { return nil }
        return try CompanionProfile(database: database, relay: identity, secrets: secrets)
    }
}

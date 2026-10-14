import BinderStore
import Companion
import Foundation
import SpravaKit

extension Commands {
    static let companionCommands: [String: Handler] = [
        "companion_status": { commands, _, _, _, _ in try commands.companionStatus() },
    ]
    /// Owner admission only. No request paths, credentials, network calls or binder reads (§6).
    /// State words are the stable PhoneSettings contract; the app owns their display text.
    func companionStatus() throws -> JSONObject {
        do {
            let database = support.appendingPathComponent("companion/state.sqlite")
            let profile = try CompanionProfile.openConfigured(database: database, secrets: CompanionMetadataCredentials())
            return JSONObject([(key: "state", value: .string(try profile?.ownerClaimState().rawValue ?? "not-configured"))])
        } catch {
            throw Failure(message: "Phone access state is unavailable.")
        }
    }
}

/// A status request cannot become a credential read or write even if its lower implementation changes.
private struct CompanionMetadataCredentials: CompanionCredentialStorage {
    func read(account: String) throws -> Data? { throw CompanionCredentialError.unavailable }
    func insert(account: String, bytes: Data) throws -> Bool { throw CompanionCredentialError.unavailable }
}

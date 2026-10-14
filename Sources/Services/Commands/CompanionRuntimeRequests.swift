import Companion
import Foundation

/// One runtime owner session shared by Phone actions and future jobs; construction performs no I/O (§6).
/// Tests and development supply an explicit isolated backend. Only the production factory chooses Keychain.
public struct CompanionRuntimeRequests: Sendable {
    public let session: CompanionOwnerSession
    public let requests: CompanionRequestQueue

    public init(database: URL, secrets: any CompanionCredentialStorage, watch: WatchBox?) throws {
        try self.init(session: CompanionOwnerSession(database: database, secrets: secrets), watch: watch)
    }
    init(session: CompanionOwnerSession, watch: WatchBox?) throws {
        self.session = session
        requests = try CompanionRequestQueue(handlers: CompanionPhoneActions.handlers(session: session), watch: watch)
    }
    public static func production(support: URL, watch: WatchBox?) throws -> Self {
        try Self(database: support.appendingPathComponent("companion/state.sqlite"),
                 secrets: CompanionKeychain(), watch: watch)
    }
}

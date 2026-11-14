import Companion
import Foundation

/// One runtime owner session shared by Phone actions and future jobs; construction performs no I/O (§6).
/// Tests and development supply an explicit isolated backend. Only the production factory chooses Keychain.
public struct CompanionRuntimeRequests: Sendable {
    public let session: CompanionOwnerSession
    public let requests: CompanionRequestQueue

    public init(database: URL, secrets: any CompanionCredentialStorage, watch: WatchBox?,
                binders: CompanionBinderSwitch? = nil) throws {
        try self.init(session: CompanionOwnerSession(database: database, secrets: secrets), watch: watch, binders: binders)
    }
    init(session: CompanionOwnerSession, watch: WatchBox?, binders: CompanionBinderSwitch? = nil) throws {
        self.session = session
        let handlers = CompanionPhoneActions.handlers(session: session)
            .merging(binders?.handlers(session: session) ?? [:]) { a, _ in a }
        requests = try CompanionRequestQueue(handlers: handlers, watch: watch)
    }
    public static func production(support: URL, deviceID: String, watch: WatchBox?) throws -> Self {
        try Self(database: support.appendingPathComponent("companion/state.sqlite"),
                 secrets: CompanionKeychain(), watch: watch,
                 binders: CompanionBinderSwitch(support: support, deviceID: deviceID))
    }
}

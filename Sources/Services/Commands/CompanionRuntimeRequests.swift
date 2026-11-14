import Companion
import Foundation
import Shelf

/// One runtime owner session shared by Phone actions and the companion job; construction performs no I/O (§6).
/// Tests and development supply an explicit isolated backend. Only the production factory chooses Keychain.
public struct CompanionRuntimeRequests: Sendable {
    public let session: CompanionOwnerSession
    public let requests: CompanionRequestQueue
    /// The companion job, when the runtime publishes (production only). It does nothing until a relay is claimed.
    public let job: CompanionJob?

    public init(database: URL, secrets: any CompanionCredentialStorage, watch: WatchBox?,
                binders: CompanionBinderSwitch? = nil) throws {
        let session = CompanionOwnerSession(database: database, secrets: secrets)
        let job = binders.map {
            CompanionJob.publishing(session: session, database: database, secrets: secrets, support: $0.support, deviceID: $0.deviceID)
        }
        try self.init(session: session, watch: watch, binders: binders, job: job)
    }
    init(session: CompanionOwnerSession, watch: WatchBox?, binders: CompanionBinderSwitch? = nil, job: CompanionJob? = nil) throws {
        self.session = session
        let handlers = CompanionPhoneActions.handlers(session: session)
            .merging(binders?.handlers(session: session) ?? [:]) { a, _ in a }
        requests = try CompanionRequestQueue(handlers: handlers, watch: watch)
        self.job = job
    }
    public static func production(support: URL, deviceID: String, watch: WatchBox?) throws -> Self {
        try Self(database: support.appendingPathComponent("companion/state.sqlite"),
                 secrets: CompanionKeychain(), watch: watch,
                 binders: CompanionBinderSwitch(support: support, deviceID: deviceID))
    }
}

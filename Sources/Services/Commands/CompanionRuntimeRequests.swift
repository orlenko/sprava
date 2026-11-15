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
        let session = CompanionOwnerSession(database: database, secrets: secrets,
                                            settle: binders.map { Self.settling(support: $0.support, deviceID: $0.deviceID) })
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
    /// A reset's first step (companion-v0 §9.4): each phone decision begun and not finished is finished here, on this
    /// Mac, as a drain would before collecting more. One that cannot be finished now (its binder offloaded or busy)
    /// stays recorded, and the reset refuses.
    static func settling(support: URL, deviceID: String) -> @Sendable (CompanionProfile, CompanionDeviceDecisionLocks) async -> Void {
        { profile, locks in
            for device in (try? profile.devicesWithPendingDecisions()) ?? [] {
                let at = CompanionPublishing.time(Date())
                let adapter = CompanionBinderDecisions(profile: profile, support: support, deviceID: deviceID)
                _ = try? await locks.withLock(deviceID: device) {
                    try CompanionDecisionExecution(profile: profile).recoverPending(deviceID: device, today: String(at.prefix(10)),
                                                                                   now: at, adapter: adapter) != nil
                }
            }
        }
    }
    public static func production(support: URL, deviceID: String, watch: WatchBox?) throws -> Self {
        try Self(database: support.appendingPathComponent("companion/state.sqlite"),
                 secrets: CompanionKeychain(), watch: watch,
                 binders: CompanionBinderSwitch(support: support, deviceID: deviceID))
    }
}

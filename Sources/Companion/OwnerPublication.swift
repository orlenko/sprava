import Foundation
import SpravaKit

public enum CompanionPublicationProgress: Sendable {
    case idle
    case waiting(name: String, retryAt: String)
    case uploaded(name: String)
    case superseded(name: String)
}
protocol OwnerPublicationTransport: Sendable {
    func putObject(name: String, bytes: Data) async throws -> Int
}
extension CompanionOwnerRelay: OwnerPublicationTransport {}

/// companion-v0 §9.7: one bounded PUT per call, exact recorded bytes, restartable pacing, no binder reads.
/// A runtime uses one publisher per profile, and routes sharing removal through it to hold its upload lock.
/// Snapshot callers separately hold the binder write lock; a newer snapshot may supersede an in-flight upload.
public actor CompanionOwnerPublication {
    private let profile: CompanionProfile
    private let transport: any OwnerPublicationTransport
    private let now: @Sendable () -> String
    private var busy = false
    public init(profile: CompanionProfile) throws {
        guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else { throw CompanionCredentialError.unavailable }
        self.profile = profile
        transport = try CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken)
        now = { Date().ISO8601Format() }
    }
    init(profile: CompanionProfile, transport: any OwnerPublicationTransport, now: @escaping @Sendable () -> String) {
        self.profile = profile; self.transport = transport; self.now = now
    }
    private func admit() throws {
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
        try profile.admitPublicationEpoch()
    }
    /// A busy removal fails visibly without changing the switch; retry after the bounded upload completes.
    public func hideBinder(_ identity: CompanionLocalBinderIdentity) throws {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        try profile.hideBinder(identity)
        try profile.discardRemovedIndex()
    }
    public func uploadView(binderID: String) async throws -> CompanionPublicationProgress {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        busy = true; defer { busy = false }
        try admit()
        guard let view = try profile.pendingView(binderID: binderID) else { return .idle }
        let attempt = try profile.reservePublicationAttempt(scope: "views/" + binderID, name: view.name, now: now())
        if !attempt.send { return .waiting(name: view.name, retryAt: attempt.next) }
        let status = try await transport.putObject(name: view.name, bytes: view.bytes)
        try refusal(status)
        if status == 409 || status == 410 {
            try profile.supersedeView(view)
            return .superseded(name: view.name)
        }
        guard status == 204 else { throw CompanionOwnerConnectionError.relayRejected(status) }
        return try profile.completeView(view) ? .uploaded(name: view.name) : .superseded(name: view.name)
    }
    public func uploadIndex(generatedAt: String) async throws -> CompanionPublicationProgress {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        busy = true; defer { busy = false }
        try admit()
        try profile.discardRemovedIndex()
        let index = try profile.prepareIndex(generatedAt: generatedAt)
        let attempt = try profile.reservePublicationAttempt(scope: "index", name: index.name, now: now())
        if !attempt.send { return .waiting(name: index.name, retryAt: attempt.next) }
        let status = try await transport.putObject(name: index.name, bytes: index.bytes)
        try refusal(status)
        if status == 409 || status == 410 {
            try profile.supersedeIndex(index)
            return .superseded(name: index.name)
        }
        guard status == 204 else { throw CompanionOwnerConnectionError.relayRejected(status) }
        // Also covers a durable removal by a higher caller before a previous process stopped.
        try profile.discardRemovedIndex()
        return try profile.completeIndex(index) ? .uploaded(name: index.name) : .superseded(name: index.name)
    }
    private func refusal(_ status: Int) throws {
        if status == 401 {
            try profile.recordClaimState(.checkingRefusal)
            throw CompanionOwnerConnectionError.relayRejected(401)
        }
    }
}

extension CompanionProfile {
    func admitPublicationEpoch() throws {
        try store.read { t in
            guard let e = try epoch(t),
                  try t.rows("SELECT 1 FROM recipients r JOIN devices d ON d.device = r.device WHERE r.epoch = ? AND d.state = 'revoked' LIMIT 1",
                             .integer(e)).isEmpty else { throw CompanionPublicationError.unavailable }
        }
    }
    /// A pending index prepared before sharing was switched off must never be resumed after restart.
    func discardRemovedIndex() throws {
        try store.write { t in
            guard let e = try epoch(t) else { throw CompanionPublicationError.invalid }
            try t.execute("UPDATE index_upload SET state = 'superseded' WHERE state = 'uploading' AND (epoch != ? OR EXISTS " +
                "(SELECT 1 FROM index_upload_views v JOIN phone_binders b ON b.binder = v.binder WHERE b.state != 'shown' OR b.key_epoch != ?))",
                .integer(e), .integer(e))
        }
    }
    func reservePublicationAttempt(scope: String, name: String, now: String) throws -> (send: Bool, next: String) {
        guard CompanionOwnerRelay.time(now), let clock = Timestamp.parse(now) else { throw CompanionPublicationError.invalid }
        return try store.write { t in
            let rows = try t.rows("SELECT name, next, attempts FROM publication_attempts WHERE scope = ?", .text(scope))
            var attempts: Int64 = 0
            if let row = rows.first {
                guard row.count == 3, let storedName = row[0].text, let next = row[1].text, CompanionOwnerRelay.time(next),
                      let count = row[2].integer, count >= 1, count <= 5 else { throw CompanionPublicationError.invalid }
                if storedName == name {
                    if next > now { return (false, next) }
                    attempts = count
                }
            }
            attempts = min(attempts + 1, 5)
            let delay: TimeInterval = [2, 5, 10, 20, 30][Int(attempts - 1)]
            let next = clock.addingTimeInterval(delay).ISO8601Format()
            guard CompanionOwnerRelay.time(next) else { throw CompanionPublicationError.invalid }
            try t.execute("INSERT OR REPLACE INTO publication_attempts VALUES (?, ?, ?, ?)", .text(scope), .text(name), .text(next), .integer(attempts))
            return (true, next)
        }
    }
}

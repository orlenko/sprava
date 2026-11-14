import Foundation
import SpravaKit

extension OwnerPublicationTransport {
    /// Transports that never delete refuse; only the relay's own transport sends `DELETE /v0/objects/{name}`.
    func deleteObject(name: String) async throws -> Int { throw CompanionRelayError.invalid }
}
extension CompanionOwnerRelay {
    /// companion-v0 §7.5: `204` also when the name does not exist.
    public func deleteObject(name: String) async throws -> Int {
        guard name.hasPrefix("views/"), name.utf8.count <= 128 else { throw CompanionRelayError.invalid }
        return try await call("/v0/objects/" + name, method: "DELETE").status
    }
}

struct RemovedBinderCleanup: Sendable {
    let binderID: String
    let keyEpoch: Int64
    let next: Int64
    let reserved: Int64
}

extension CompanionOwnerPublication {
    /// companion-v0 §9.7, the case of a binder switched off: once the last published index leaves it out, delete
    /// every view version ever reserved for it, then forget its key. Each deletion answered `204` raises a durable
    /// mark; a failed one stops the pass and the next run retries it, with the key kept until every deletion succeeded.
    /// Returns how many deletions were sent; at most `limit` per call.
    public func cleanRemovedBinders(limit: Int) async throws -> Int {
        guard !busy else { throw CompanionOwnerConnectionError.busy }
        busy = true; defer { busy = false }
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
        var sent = 0
        while let job = try profile.nextRemovedBinderCleanup() {
            try Task.checkCancellation()
            if job.next > job.reserved { try profile.finishRemovedBinderCleanup(job); continue }
            guard sent < limit else { break }
            let status = try await transport.deleteObject(name: "views/\(job.binderID)/\(job.next)")
            sent += 1
            try refusal(status)
            guard status == 204 || status == 404 else { throw CompanionOwnerConnectionError.relayRejected(status) }
            try profile.advanceRemovedBinderCleanup(job)
        }
        return sent
    }
}

extension CompanionProfile {
    /// A removed binder is cleaned only behind a published index that does not name it (§9.7).
    func nextRemovedBinderCleanup() throws -> RemovedBinderCleanup? {
        try store.read { t in
            let rows = try t.rows("SELECT b.binder, b.key_epoch, b.highest_reserved, c.next FROM phone_binders b " +
                "LEFT JOIN binder_cleanup c ON c.binder = b.binder WHERE b.state = 'removed' AND COALESCE(c.done, 0) = 0 " +
                "AND NOT EXISTS (SELECT 1 FROM index_published_views v WHERE v.binder = b.binder) " +
                "AND NOT EXISTS (SELECT 1 FROM index_upload u JOIN index_upload_views w ON w.binder = b.binder WHERE u.state = 'uploading') " +
                "ORDER BY b.binder LIMIT 1")
            guard let r = rows.first else { return nil }
            guard r.count == 4, let id = r[0].text, CompanionWire.isID(id), let e = r[1].integer, e >= 1,
                  let reserved = r[2].integer, reserved >= 0, reserved <= JSONNumber.maxSafeInteger else { throw CompanionPublicationError.invalid }
            let next = r[3].integer ?? 1
            guard next >= 1, next <= reserved + 1 else { throw CompanionPublicationError.invalid }
            return RemovedBinderCleanup(binderID: id, keyEpoch: e, next: next, reserved: reserved)
        }
    }
    func advanceRemovedBinderCleanup(_ job: RemovedBinderCleanup) throws {
        try store.write { t in
            _ = try t.execute("INSERT INTO binder_cleanup (binder, next, done) VALUES (?, ?, 0) " +
                "ON CONFLICT(binder) DO UPDATE SET next = excluded.next WHERE binder_cleanup.next = ?",
                .text(job.binderID), .integer(job.next + 1), .integer(job.next))
        }
    }
    /// The key goes before the mark: a failed removal leaves the cleanup scheduled; removal is idempotent.
    func finishRemovedBinderCleanup(_ job: RemovedBinderCleanup) throws {
        try secrets.remove(account: binderKeyAccount(job.binderID, epoch: job.keyEpoch))
        try store.write { t in
            _ = try t.execute("INSERT INTO binder_cleanup (binder, next, done) VALUES (?, ?, 1) " +
                "ON CONFLICT(binder) DO UPDATE SET done = 1", .text(job.binderID), .integer(job.reserved + 1))
        }
    }
}

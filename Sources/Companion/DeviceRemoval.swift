import Foundation
import SpravaKit

public enum CompanionDeviceRemovalError: Error, Sendable, Equatable { case invalid, unavailable, decisionPending }
public struct CompanionDeviceRemovalReceipt: Sendable, Equatable {
    public let deviceID: String
    public let keyCleanupPending: Bool
    public let relayDeletionPending: Bool
    public let rotationPending: Bool
}
public struct CompanionDeviceRemovalPage: Sendable {
    public let removals: [CompanionDeviceRemovalReceipt]
    public let next: String?
}

/// companion-v0 §4.4 step1: the runtime shares this decision lock with drain, outcome publication and pairing.
/// This journal does not perform rotation or relay deletion; a Remove command waits for those interfaces.
public struct CompanionDeviceRemoval: Sendable {
    private let profile: CompanionProfile
    private let locks: CompanionDeviceDecisionLocks
    public init(profile: CompanionProfile, locks: CompanionDeviceDecisionLocks) { self.profile = profile; self.locks = locks }
    /// The caller first finishes any recorded decision. A remaining intent refuses removal without changing it.
    /// SQLite's write transaction is the key lock; no network or credential deletion happens in this commit.
    public func record(deviceID: String) async throws -> CompanionDeviceRemovalReceipt {
        try await locks.withLock(deviceID: deviceID) { try profile.recordDeviceRemoval(deviceID) }
    }
}

extension CompanionProfile {
    public func rotationPending() throws -> Bool { try store.read { try rotationPending($0) } }
    func rotationPending(_ t: Transaction) throws -> Bool {
        let rows = try t.rows("SELECT pending FROM rotation_state WHERE slot = 1")
        if rows.isEmpty { return false }
        guard rows.count == 1, rows[0].count == 1, let flag = rows[0][0].integer, (0...1).contains(flag) else {
            throw CompanionDeviceRemovalError.invalid
        }
        return flag == 1
    }
    public func deviceRemoval(deviceID: String) throws -> CompanionDeviceRemovalReceipt? {
        guard CompanionWire.isID(deviceID) else { throw CompanionDeviceRemovalError.invalid }
        return try store.read { try removalReceipt(deviceID, $0) }
    }
    /// Keyless bounded cleanup work. Completed receipts remain stored so a duplicate removal is always a no-op.
    public func pendingDeviceRemovals(limit: Int = 20, after: String? = nil) throws -> CompanionDeviceRemovalPage {
        guard (1...20).contains(limit), after.map(CompanionWire.isID) ?? true else { throw CompanionDeviceRemovalError.invalid }
        return try store.read { t in
            let rows = try t.rows("SELECT device FROM device_removals WHERE (key_cleanup = 1 OR relay_delete = 1) " +
                "AND device > ? ORDER BY device LIMIT ?", .text(after ?? ""), .integer(Int64(limit + 1)))
            let removals = try rows.prefix(limit).map { row -> CompanionDeviceRemovalReceipt in
                guard let id = row.first?.text, let receipt = try removalReceipt(id, t) else { throw CompanionDeviceRemovalError.invalid }
                return receipt
            }
            return CompanionDeviceRemovalPage(removals: removals, next: rows.count > limit ? removals.last?.deviceID : nil)
        }
    }
    func recordDeviceRemoval(_ id: String, beforeCommit: () throws -> Void = {}) throws -> CompanionDeviceRemovalReceipt {
        guard CompanionWire.isID(id) else { throw CompanionDeviceRemovalError.invalid }
        return try store.write { t in
            guard try epoch(t) != nil else { throw CompanionDeviceRemovalError.unavailable }
            if let receipt = try removalReceipt(id, t) { return receipt }
            guard try record(id, t)?.state == .active else { throw CompanionDeviceRemovalError.invalid }
            guard try t.rows("SELECT 1 FROM request_decisions WHERE device = ? LIMIT 1", .text(id)).isEmpty else {
                throw CompanionDeviceRemovalError.decisionPending
            }
            try t.execute("UPDATE devices SET state = 'revoked' WHERE device = ?", .text(id))
            try t.execute("INSERT INTO device_removals VALUES (?, 1, 1)", .text(id))
            try t.execute("INSERT INTO rotation_state VALUES (1, 1) ON CONFLICT(slot) DO UPDATE SET pending = 1")
            try t.execute("UPDATE decision_state SET outcomes_built = outcomes_generation WHERE device = ?", .text(id))
            // Keep the reserved revision floor and committed tombstones; only unfinished ciphertext is retired.
            try t.execute("DELETE FROM outcomes_upload WHERE device = ? AND state != 'published'", .text(id))
            try t.execute("DELETE FROM publication_attempts WHERE scope = ?", .text("outcomes/" + id))
            try beforeCommit()
            guard let receipt = try removalReceipt(id, t) else { throw CompanionDeviceRemovalError.invalid }; return receipt
        }
    }
    /// Only a durably revoked device can lose its device and temporary pairing secrets.
    /// A failed deletion or commit leaves its cleanup receipt retryable, including after partial secret deletion.
    /// No account/binder/owner key is removed. Remote deletion and rotation remain independent pending work.
    public func finishRemovedDeviceKeyCleanup(deviceID: String) throws -> CompanionDeviceRemovalReceipt {
        guard CompanionWire.isID(deviceID) else { throw CompanionDeviceRemovalError.invalid }
        return try store.write { t in
            guard let receipt = try removalReceipt(deviceID, t) else { throw CompanionDeviceRemovalError.invalid }
            if receipt.keyCleanupPending {
                try secrets.remove(account: deviceAccount(deviceID))
                try secrets.remove(account: pairingAccount(deviceID))
                try secrets.remove(account: createdAccount(deviceID))
                try t.execute("UPDATE devices SET key_ready = 0 WHERE device = ?", .text(deviceID))
                try t.execute("UPDATE pairings SET ephemeral_cleanup = 0 WHERE device = ?", .text(deviceID))
                try t.execute("UPDATE device_removals SET key_cleanup = 0 WHERE device = ?", .text(deviceID))
            }
            guard let result = try removalReceipt(deviceID, t) else { throw CompanionDeviceRemovalError.invalid }; return result
        }
    }
    private func removalReceipt(_ id: String, _ t: Transaction) throws -> CompanionDeviceRemovalReceipt? {
        let rows = try t.rows("SELECT key_cleanup, relay_delete FROM device_removals WHERE device = ?", .text(id))
        if rows.isEmpty { return nil }
        guard CompanionWire.isID(id), try record(id, t)?.state == .revoked, rows.count == 1, rows[0].count == 2,
              let key = rows[0][0].integer, (0...1).contains(key), let relay = rows[0][1].integer, (0...1).contains(relay) else {
            throw CompanionDeviceRemovalError.invalid
        }
        return CompanionDeviceRemovalReceipt(deviceID: id, keyCleanupPending: key == 1,
                                              relayDeletionPending: relay == 1, rotationPending: try rotationPending(t))
    }
}

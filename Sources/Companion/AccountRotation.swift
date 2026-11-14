import CryptoKit
import Foundation
import SpravaKit

public struct CompanionRotationKeys: Sendable, Equatable {
    public let epoch: Int64
    public let deviceID: String
    public let bytes: Data
    public var name: String { "devices/\(deviceID)/keys/\(epoch)" }
}
public enum CompanionRotationError: Error, Sendable, Equatable { case invalid }

/// companion-v0 §4.4 steps 2, 3 and 5, after a device removal recorded step 1. Rotation is for removal only;
/// hiding a binder retires its id and key instead (§8.4, `hideBinder`).
extension CompanionProfile {
    /// Steps 2 and 3 in one SQLite write, which is the key lock; no network call. Only when a rotation is pending.
    /// New account and binder keys are staged in the vault first, so a failed commit reuses them on retry. Every
    /// active device's keys object is sealed with its `Kd`, signed and recorded, and becomes the epoch's recipient
    /// list. The epoch moves in the same write, so nothing later is sealed for a removed device. Unsent keys
    /// objects of an earlier rotation are dropped: a device needs only the newest (supersession).
    @discardableResult
    public func beginRotation() throws -> Int64? { try beginRotation(beforeCommit: {}) }
    func beginRotation(beforeCommit: () throws -> Void) throws -> Int64? {
        try store.write { t in
            guard try rotationPending(t), let e = try epoch(t) else { return nil }
            guard e < JSONNumber.maxSafeInteger else { throw CompanionRotationError.invalid }
            guard let owner = try CompanionOwnerVault(backend: secrets).load(relay) else { throw CompanionCredentialError.unavailable }
            let next = e + 1
            try stageKey(keyAccount(next))
            let binders = try t.rows("SELECT binder FROM phone_binders WHERE state IN ('preparing', 'shown') ORDER BY binder").map { row in
                guard row.count == 1, let id = row[0].text, CompanionWire.isID(id) else { throw CompanionRotationError.invalid }
                return id
            }
            for id in binders { try stageKey(binderKeyAccount(id, epoch: next)) }
            let k = try key(next).withUnsafeBytes { Data($0) }
            let devices = try t.rows("SELECT device FROM devices WHERE state = 'active' ORDER BY device").map { row in
                guard row.count == 1, let id = row[0].text, CompanionWire.isID(id) else { throw CompanionRotationError.invalid }
                return id
            }
            try t.execute("DELETE FROM rotation_keys WHERE epoch < ? AND state = 'pending'", .integer(next))
            let epochValue = JSONValue.number(JSONNumber(text: String(next)))
            for d in devices {
                guard let kd = try secrets.read(account: deviceAccount(d)) else { throw CompanionCredentialError.unavailable }
                guard kd.count == 32 else { throw CompanionCredentialError.invalid }
                let bytes = try CompanionSealedObject.seal(name: "devices/\(d)/keys/\(next)", epoch: next, key: SymmetricKey(data: kd),
                    plaintext: pairingJSON([("account_key", .string(CompanionWire.base64(k))), ("epoch", epochValue), ("device_id", .string(d))]),
                    signer: owner.signingKey)
                try t.execute("INSERT INTO rotation_keys VALUES (?, ?, 'pending', ?)", .integer(next), .text(d), .blob(bytes))
                try t.execute("INSERT INTO recipients VALUES (?, ?)", .integer(next), .text(d))
            }
            try t.execute("INSERT OR IGNORE INTO discard_epochs VALUES (?)", .integer(e))
            try t.execute("UPDATE profile SET epoch = ? WHERE slot = 1", .integer(next))
            try t.execute("UPDATE phone_binders SET key_epoch = ? WHERE state IN ('preparing', 'shown')", .integer(next))
            try t.execute("UPDATE rotation_state SET pending = 0 WHERE slot = 1")
            try beforeCommit()
            return next
        }
    }
    private func stageKey(_ account: String) throws {
        if try secrets.read(account: account) == nil {
            _ = try secrets.insert(account: account, bytes: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) })
        }
        guard try secrets.read(account: account)?.count == 32 else { throw CompanionCredentialError.unavailable }
    }

    /// The person's retry after a relay fault: a new rotation replaces keys objects the relay refused.
    public func requestRotation() throws {
        try store.write { t in
            guard try epoch(t) != nil else { throw CompanionRotationError.invalid }
            try t.execute("INSERT INTO rotation_state VALUES (1, 1) ON CONFLICT(slot) DO UPDATE SET pending = 1")
        }
    }

    /// The next keys object of the current epoch still to upload, keyless.
    public func pendingRotationKeys() throws -> CompanionRotationKeys? {
        try store.read { t in
            guard let e = try epoch(t) else { return nil }
            guard let row = try t.rows("SELECT device, bytes FROM rotation_keys WHERE epoch = ? AND state = 'pending' ORDER BY device LIMIT 1",
                                       .integer(e)).first else { return nil }
            guard row.count == 2, let d = row[0].text, CompanionWire.isID(d), let bytes = row[1].blob, !bytes.isEmpty, bytes.count <= 4096 else {
                throw CompanionRotationError.invalid
            }
            return CompanionRotationKeys(epoch: e, deviceID: d, bytes: bytes)
        }
    }
    /// Whether publication at the current epoch must wait: a rotation is pending, or one of its keys objects is
    /// not yet on the relay, so a remaining phone could meet an index it cannot open. Keyless; for the publishing job.
    public func rotationBlocksPublication() throws -> Bool { try store.read { try rotationBlocks($0) } }
    func rotationBlocks(_ t: Transaction) throws -> Bool {
        guard let e = try epoch(t) else { return false }
        if try rotationPending(t) { return true }
        return try !t.rows("SELECT 1 FROM rotation_keys WHERE epoch = ? AND state != 'uploaded' LIMIT 1", .integer(e)).isEmpty
    }
    /// A keys object the relay refused (409, or 410 for a device still active): a relay fault the person must see.
    /// Nothing retries it by itself; `requestRotation` is the person's retry.
    public func rotationFault() throws -> Bool {
        try store.read { t in
            guard let e = try epoch(t) else { return false }
            return try !t.rows("SELECT 1 FROM rotation_keys WHERE epoch = ? AND state = 'refused' LIMIT 1", .integer(e)).isEmpty
        }
    }
    func recordRotationKeys(_ keys: CompanionRotationKeys, uploaded: Bool) throws {
        try store.write { t in
            guard let row = try t.rows("SELECT state, bytes FROM rotation_keys WHERE epoch = ? AND device = ?",
                                       .integer(keys.epoch), .text(keys.deviceID)).first else { return } // superseded meanwhile
            guard row.count == 2, row[1].blob == keys.bytes else { throw CompanionRotationError.invalid }
            guard row[0].text == "pending" else { return }
            try t.execute("UPDATE rotation_keys SET state = ? WHERE epoch = ? AND device = ?",
                          .text(uploaded ? "uploaded" : "refused"), .integer(keys.epoch), .text(keys.deviceID))
        }
    }
    /// Step 4's work list, keyless: shown binders with no view recorded at their key epoch, which the publishing
    /// job snapshots again after a rotation.
    public func bindersNeedingEpochView() throws -> [String] {
        try store.read { t in
            try t.rows("SELECT b.binder FROM phone_binders b WHERE b.state = 'shown' AND NOT EXISTS (SELECT 1 FROM phone_views v " +
                       "WHERE v.binder = b.binder AND v.epoch = b.key_epoch) ORDER BY b.binder LIMIT 100").map { row in
                guard row.count == 1, let id = row[0].text, CompanionWire.isID(id) else { throw CompanionRotationError.invalid }
                return id
            }
        }
    }
    /// The first removed device whose relay deletion is not yet confirmed, keyless.
    public func relayDeletionPending() throws -> String? {
        try store.read { t in
            guard let row = try t.rows("SELECT device FROM device_removals WHERE relay_delete = 1 ORDER BY device LIMIT 1").first else { return nil }
            guard row.count == 1, let id = row[0].text, CompanionWire.isID(id) else { throw CompanionRotationError.invalid }
            return id
        }
    }
    func recordRelayDeletion(deviceID: String) throws {
        try store.write { t in
            guard try record(deviceID, t)?.state == .revoked else { throw CompanionRotationError.invalid }
            try t.execute("UPDATE device_removals SET relay_delete = 0 WHERE device = ?", .text(deviceID))
            try t.execute("DELETE FROM publication_attempts WHERE scope = ?", .text("removal/" + deviceID))
        }
    }
    /// Removed phones the relay has not confirmed deleting, with their private labels, for Settings › Phone only.
    public func removalsAwaitingRelay() throws -> [(deviceID: String, label: String)] {
        try store.read { t in
            try t.rows("SELECT r.device, COALESCE(p.label, '') FROM device_removals r LEFT JOIN pairings p ON p.device = r.device " +
                       "WHERE r.relay_delete = 1 ORDER BY r.device LIMIT 20").map { row in
                guard row.count == 2, let id = row[0].text, CompanionWire.isID(id), let label = row[1].text else {
                    throw CompanionRotationError.invalid
                }
                return (id, label)
            }
        }
    }
    func deviceRevoked(_ id: String) throws -> Bool { try store.read { try record(id, $0)?.state == .revoked } }

    /// Step 5: once an index at the current epoch is recorded as published, discard the account key and the
    /// rotated binders' keys of every earlier epoch awaiting discard. Before that, nothing is removed.
    @discardableResult
    public func discardOldEpochKeys() throws -> Bool {
        try store.write { t in
            guard let e = try epoch(t),
                  let head = try t.rows("SELECT epoch, state FROM index_upload WHERE slot = 1").first,
                  head.count == 2, head[0].integer == e, head[1].text == "published" else { return false }
            let old = try t.rows("SELECT epoch FROM discard_epochs WHERE epoch < ? ORDER BY epoch", .integer(e)).compactMap { $0.first?.integer }
            if old.isEmpty { return false }
            let binders = try t.rows("SELECT binder FROM phone_binders WHERE key_epoch = ?", .integer(e)).compactMap { $0.first?.text }
            for epoch in old {
                try secrets.remove(account: keyAccount(epoch))
                for id in binders { try secrets.remove(account: binderKeyAccount(id, epoch: epoch)) }
                try t.execute("DELETE FROM discard_epochs WHERE epoch = ?", .integer(epoch))
            }
            return true
        }
    }
}

protocol OwnerRotationTransport: Sendable {
    func putObject(name: String, bytes: Data) async throws -> Int
    func deleteDevice(deviceID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data>
}
extension CompanionOwnerRelay: OwnerRotationTransport {}

public enum CompanionRotationProgress: Sendable, Equatable {
    case idle
    case rotated(epoch: Int64)
    case deleted(deviceID: String)
    case waiting(retryAt: String)
    case uploaded(deviceID: String)
    case refused(deviceID: String)
    case discarded
}

/// companion-v0 §4.4: one bounded step per call. Begins a pending rotation (local); else deletes one removed device
/// on the relay (first, so its token stops working); else uploads one recorded keys object with its exact bytes;
/// else discards old keys behind a published index at the new epoch. A refused upload is recorded as a relay fault
/// and never re-rotated automatically: an untrusted relay cannot make the Mac loop.
public actor CompanionOwnerRotation {
    private let profile: CompanionProfile
    private let transport: @Sendable () throws -> any OwnerRotationTransport
    private let now: @Sendable () -> String
    private var busy = false

    /// Construction is keyless; the owner token is loaded only for an admitted upload.
    public init(profile: CompanionProfile) {
        self.profile = profile
        transport = {
            guard let owner = try CompanionOwnerVault(backend: profile.secrets).load(profile.relay) else {
                throw CompanionCredentialError.unavailable
            }
            return try CompanionOwnerRelay(relay: profile.relay, token: owner.ownerToken)
        }
        now = { Date().ISO8601Format() }
    }
    init(profile: CompanionProfile, transport: any OwnerRotationTransport, now: @escaping @Sendable () -> String) {
        self.profile = profile; self.transport = { transport }; self.now = now
    }

    public func step() async throws -> CompanionRotationProgress {
        guard !busy else { throw CompanionPairingFlowError.busy }
        busy = true; defer { busy = false }
        try Task.checkCancellation()
        if let epoch = try profile.beginRotation() { return .rotated(epoch: epoch) }
        let deletion = try profile.relayDeletionPending()
        let keys = try profile.pendingRotationKeys()
        guard deletion != nil || keys != nil else { return try profile.discardOldEpochKeys() ? .discarded : .idle }
        let state = try profile.ownerClaimState()
        guard state == .claimed else { throw CompanionPairingFlowError.ownerUnavailable(state) }
        // §4.4 step 1: repeated until 204, paced on its own so a relay refusing it never holds up the new keys.
        if let deletion, try profile.reservePublicationAttempt(scope: "removal/" + deletion, name: "devices/" + deletion, now: now()).send {
            let reply = try await transport().deleteDevice(deviceID: deletion, downloadLimit: 4096)
            switch reply.status {
            case 204: try profile.recordRelayDeletion(deviceID: deletion); return .deleted(deviceID: deletion)
            case 401:
                try profile.recordClaimState(.checkingRefusal)
                throw CompanionOwnerConnectionError.relayRejected(401)
            default: throw CompanionOwnerConnectionError.relayRejected(reply.status)
            }
        }
        guard let keys else { return .idle }
        let attempt = try profile.reservePublicationAttempt(scope: "rotation/" + keys.deviceID, name: keys.name, now: now())
        if !attempt.send { return .waiting(retryAt: attempt.next) }
        let status = try await transport().putObject(name: keys.name, bytes: keys.bytes)
        switch status {
        case 204:
            try profile.recordRotationKeys(keys, uploaded: true); return .uploaded(deviceID: keys.deviceID)
        case 410 where try profile.deviceRevoked(keys.deviceID):
            // Deleted with its removed device: nothing to deliver (§9.7).
            try profile.recordRotationKeys(keys, uploaded: true); return .uploaded(deviceID: keys.deviceID)
        case 409, 410:
            try profile.recordRotationKeys(keys, uploaded: false); return .refused(deviceID: keys.deviceID)
        case 401:
            try profile.recordClaimState(.checkingRefusal)
            throw CompanionOwnerConnectionError.relayRejected(401)
        default:
            throw CompanionOwnerConnectionError.relayRejected(status)
        }
    }
}

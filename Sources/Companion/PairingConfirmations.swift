import CryptoKit
import Foundation
import SpravaKit

public struct CompanionPairingDelivery: Sendable {
    public let deviceID: String
    public let pairingID: String
    public let expiresAt: String
    public let epoch: Int64
    public let wrappedKey: Data
    public let deviceKeys: Data
    public let acknowledged: Bool
    public let ephemeralCleanupPending: Bool
    public var keysName: String { "devices/\(deviceID)/keys/\(epoch)" }
}
extension CompanionProfile {
    /// companion-v0 §5.2 step 4: record Kd, both exact envelopes and activation before any upload.
    public func confirmPairing(_ approval: CompanionPairingApproval, credentials: CompanionOwnerCredentials,
                               now: String) throws -> CompanionPairingDelivery {
        try confirmPairing(approval, credentials: credentials, now: now, beforeCommit: {})
    }
    func confirmPairing(_ approval: CompanionPairingApproval, credentials: CompanionOwnerCredentials,
                        now: String, beforeCommit: () throws -> Void) throws -> CompanionPairingDelivery {
        guard CompanionWire.isID(approval.deviceID), CompanionOwnerRelay.time(now),
              credentials.relay.origin == relay.origin, credentials.relay.instance == relay.instance else {
            throw CompanionOwnerPairingError.invalid
        }
        guard let owner = try CompanionOwnerVault(backend: secrets).load(relay),
              owner.ownerToken == credentials.ownerToken,
              owner.signingKey.publicKey.rawRepresentation == credentials.signingKey.publicKey.rawRepresentation else {
            throw CompanionCredentialError.unavailable
        }
        do {
            return try store.write { t in
                let d = approval.deviceID
                guard let r = try record(d, t), r.state == .pairing || r.state == .active,
                      let row = try t.rows("SELECT pairing, expires, public_b, approval FROM pairings WHERE device = ?", .text(d)).first,
                      row.count == 4, row[0].text == approval.pairingID, row[3].text == approval.digest else { throw CompanionOwnerPairingError.invalid }
                if r.state == .active { return try delivery(d, t) }
                guard let expires = row[1].text, CompanionOwnerRelay.time(expires), let b = row[2].blob else { throw CompanionCredentialError.invalid }
                if now >= expires { throw CompanionOwnerPairingError.expired }
                guard let e = try epoch(t), let floor = try t.rows("SELECT index_reserved, index_published FROM profile").first,
                      floor.count == 2, let reserved = floor[0].integer, let published = floor[1].integer,
                      published >= 0, published <= JSONNumber.maxSafeInteger, reserved == published else {
                    // An unfinished index must be finished or superseded before a pairing can take its rollback floor.
                    throw CompanionCredentialError.unavailable
                }
                let keys = try CompanionPairing.derive(pairingID: approval.pairingID, deviceID: d, devicePublicKey: b, owner: ephemeralKey(d))
                let kd = keys.device.withUnsafeBytes { Data($0) }
                if try secrets.read(account: deviceAccount(d)) == nil { _ = try secrets.insert(account: deviceAccount(d), bytes: kd) }
                guard try secrets.read(account: deviceAccount(d)) == kd else { throw CompanionCredentialError.invalid }
                let k = try key(e).withUnsafeBytes { Data($0) }
                let epochValue = JSONValue.number(JSONNumber(text: String(e)))
                let wrapped = try CompanionSealedObject.seal(name: "pairings/\(approval.pairingID)/key", epoch: e, key: keys.wrap,
                    plaintext: pairingJSON([("account_key", .string(CompanionWire.base64(k))), ("epoch", epochValue), ("device_id", .string(d)),
                        ("min_index_revision", .number(JSONNumber(text: String(published)))),
                        ("owner_signing_key", .string(CompanionWire.base64(credentials.signingKey.publicKey.rawRepresentation)))]))
                let signed = try CompanionSealedObject.seal(name: "devices/\(d)/keys/\(e)", epoch: e, key: keys.device,
                    plaintext: pairingJSON([("account_key", .string(CompanionWire.base64(k))), ("epoch", epochValue), ("device_id", .string(d))]),
                    signer: credentials.signingKey)
                try t.execute("UPDATE pairings SET wrapped_key = ?, device_keys = ?, key_epoch = ?, paired_at = ? WHERE device = ?",
                              .blob(wrapped), .blob(signed), .integer(e), .text(now), .text(d))
                try t.execute("UPDATE devices SET state = 'active' WHERE device = ?", .text(d))
                try t.execute("INSERT INTO recipients VALUES (?, ?)", .integer(e), .text(d))
                try beforeCommit()
                return try delivery(d, t)
            }
        } catch CompanionOwnerPairingError.expired {
            try abandonPairing(deviceID: approval.deviceID)
            throw CompanionOwnerPairingError.expired
        }
    }
    public func pairingDelivery(deviceID: String) throws -> CompanionPairingDelivery? {
        guard CompanionWire.isID(deviceID) else { throw CompanionOwnerPairingError.invalid }
        return try store.read { t in
            guard let r = try record(deviceID, t), r.state == .active else { return nil }
            return try delivery(deviceID, t)
        }
    }
    private func delivery(_ id: String, _ t: Transaction) throws -> CompanionPairingDelivery {
        let rows = try t.rows("SELECT pairing, expires, key_epoch, wrapped_key, device_keys, acknowledged, ephemeral_cleanup FROM pairings WHERE device = ?", .text(id))
        guard let r = rows.first, r.count == 7, let p = r[0].text, CompanionWire.isID(p),
              let expires = r[1].text, CompanionOwnerRelay.time(expires), let e = r[2].integer, e >= 1, e <= JSONNumber.maxSafeInteger,
              let wrapped = r[3].blob, wrapped.count <= 1024, let signed = r[4].blob, signed.count <= 4096,
              let ack = r[5].integer, (0...1).contains(ack), let cleanup = r[6].integer, (0...1).contains(cleanup) else {
            throw CompanionCredentialError.invalid
        }
        return CompanionPairingDelivery(deviceID: id, pairingID: p, expiresAt: expires, epoch: e, wrappedKey: wrapped,
                                        deviceKeys: signed, acknowledged: ack == 1, ephemeralCleanupPending: cleanup == 1)
    }
    public func acknowledgePairing(deviceID: String) throws {
        guard CompanionWire.isID(deviceID) else { throw CompanionOwnerPairingError.invalid }
        try store.write { t in
            guard let r = try record(deviceID, t), r.state == .active else { throw CompanionCredentialError.invalid }
            try t.execute("UPDATE pairings SET ephemeral_cleanup = CASE WHEN acknowledged = 0 THEN 1 ELSE ephemeral_cleanup END, acknowledged = 1 WHERE device = ?", .text(deviceID))
        }
        try finishPairingSecrets(deviceID: deviceID)
    }
    /// Also used at expiry when the phone did not acknowledge; it keeps the active Kd and not-confirmed status.
    public func finishPairingSecrets(deviceID: String) throws {
        guard CompanionWire.isID(deviceID) else { throw CompanionOwnerPairingError.invalid }
        try store.write { t in
            guard let r = try record(deviceID, t), r.state == .active else { throw CompanionCredentialError.invalid }
            if r.keyReady { try t.execute("UPDATE pairings SET ephemeral_cleanup = 1 WHERE device = ?", .text(deviceID)) }
        }
        try store.write { t in
            guard let r = try record(deviceID, t), r.state == .active,
                  let pending = try t.rows("SELECT ephemeral_cleanup FROM pairings WHERE device = ?", .text(deviceID)).first?.first?.integer else {
                throw CompanionCredentialError.invalid
            }
            if pending == 0 { return }
            try secrets.remove(account: pairingAccount(deviceID)); try secrets.remove(account: createdAccount(deviceID))
            try t.execute("UPDATE pairings SET ephemeral_cleanup = 0 WHERE device = ?", .text(deviceID))
            try t.execute("UPDATE devices SET key_ready = 0 WHERE device = ?", .text(deviceID))
        }
    }
}

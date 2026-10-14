import CryptoKit
import Foundation
import SpravaKit

public struct CompanionPairingReservation: Sendable {
    public let deviceID: String
    public let ownerPublicKey: Data
}
public struct CompanionDeviceRecord: Sendable {
    public enum State: String, Sendable { case pairing, active, revoked, abandoned }
    public let deviceID: String
    public let state: State
    public let keyReady: Bool
    public let creationAttempted: Bool
    public let cleanupPending: Bool
}

extension CompanionProfile {
    /// companion-v0 §5.2: reserve D durably before making its ephemeral key, then before making any relay call.
    public func reservePairing() throws -> CompanionPairingReservation {
        let id = CompanionWire.base64(SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) })
        try store.write { t in
            guard try epoch(t) != nil else { throw CompanionCredentialError.invalid }
            try t.execute("INSERT INTO devices VALUES (?, 'pairing', 0, 0, 0)", .text(id))
        }
        return try preparePairingReservation(deviceID: id)
    }

    /// Recover an interrupted key write only before a create attempt. Never replace a ready or attempted key.
    public func preparePairingReservation(deviceID: String) throws -> CompanionPairingReservation {
        try checkID(deviceID)
        return try store.write { t in
            guard let r = try record(deviceID, t), r.state == .pairing, !r.cleanupPending else { throw CompanionCredentialError.invalid }
            if !r.keyReady {
                guard !r.creationAttempted else { throw CompanionCredentialError.invalid }
                if try secrets.read(account: pairingAccount(deviceID)) == nil {
                    _ = try secrets.insert(account: pairingAccount(deviceID), bytes: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
                }
            }
            let key = try ephemeralKey(deviceID)
            try t.execute("UPDATE devices SET key_ready = 1 WHERE device = ?", .text(deviceID))
            return CompanionPairingReservation(deviceID: deviceID, ownerPublicKey: key.publicKey.rawRepresentation)
        }
    }

    /// Commit before POST. Once attempted, the caller must record a known result or abandon D, never POST D again.
    public func beginPairingCreation(deviceID: String) throws -> CompanionPairingReservation {
        try checkID(deviceID)
        return try store.write { t in
            guard let r = try record(deviceID, t), r.state == .pairing, r.keyReady,
                  !r.creationAttempted, !r.cleanupPending else { throw CompanionCredentialError.invalid }
            let key = try ephemeralKey(deviceID)
            try t.execute("UPDATE devices SET creation_attempted = 1 WHERE device = ?", .text(deviceID))
            return CompanionPairingReservation(deviceID: deviceID, ownerPublicKey: key.publicKey.rawRepresentation)
        }
    }

    /// Mark inactive first; a failed Keychain deletion is retried from the retained id, never treated as done.
    public func abandonPairing(deviceID: String) throws {
        try checkID(deviceID)
        try store.write { t in
            guard let r = try record(deviceID, t), r.state == .pairing || r.state == .abandoned else { throw CompanionCredentialError.invalid }
            if r.state == .pairing {
                try t.execute("UPDATE devices SET state = 'abandoned', cleanup_pending = 1 WHERE device = ?", .text(deviceID))
            }
        }
        try cleanAbandonedPairing(deviceID: deviceID)
    }

    public func cleanAbandonedPairing(deviceID: String) throws {
        try checkID(deviceID)
        try store.write { t in
            guard let r = try record(deviceID, t), r.state == .abandoned else { throw CompanionCredentialError.invalid }
            if !r.cleanupPending { return }
            try secrets.remove(account: pairingAccount(deviceID))
            try t.execute("UPDATE devices SET cleanup_pending = 0, key_ready = 0 WHERE device = ?", .text(deviceID))
        }
    }

    /// Bounded, keyless metadata for recovery and the eventual settings facade; ids remain after abandonment.
    public func deviceRecords(limit: Int = 20, after: String? = nil) throws -> [CompanionDeviceRecord] {
        guard (1...100).contains(limit) else { throw CompanionCredentialError.invalid }
        if let after { try checkID(after) }
        return try store.read { t in
            guard try epoch(t) != nil else { return [] }
            return try t.rows("SELECT device, state, key_ready, creation_attempted, cleanup_pending FROM devices " +
                              "WHERE device > ? ORDER BY device LIMIT ?", .text(after ?? ""), .integer(Int64(limit))).map(decodeRecord)
        }
    }
    func record(_ id: String, _ t: Transaction) throws -> CompanionDeviceRecord? {
        guard try epoch(t) != nil else { throw CompanionCredentialError.invalid }
        let rows = try t.rows("SELECT device, state, key_ready, creation_attempted, cleanup_pending FROM devices WHERE device = ?", .text(id))
        return try rows.first.map(decodeRecord)
    }
    private func decodeRecord(_ row: [StateValue]) throws -> CompanionDeviceRecord {
        guard row.count == 5, let id = row[0].text, CompanionWire.isID(id), let state = row[1].text,
              let state = CompanionDeviceRecord.State(rawValue: state),
              let ready = row[2].integer, (0...1).contains(ready), let attempted = row[3].integer, (0...1).contains(attempted),
              let cleanup = row[4].integer, (0...1).contains(cleanup) else { throw CompanionCredentialError.invalid }
        return CompanionDeviceRecord(deviceID: id, state: state, keyReady: ready == 1, creationAttempted: attempted == 1, cleanupPending: cleanup == 1)
    }
    func pairingAccount(_ id: String) -> String { relay.account + ":pairing-a-v0:" + id }
    func ephemeralKey(_ id: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let bytes = try secrets.read(account: pairingAccount(id)) else { throw CompanionCredentialError.unavailable }
        guard bytes.count == 32 else { throw CompanionCredentialError.invalid }
        do { return try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) }
        catch { throw CompanionCredentialError.invalid }
    }
    private func checkID(_ id: String) throws {
        guard CompanionWire.isID(id) else { throw CompanionCredentialError.invalid }
    }
}

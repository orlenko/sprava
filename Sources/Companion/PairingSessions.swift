import CryptoKit
import Foundation
import SpravaKit

public enum CompanionOwnerPairingError: Error, Equatable { case invalid, expired }
public struct CompanionPairingApproval: Sendable {
    public let deviceID: String
    public let pairingID: String
    public let label: String
    public let confirmation: String
    let digest: String
}

extension CompanionProfile {
    /// Capture a known create result once; its protected record survives a failed SQLite reference commit.
    public func captureCreatedPairing(deviceID: String, created: CompanionCreatedPairing) throws {
        guard CompanionWire.isID(deviceID), CompanionWire.isID(created.id), CompanionWire.isID(created.secret),
              CompanionOwnerRelay.time(created.expiresAt) else { throw CompanionOwnerPairingError.invalid }
        try store.write { t in
            guard let r = try record(deviceID, t), r.state == .pairing, r.keyReady, r.creationAttempted else {
                throw CompanionOwnerPairingError.invalid
            }
            let bytes = pairingJSON([("id", .string(created.id)), ("secret", .string(created.secret)), ("expires", .string(created.expiresAt))])
            if try secrets.read(account: createdAccount(deviceID)) == nil { _ = try secrets.insert(account: createdAccount(deviceID), bytes: bytes) }
            guard try secrets.read(account: createdAccount(deviceID)) == bytes else { throw CompanionOwnerPairingError.invalid }
            try referenceCreated(deviceID, created, t)
        }
    }
    public func createdPairing(deviceID: String) throws -> CompanionCreatedPairing? {
        guard CompanionWire.isID(deviceID) else { throw CompanionOwnerPairingError.invalid }
        return try store.write { t in
            guard let r = try record(deviceID, t), r.state == .pairing else { return nil }
            guard let bytes = try secrets.read(account: createdAccount(deviceID)) else { return nil }
            let value = try CompanionWire.parse(bytes, limit: 4096)
            guard let id = value["id"]?.stringValue, CompanionWire.isID(id),
                  let secret = value["secret"]?.stringValue, CompanionWire.isID(secret),
                  let expires = value["expires"]?.stringValue, CompanionOwnerRelay.time(expires) else { throw CompanionOwnerPairingError.invalid }
            let created = CompanionCreatedPairing(id: id, secret: secret, expiresAt: expires)
            guard r.keyReady, r.creationAttempted else { throw CompanionOwnerPairingError.invalid }
            try referenceCreated(deviceID, created, t)
            return created
        }
    }
    private func referenceCreated(_ id: String, _ created: CompanionCreatedPairing, _ t: Transaction) throws {
        let existing = try t.rows("SELECT pairing, expires FROM pairings WHERE device = ?", .text(id))
        if let row = existing.first {
            guard row.count == 2, row[0].text == created.id, row[1].text == created.expiresAt else { throw CompanionOwnerPairingError.invalid }
        } else {
            try t.execute("INSERT INTO pairings (device, pairing, expires) VALUES (?, ?, ?)", .text(id), .text(created.id), .text(created.expiresAt))
        }
    }

    /// companion-v0 §5.2 step 3: pin B and hello before showing a code; later hello bytes never replace the first.
    public func observePairing(deviceID: String, response: CompanionRelayPairing) throws -> CompanionPairingApproval? {
        guard CompanionWire.isID(deviceID) else { throw CompanionOwnerPairingError.invalid }
        do {
            return try store.write { t in
                guard let r = try record(deviceID, t) else { throw CompanionCredentialError.invalid }
                if r.state == .active { return nil } // Active transcripts are already confirmed; never abandon them from relay fields.
                guard r.state == .pairing else { throw CompanionCredentialError.invalid }
                if response.state == .open { return nil }
                guard response.deviceID == deviceID, let b = response.publicKey, b.count == 32, let hello = response.hello else {
                    throw CompanionOwnerPairingError.invalid
                }
                let rows = try t.rows("SELECT pairing, public_b, hello FROM pairings WHERE device = ?", .text(deviceID))
                guard let row = rows.first, row.count == 3, let p = row[0].text, CompanionWire.isID(p) else { throw CompanionCredentialError.invalid }
                if let pinned = row[1].blob, pinned != b { throw CompanionOwnerPairingError.invalid }
                let firstHello = row[2].blob ?? hello
                let owner = try ephemeralKey(deviceID)
                let keys: CompanionPairingKeys
                let label: String
                do {
                    keys = try CompanionPairing.derive(pairingID: p, deviceID: deviceID, devicePublicKey: b, owner: owner)
                    let opened = try CompanionSealedObject.openPayload(name: "pairings/\(p)/hello", epoch: 0, key: keys.wrap, bytes: firstHello)
                    label = try helloLabel(opened)
                } catch { throw CompanionOwnerPairingError.invalid }
                let digest = CompanionWire.base64(Data(SHA256.hash(data: Data(p.utf8) + keys.ownerPublicKey + b +
                    (try CompanionWire.decode(deviceID)) + Data(SHA256.hash(data: firstHello)))))
                if row[1].blob == nil {
                    try t.execute("UPDATE pairings SET public_b = ?, hello = ?, label = ?, approval = ? WHERE device = ?",
                                  .blob(b), .blob(firstHello), .text(label), .text(digest), .text(deviceID))
                }
                return CompanionPairingApproval(deviceID: deviceID, pairingID: p, label: label, confirmation: keys.confirmation, digest: digest)
            }
        } catch CompanionOwnerPairingError.invalid {
            try abandonPairing(deviceID: deviceID)
            throw CompanionOwnerPairingError.invalid
        }
    }
    private func helloLabel(_ opened: CompanionOpenedObject) throws -> String {
        guard opened.plaintextLength == 512, let label = opened.value["label"]?.stringValue,
              (1...40).contains(label.unicodeScalars.count), JSONWriter.compact(.string(label)).utf8.count - 2 <= 160,
              label.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
              let pad = opened.value["pad"]?.stringValue, pad.utf8.allSatisfy({ $0 == 32 }) else { throw CompanionOwnerPairingError.invalid }
        return label
    }
    func pairingJSON(_ fields: [(key: String, value: JSONValue)]) -> Data { Data(JSONWriter.compact(.object(JSONObject(fields))).utf8) }
    func createdAccount(_ id: String) -> String { relay.account + ":pairing-created-v0:" + id }
    func deviceAccount(_ id: String) -> String { relay.account + ":device-key-v0:" + id }
}

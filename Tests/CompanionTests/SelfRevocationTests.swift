import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private let revocationDevice = CompanionWire.base64(Data(repeating: 101, count: 16))
private let revocationOther = CompanionWire.base64(Data(repeating: 102, count: 16))
private let revocationInstance = "0123456789abcdef0123456789abcdef"
private struct RevocationUnavailableSecrets: CompanionCredentialStorage {
    let bytes: Data?
    func read(account: String) throws -> Data? { bytes }
    func insert(account: String, bytes: Data) throws -> Bool { throw CompanionCredentialError.unavailable }
}
private final class RevocationSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
private struct RevocationFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-revocation-" + UUID().uuidString)
    let key = SymmetricKey(data: Data(repeating: 103, count: 32))
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func prepare() throws -> CompanionProfile {
        let p = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: revocationInstance), secrets: RevocationSecrets())
        _ = try p.prepareAccount()
        _ = try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(revocationDevice)) }
        _ = try p.secrets.insert(account: p.deviceAccount(revocationDevice), bytes: key.withUnsafeBytes { Data($0) })
        return p
    }
    func proof(device: String = revocationDevice, instance: String = revocationInstance, type: String = "revoke-self",
               key: SymmetricKey? = nil, name: String? = nil, extras: [(String, JSONValue)] = []) throws -> Data {
        let payload = JSONValue.obj([("type", .string(type)), ("device_id", .string(device)), ("instance", .string(instance))] + extras)
        return try CompanionSealedObject.seal(name: name ?? "devices/\(revocationDevice)/revocation", epoch: 0,
            key: key ?? self.key, plaintext: Data(JSONWriter.compact(payload).utf8))
    }
}

@Test func validSelfRevocationProofIsBoundToThisDeviceAndInstanceButDoesNotChangeAccess() throws {
    let f = RevocationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    for extras: [(String, JSONValue)] in [[], [("made_at", .str("not-a-clock")), ("pairing_generation", .null)]] {
        #expect(try p.verifySelfRevocation(deviceID: revocationDevice, bytes: f.proof(extras: extras)))
        #expect(try p.deviceRecords().first?.state == .active)
        #expect(try p.currentAccount()?.number == 1)
        #expect(try p.secrets.read(account: p.deviceAccount(revocationDevice)) == f.key.withUnsafeBytes { Data($0) })
    }
}

@Test func forgedMismatchedMalformedAndOversizedRevocationsCannotChangeDeviceAccess() throws {
    let f = RevocationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let invalid = [try f.proof(device: revocationOther), try f.proof(instance: String(repeating: "f", count: 32)),
        try f.proof(type: "done"), try f.proof(key: SymmetricKey(data: Data(repeating: 104, count: 32))),
        try f.proof(name: "devices/\(revocationOther)/revocation"), Data("{}".utf8), Data(repeating: 32, count: 1025)]
    for bytes in invalid { #expect(try !p.verifySelfRevocation(deviceID: revocationDevice, bytes: bytes)) }
    #expect(try !p.verifySelfRevocation(deviceID: "../credentials", bytes: f.proof()))
    #expect(try p.deviceRecords().first?.state == .active)
}

@Test func missingAndCorruptLocalRevocationKeysAreErrorsInsteadOfInvalidRelayProofs() throws {
    let f = RevocationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let original = try f.prepare()
    let proof = try f.proof()
    for bytes: Data? in [nil, Data(repeating: 105, count: 16)] {
        let p = try CompanionProfile(database: f.database, relay: original.relay, secrets: RevocationUnavailableSecrets(bytes: bytes))
        #expect(throws: bytes == nil ? CompanionCredentialError.unavailable : .invalid) {
            try p.verifySelfRevocation(deviceID: revocationDevice, bytes: proof)
        }
    }
}

@Test func inactiveAndUnknownDevicesCannotSupplyAnAcceptedRevocation() throws {
    let f = RevocationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let original = try f.prepare()
    let proof = try f.proof()
    let p = try CompanionProfile(database: f.database, relay: original.relay, secrets: RevocationUnavailableSecrets(bytes: nil))
    #expect(try !p.verifySelfRevocation(deviceID: revocationOther, bytes: proof))
    for state in ["pairing", "revoked", "abandoned"] {
        _ = try original.store.write { try $0.execute("UPDATE devices SET state = ? WHERE device = ?", .text(state), .text(revocationDevice)) }
        #expect(try !p.verifySelfRevocation(deviceID: revocationDevice, bytes: proof))
    }
}

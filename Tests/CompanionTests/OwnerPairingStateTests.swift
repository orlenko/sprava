import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class SessionSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var entries: [String: Data] = [:]
    var failRemove = false
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if entries[account] != nil { return false }; entries[account] = bytes; return true
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemove { throw CompanionCredentialError.unavailable }
        entries.removeValue(forKey: account)
    }
}
private struct SessionFixture {
    let folder: URL
    let secrets = SessionSecrets()
    let profile: CompanionProfile
    let credentials: CompanionOwnerCredentials
    let reservation: CompanionPairingReservation
    let created = CompanionCreatedPairing(id: CompanionWire.base64(Data(repeating: 9, count: 16)),
        secret: CompanionWire.base64(Data(repeating: 10, count: 16)), expiresAt: "2026-10-15T12:00:00Z")
    let phone = Curve25519.KeyAgreement.PrivateKey()
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-owner-pairing-" + UUID().uuidString)
        let relay = try CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
        credentials = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 13, count: 32).base64EncodedString())
        profile = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
        _ = try profile.prepareAccount()
        reservation = try profile.reservePairing()
        _ = try profile.beginPairingCreation(deviceID: reservation.deviceID)
        try profile.captureCreatedPairing(deviceID: reservation.deviceID, created: created)
    }
    func reopen() throws -> CompanionProfile { try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: credentials.relay, secrets: secrets) }
    func remove() { try? FileManager.default.removeItem(at: folder) }
    // Derive from the device's private key, independently of the owner-side CompanionPairing helper.
    func phoneKey(_ kind: String, count: Int = 32) throws -> SymmetricKey {
        let shared = try phone.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: reservation.ownerPublicKey))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(created.id.utf8),
            sharedInfo: Data("sprava-companion/v0 \(kind)".utf8) + reservation.ownerPublicKey + phone.publicKey.rawRepresentation +
                (try CompanionWire.decode(reservation.deviceID)), outputByteCount: count)
    }
    func hello(_ label: String = "Pocket", badPad: Bool = false) throws -> Data {
        let base = JSONObject([("label", .string(label)), ("pad", .string(""))])
        let amount = 512 - JSONWriter.compact(.object(base)).utf8.count
        let pad = (badPad ? "x" : " ") + String(repeating: " ", count: amount - 1)
        let bytes = Data(JSONWriter.compact(.object(JSONObject([("label", .string(label)), ("pad", .string(pad))]))).utf8)
        return try CompanionSealedObject.seal(name: "pairings/\(created.id)/hello", epoch: 0, key: phoneKey("wrap"), plaintext: bytes)
    }
    func observe(_ hello: Data? = nil) throws -> CompanionPairingApproval {
        let response = CompanionRelayPairing(state: .joined, deviceID: reservation.deviceID,
            publicKey: phone.publicKey.rawRepresentation, hello: try hello ?? self.hello())
        return try #require(try profile.observePairing(deviceID: reservation.deviceID, response: response))
    }
}

@Test func ownerCapturesOneTranscriptAndReturnsThePhoneDerivedCodeAfterValidatingHello() throws {
    let f = try SessionFixture(); defer { f.remove() }
    let approval = try f.observe()
    let codeBytes = try f.phoneKey("confirm", count: 4).withUnsafeBytes { Data($0) }
    let number = codeBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000
    #expect(approval.confirmation == String(format: "%06u", number))
    #expect(approval.label == "Pocket")
    #expect(try f.reopen().createdPairing(deviceID: f.reservation.deviceID)?.secret == f.created.secret)
    let changedHello = try f.hello("Other label")
    #expect(try f.observe(changedHello).label == "Pocket")
    #expect(try f.profile.pairingDelivery(deviceID: f.reservation.deviceID) == nil)
}

@Test func changedPublicKeyAndMalformedHelloAbandonOnlyThePendingDevice() throws {
    for invalid in [false, true] {
        let f = try SessionFixture(); defer { f.remove() }
        if !invalid { _ = try f.observe() }
        let response = CompanionRelayPairing(state: .joined, deviceID: f.reservation.deviceID,
            publicKey: invalid ? f.phone.publicKey.rawRepresentation : Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation,
            hello: try f.hello(badPad: invalid))
        #expect(throws: CompanionOwnerPairingError.invalid) { try f.profile.observePairing(deviceID: f.reservation.deviceID, response: response) }
        #expect(try f.profile.deviceRecords().first?.state == .abandoned)
        #expect(f.secrets.entries[f.profile.pairingAccount(f.reservation.deviceID)] == nil)
        #expect(f.secrets.entries[f.profile.createdAccount(f.reservation.deviceID)] == nil)
    }
}

@Test func confirmationStoresExactEnvelopesAndRecipientBeforeReturningAndRestartReusesThem() throws {
    let f = try SessionFixture(); defer { f.remove() }
    let approval = try f.observe()
    let delivery = try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:55:00Z")
    let retry = try f.reopen().confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:56:00Z")
    #expect(delivery.wrappedKey == retry.wrappedKey && delivery.deviceKeys == retry.deviceKeys)
    let wrapped = try CompanionSealedObject.open(name: "pairings/\(f.created.id)/key", epoch: 1, key: f.phoneKey("wrap"), bytes: delivery.wrappedKey)
    let signed = try CompanionSealedObject.open(name: delivery.keysName, epoch: 1, key: f.phoneKey("device"),
        bytes: delivery.deviceKeys, owner: f.credentials.signingKey.publicKey)
    #expect(wrapped["device_id"]?.stringValue == f.reservation.deviceID && signed["device_id"] == wrapped["device_id"])
    #expect(wrapped["account_key"] == signed["account_key"] && CompanionWire.unsigned(wrapped["min_index_revision"]) == 0)
    #expect(try f.profile.deviceRecords().first?.state == .active)
    #expect(try f.profile.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(0)]])
    #expect(try f.profile.store.read { try $0.rows("SELECT epoch, device FROM recipients") } == [[.integer(1), .text(f.reservation.deviceID)]])
}

@Test func aFailedConfirmationCommitDoesNotActivateOrExposeDeliveryAndCanRetry() throws {
    let f = try SessionFixture(); defer { f.remove() }
    let approval = try f.observe()
    #expect(throws: CompanionCredentialError.unavailable) {
        try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:55:00Z",
                                    beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(try f.profile.pairingDelivery(deviceID: f.reservation.deviceID) == nil)
    #expect(try f.profile.deviceRecords().first?.state == .pairing)
    let key = try #require(f.secrets.entries[f.profile.deviceAccount(f.reservation.deviceID)])
    _ = try f.reopen().confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:56:00Z")
    #expect(f.secrets.entries[f.profile.deviceAccount(f.reservation.deviceID)] == key)
}

@Test func pendingPublicationBlocksConfirmationAndItsSettledRevisionBecomesTheFloor() throws {
    let f = try SessionFixture(); defer { f.remove() }
    let approval = try f.observe()
    try f.profile.store.write { try $0.execute("UPDATE profile SET index_reserved = 13, index_published = 12") }
    #expect(throws: CompanionCredentialError.unavailable) { try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:55:00Z") }
    #expect(f.secrets.entries[f.profile.deviceAccount(f.reservation.deviceID)] == nil)
    try f.profile.store.write { try $0.execute("UPDATE profile SET index_published = 13") }
    let delivery = try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:56:00Z")
    let wrapped = try CompanionSealedObject.open(name: "pairings/\(f.created.id)/key", epoch: 1, key: f.phoneKey("wrap"), bytes: delivery.wrappedKey)
    #expect(CompanionWire.unsigned(wrapped["min_index_revision"]) == 13)
}

@Test func activeDeviceIgnoresChangedRelayTranscriptAndAcknowledgementRetriesSecretCleanup() throws {
    let f = try SessionFixture(); defer { f.remove() }
    let approval = try f.observe()
    let delivery = try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:55:00Z")
    let bogus = CompanionRelayPairing(state: .acknowledged, deviceID: "bogus", publicKey: nil, hello: nil)
    #expect(try f.profile.observePairing(deviceID: f.reservation.deviceID, response: bogus) == nil)
    f.secrets.failRemove = true
    #expect(throws: CompanionCredentialError.unavailable) { try f.profile.acknowledgePairing(deviceID: f.reservation.deviceID) }
    let pending = try #require(try f.reopen().pairingDelivery(deviceID: f.reservation.deviceID))
    #expect(pending.acknowledged && pending.ephemeralCleanupPending)
    f.secrets.failRemove = false
    try f.reopen().finishPairingSecrets(deviceID: f.reservation.deviceID)
    #expect(f.secrets.entries[f.profile.deviceAccount(f.reservation.deviceID)] != nil)
    #expect(f.secrets.entries[f.profile.pairingAccount(f.reservation.deviceID)] == nil)
    #expect(f.secrets.entries[f.profile.createdAccount(f.reservation.deviceID)] == nil)
    let retry = try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T12:05:00Z")
    #expect(retry.deviceKeys == delivery.deviceKeys && retry.wrappedKey == delivery.wrappedKey)
}

@Test func expiredApprovalCannotActivateAndForgetsKeysStagedByAnEarlierFailedConfirmation() throws {
    let f = try SessionFixture(); defer { f.remove() }
    let approval = try f.observe()
    #expect(throws: CompanionCredentialError.unavailable) {
        try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T11:55:00Z",
                                    beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(throws: CompanionOwnerPairingError.expired) { try f.profile.confirmPairing(approval, credentials: f.credentials, now: "2026-10-15T12:00:00Z") }
    #expect(try f.profile.deviceRecords().first?.state == .abandoned)
    #expect(f.secrets.entries[f.profile.deviceAccount(f.reservation.deviceID)] == nil)
}

import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Companion

private final class PairingSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var entries: [String: Data] = [:]
    var failWrite = false
    var failRemove = false
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failWrite { throw CompanionCredentialError.unavailable }
        if entries[account] != nil { return false }
        entries[account] = bytes; return true
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemove { throw CompanionCredentialError.unavailable }
        entries.removeValue(forKey: account)
    }
}
private struct DeviceFixture: Sendable {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-companion-devices-" + UUID().uuidString)
    let secrets = PairingSecrets()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func profile() throws -> CompanionProfile {
        let relay = try CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
        return try CompanionProfile(database: database, relay: relay, secrets: secrets)
    }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}

@Test func reservedDeviceAndEphemeralKeySurviveRestartAndCreateCanBeAttemptedOnlyOnce() throws {
    let f = DeviceFixture(); defer { f.remove() }
    let profile = try f.profile()
    _ = try profile.prepareAccount()
    let reserved = try profile.reservePairing()
    #expect(CompanionWire.isID(reserved.deviceID) && reserved.ownerPublicKey.count == 32)
    let restarted = try f.profile()
    let first = try restarted.beginPairingCreation(deviceID: reserved.deviceID)
    #expect(first.ownerPublicKey == reserved.ownerPublicKey)
    #expect(throws: CompanionCredentialError.invalid) { try f.profile().beginPairingCreation(deviceID: reserved.deviceID) }
    let row = try #require(try restarted.deviceRecords().first)
    #expect(row.creationAttempted && row.keyReady && row.state == .pairing)
    #expect(try restarted.preparePairingReservation(deviceID: reserved.deviceID).ownerPublicKey == reserved.ownerPublicKey)
}

@Test func aFailedEphemeralKeyWriteRetainsItsIdAndCanRecoverBeforeAnyCreateAttempt() throws {
    let f = DeviceFixture(); defer { f.remove() }
    let profile = try f.profile()
    _ = try profile.prepareAccount()
    f.secrets.failWrite = true
    #expect(throws: CompanionCredentialError.unavailable) { try profile.reservePairing() }
    let row = try #require(try f.profile().deviceRecords().first)
    #expect(!row.creationAttempted && !row.keyReady)
    #expect(throws: CompanionCredentialError.invalid) { try profile.beginPairingCreation(deviceID: row.deviceID) }
    f.secrets.failWrite = false
    let recovered = try f.profile().preparePairingReservation(deviceID: row.deviceID)
    #expect(recovered.deviceID == row.deviceID)
    #expect(try profile.beginPairingCreation(deviceID: row.deviceID).ownerPublicKey == recovered.ownerPublicKey)
}

@Test func missingReadyKeysAreNeverReplacedAndDoNotMarkCreationAttempted() throws {
    let f = DeviceFixture(); defer { f.remove() }
    let profile = try f.profile()
    _ = try profile.prepareAccount()
    let reservation = try profile.reservePairing(), account = profile.pairingAccount(reservation.deviceID)
    f.secrets.entries.removeValue(forKey: account)
    #expect(throws: CompanionCredentialError.unavailable) { try profile.preparePairingReservation(deviceID: reservation.deviceID) }
    #expect(throws: CompanionCredentialError.unavailable) { try profile.beginPairingCreation(deviceID: reservation.deviceID) }
    #expect(f.secrets.entries[account] == nil)
    #expect(try profile.deviceRecords().first?.creationAttempted == false)
}

@Test func abandonedDeviceIsInactiveBeforeDeletionAndItsFailedCleanupSurvivesRestart() throws {
    let f = DeviceFixture(); defer { f.remove() }
    let profile = try f.profile()
    _ = try profile.prepareAccount()
    let reservation = try profile.reservePairing(), account = profile.pairingAccount(reservation.deviceID)
    _ = try profile.beginPairingCreation(deviceID: reservation.deviceID)
    f.secrets.failRemove = true
    #expect(throws: CompanionCredentialError.unavailable) { try profile.abandonPairing(deviceID: reservation.deviceID) }
    let row = try #require(try f.profile().deviceRecords().first)
    #expect(row.state == .abandoned && row.cleanupPending && row.creationAttempted)
    #expect(f.secrets.entries[account] != nil)
    #expect(throws: CompanionCredentialError.invalid) { try profile.preparePairingReservation(deviceID: reservation.deviceID) }
    #expect(throws: CompanionCredentialError.invalid) { try profile.beginPairingCreation(deviceID: reservation.deviceID) }
    f.secrets.failRemove = false
    try f.profile().cleanAbandonedPairing(deviceID: reservation.deviceID)
    try f.profile().abandonPairing(deviceID: reservation.deviceID)
    let cleaned = try #require(try profile.deviceRecords().first)
    #expect(cleaned.state == .abandoned && !cleaned.cleanupPending && !cleaned.keyReady)
    #expect(f.secrets.entries[account] == nil)
    #expect(try profile.prepareAccount().number == 1)
    #expect(f.secrets.entries.count == 1)
}

@Test func concurrentReservationsKeepDistinctIdsAndBoundedKeylessRecoveryPages() async throws {
    let f = DeviceFixture(); defer { f.remove() }
    _ = try f.profile().prepareAccount()
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<20 { group.addTask { try f.profile().reservePairing().deviceID } }
        var ids: [String] = []
        for try await id in group { ids.append(id) }
        return ids
    }
    #expect(Set(ids).count == 20)
    let profile = try f.profile(), first = try profile.deviceRecords(limit: 7)
    let second = try profile.deviceRecords(limit: 100, after: try #require(first.last).deviceID)
    #expect(first.count == 7 && second.count == 13)
    #expect(Set((first + second).map(\.deviceID)) == Set(ids))
    #expect(throws: CompanionCredentialError.invalid) { try profile.deviceRecords(limit: 101) }
    #expect(throws: CompanionCredentialError.invalid) { try profile.deviceRecords(after: "../x") }
}

@Test func deviceReservationRequiresAnAccountAndDeletionUsesOnlyTheLocalKeychainNamespace() throws {
    let f = DeviceFixture(); defer { f.remove() }
    let profile = try f.profile()
    #expect(throws: CompanionCredentialError.invalid) { try profile.reservePairing() }
    let keychain = CompanionKeychain(calls: .init(read: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecSuccess }, remove: { query in
        let q = query as! [String: Any]
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect((q[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(q[kSecAttrAccount as String] as? String == "invented")
        return errSecItemNotFound
    }))
    try keychain.remove(account: "invented")
    let locked = CompanionKeychain(calls: .init(read: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecSuccess }, remove: { _ in errSecInteractionNotAllowed }))
    #expect(throws: CompanionCredentialError.unavailable) { try locked.remove(account: "invented") }
}

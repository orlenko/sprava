import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private let rotationAt = "2026-10-15T12:00:00Z"
private func rotationID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }
private let phoneA = rotationID(80), phoneB = rotationID(81), phoneC = rotationID(82), shownBinder = rotationID(90)

private final class RotationSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; if entries[account] != nil { return false }; entries[account] = bytes; return true
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: account) }
}
private final class RotationRelay: OwnerRotationTransport, @unchecked Sendable {
    private let lock = NSLock()
    var answer: Result<Int, any Error> = .success(204)
    private(set) var puts: [String] = []
    func putObject(name: String, bytes: Data) async throws -> Int {
        lock.withLock { puts.append(name) }
        return try answer.get()
    }
}
private struct RotationTimeout: Error {}

private struct RotationFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-rotation-" + UUID().uuidString)
    let secrets = RotationSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    func profile() throws -> CompanionProfile {
        try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
    }
    /// A claimed profile at epoch 1 with active phones (each its own `Kd`) and one shown binder.
    func prepare(_ phones: [String] = [phoneA, phoneB]) throws -> CompanionProfile {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 29, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        for phone in phones { try addPhone(phone, p) }
        try p.store.write { t in
            try t.execute("INSERT INTO phone_binders (binder, state) VALUES (?, 'shown')", .text(shownBinder))
        }
        _ = try secrets.insert(account: p.binderKeyAccount(shownBinder, epoch: 1), bytes: Data(repeating: 41, count: 32))
        return p
    }
    func addPhone(_ id: String, _ p: CompanionProfile) throws {
        try p.store.write { t in
            try t.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(id))
            try t.execute("INSERT INTO recipients VALUES (1, ?)", .text(id))
        }
        _ = try secrets.insert(account: p.deviceAccount(id), bytes: kd(id))
    }
    func kd(_ id: String) -> Data { Data(SHA256.hash(data: Data(id.utf8))) }
    func remove(_ id: String, _ p: CompanionProfile) async throws {
        _ = try await CompanionDeviceRemoval(profile: p, locks: CompanionDeviceDecisionLocks()).record(deviceID: id)
    }
    func keysRows(_ p: CompanionProfile) throws -> [[StateValue]] {
        try p.store.read { try $0.rows("SELECT epoch, device, state FROM rotation_keys ORDER BY epoch, device") }
    }
    func uploadAll(_ p: CompanionProfile) throws {
        while let keys = try p.pendingRotationKeys() { try p.recordRotationKeys(keys, uploaded: true) }
    }
}

@Test func aRotationAfterRemovalSealsNewKeysForTheRemainingPhonesAndMovesTheEpochInOneWrite() async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare()
    #expect(try p.beginRotation() == nil) // nothing pending
    try await f.remove(phoneA, p)
    #expect(try p.rotationBlocksPublication())
    let old = try #require(try p.currentAccount()).key.withUnsafeBytes { Data($0) }
    #expect(try p.beginRotation() == 2)
    let account = try #require(try p.currentAccount())
    #expect(account.number == 2 && account.key.withUnsafeBytes { Data($0) } != old)
    #expect(try !p.rotationPending())
    #expect(try p.store.read { try $0.rows("SELECT device FROM recipients WHERE epoch = 2") } == [[.text(phoneB)]])
    #expect(try f.keysRows(p) == [[.integer(2), .text(phoneB), .text("pending")]])
    #expect(try p.store.read { try $0.rows("SELECT key_epoch FROM phone_binders") } == [[.integer(2)]])
    #expect(try p.bindersNeedingEpochView() == [shownBinder]) // step 4: snapshot it again at epoch 2
    let newBinderKey = try #require(try f.secrets.read(account: p.binderKeyAccount(shownBinder, epoch: 2)))
    #expect(newBinderKey != Data(repeating: 41, count: 32))
    // The keys object opens only with that phone's Kd, carries the new K and is signed by the owner (§8.3).
    let keys = try #require(try p.pendingRotationKeys())
    let owner = try #require(try CompanionOwnerVault(backend: f.secrets).load(f.relay))
    let opened = try CompanionSealedObject.open(name: keys.name, epoch: 2, key: SymmetricKey(data: f.kd(phoneB)),
                                                bytes: keys.bytes, owner: owner.signingKey.publicKey)
    #expect(opened["account_key"]?.stringValue == CompanionWire.base64(account.key.withUnsafeBytes { Data($0) }))
    #expect(CompanionWire.unsigned(opened["epoch"]) == 2 && opened["device_id"]?.stringValue == phoneB)
    #expect(throws: (any Error).self) {
        try CompanionSealedObject.open(name: keys.name, epoch: 2, key: SymmetricKey(data: f.kd(phoneA)),
                                       bytes: keys.bytes, owner: owner.signingKey.publicKey)
    }
    #expect(try p.beginRotation() == nil)
}

@Test func aFailedRotationCommitChangesNothingAndTheRetryReusesTheStagedKeys() async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare()
    try await f.remove(phoneA, p)
    #expect(throws: CompanionCredentialError.unavailable) {
        try p.beginRotation(beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(try p.currentAccount()?.number == 1 && p.rotationPending() && f.keysRows(p).isEmpty)
    let staged = try #require(try f.secrets.read(account: p.keyAccount(2)))
    let stagedBinder = try #require(try f.secrets.read(account: p.binderKeyAccount(shownBinder, epoch: 2)))
    #expect(try f.profile().beginRotation() == 2)
    #expect(try f.secrets.read(account: p.keyAccount(2)) == staged)
    #expect(try f.secrets.read(account: p.binderKeyAccount(shownBinder, epoch: 2)) == stagedBinder)
}

@Test func publicationAtTheNewEpochWaitsUntilEveryRemainingPhonesKeysAreOnTheRelay() async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare([phoneA, phoneB, phoneC])
    #expect(try !p.rotationBlocksPublication())
    try p.admitPublicationEpoch()
    try await f.remove(phoneA, p)
    #expect(throws: CompanionPublicationError.unavailable) { try p.admitPublicationEpoch() }
    try p.beginRotation()
    let first = try #require(try p.pendingRotationKeys())
    try p.recordRotationKeys(first, uploaded: true)
    #expect(try p.rotationBlocksPublication())
    #expect(throws: CompanionPublicationError.unavailable) { try p.admitPublicationEpoch() }
    try f.uploadAll(p)
    #expect(try !p.rotationBlocksPublication())
    try p.admitPublicationEpoch()
}

/// Each relay answer to a keys upload has exactly one outcome; none starts another rotation by itself.
@Test(arguments: ["204", "409", "410-active", "410-revoked", "401", "503", "timeout"])
func eachRelayAnswerToAKeysUploadHasOneOutcome(_ answer: String) async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare()
    try await f.remove(phoneA, p)
    let relay = RotationRelay()
    let worker = CompanionOwnerRotation(profile: p, transport: relay, now: { rotationAt })
    #expect(try await worker.step() == .rotated(epoch: 2))
    let keys = try #require(try p.pendingRotationKeys())
    switch answer {
    case "204": relay.answer = .success(204)
    case "409": relay.answer = .success(409)
    case "410-active": relay.answer = .success(410)
    case "410-revoked":
        relay.answer = .success(410)
        try p.store.write { try $0.execute("UPDATE devices SET state = 'revoked' WHERE device = ?", .text(phoneB)) }
    case "401": relay.answer = .success(401)
    case "503": relay.answer = .success(503)
    default: relay.answer = .failure(RotationTimeout())
    }
    let outcome: Result<CompanionRotationProgress, any Error>
    do { outcome = .success(try await worker.step()) } catch { outcome = .failure(error) }
    #expect(relay.puts == [keys.name])
    switch answer {
    case "204", "410-revoked":
        #expect(try outcome.get() == .uploaded(deviceID: phoneB))
        #expect(try f.keysRows(p) == [[.integer(2), .text(phoneB), .text("uploaded")]])
        #expect(try !p.rotationFault() && !p.rotationBlocksPublication())
    case "409", "410-active":
        #expect(try outcome.get() == .refused(deviceID: phoneB))
        #expect(try p.rotationFault() && p.rotationBlocksPublication() && !p.rotationPending())
        #expect(try await worker.step() == .idle) // recorded and stopped: no re-rotation, no second upload
        #expect(relay.puts.count == 1)
        #expect(try p.currentAccount()?.number == 2)
    case "401":
        #expect(throws: CompanionOwnerConnectionError.relayRejected(401)) { try outcome.get() }
        #expect(try p.ownerClaimState() == .checkingRefusal && p.pendingRotationKeys() == keys)
    case "503":
        #expect(throws: CompanionOwnerConnectionError.relayRejected(503)) { try outcome.get() }
        #expect(try p.pendingRotationKeys() == keys && !p.rotationFault())
    default:
        #expect(throws: RotationTimeout.self) { try outcome.get() }
        #expect(try p.pendingRotationKeys() == keys && !p.rotationFault())
    }
}

@Test func thePersonsRetryAfterARelayFaultRotatesAgainAndReplacesTheRefusedKeys() async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare()
    try await f.remove(phoneA, p)
    try p.beginRotation()
    try p.recordRotationKeys(try #require(try p.pendingRotationKeys()), uploaded: false)
    #expect(try p.rotationFault())
    try p.requestRotation()
    #expect(try p.beginRotation() == 3)
    #expect(try !p.rotationFault() && p.pendingRotationKeys()?.epoch == 3)
}

@Test func aRemovalDuringAnUnfinishedRotationDropsItsUnsentKeysObjects() async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare([phoneA, phoneB, phoneC])
    try await f.remove(phoneA, p)
    try p.beginRotation()
    #expect(try f.keysRows(p) == [[.integer(2), .text(phoneB), .text("pending")], [.integer(2), .text(phoneC), .text("pending")]])
    try p.recordRotationKeys(try #require(try p.pendingRotationKeys()), uploaded: true) // B's arrives
    try await f.remove(phoneB, p)
    #expect(try p.beginRotation() == 3)
    // C's unsent epoch-2 object is dropped; it needs only the newest. B's sent one stays recorded for cleanup.
    #expect(try f.keysRows(p) == [[.integer(2), .text(phoneB), .text("uploaded")], [.integer(3), .text(phoneC), .text("pending")]])
    #expect(try p.store.read { try $0.rows("SELECT device FROM recipients WHERE epoch = 3") } == [[.text(phoneC)]])
    #expect(try p.store.read { try $0.rows("SELECT epoch FROM discard_epochs ORDER BY epoch") } == [[.integer(1)], [.integer(2)]])
}

@Test func aPhoneConfirmedButNotYetAcknowledgedIsGivenTheNewEpochToo() async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare()
    // Phone C: confirmed at epoch 1, its pairing delivery recorded but not acknowledged by the phone.
    try f.addPhone(phoneC, p)
    try p.store.write { t in
        try t.execute("INSERT INTO pairings (device, pairing, expires, key_epoch, wrapped_key, device_keys, paired_at, acknowledged) " +
                      "VALUES (?, ?, '2099-01-01T00:00:00Z', 1, ?, ?, ?, 0)",
                      .text(phoneC), .text(rotationID(83)), .blob(Data([1])), .blob(Data([2])), .text(rotationAt))
    }
    try await f.remove(phoneA, p)
    try p.beginRotation()
    #expect(try p.store.read { try $0.rows("SELECT device FROM rotation_keys WHERE epoch = 2 ORDER BY device") } ==
            [[.text(phoneB)], [.text(phoneC)]])
    // Its pairing delivery still sends the epoch-1 key it was promised; keys/2 then moves it to epoch 2 (§4.4).
    #expect(try p.pairingDelivery(deviceID: phoneC)?.epoch == 1)
}

@Test func oldKeysAreDiscardedOnlyAfterAnIndexAtTheNewEpochIsPublished() async throws {
    let f = RotationFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare()
    try await f.remove(phoneA, p)
    let relay = RotationRelay(), worker = CompanionOwnerRotation(profile: p, transport: relay, now: { rotationAt })
    #expect(try await worker.step() == .rotated(epoch: 2))
    #expect(try await worker.step() == .uploaded(deviceID: phoneB))
    #expect(try await worker.step() == .idle)
    #expect(try f.secrets.read(account: p.keyAccount(1)) != nil)
    #expect(try f.secrets.read(account: p.binderKeyAccount(shownBinder, epoch: 1)) != nil)
    let index = try p.prepareIndex(generatedAt: rotationAt)
    #expect(index.epoch == 2)
    #expect(try !p.discardOldEpochKeys()) // recorded, not yet published
    try p.completeIndex(index)
    #expect(try await worker.step() == .discarded)
    #expect(try f.secrets.read(account: p.keyAccount(1)) == nil)
    #expect(try f.secrets.read(account: p.binderKeyAccount(shownBinder, epoch: 1)) == nil)
    #expect(try f.secrets.read(account: p.keyAccount(2)) != nil)
    #expect(try f.secrets.read(account: p.binderKeyAccount(shownBinder, epoch: 2)) != nil)
    #expect(try await worker.step() == .idle)
}

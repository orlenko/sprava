import Foundation
import SpravaKit
import Testing
@testable import Companion

private final class CleanupSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var removalsBlocked = false
    private var readsBlocked = false
    func blockRemovals() { lock.lock(); defer { lock.unlock() }; removalsBlocked = true }
    func blockReads() { lock.lock(); defer { lock.unlock() }; readsBlocked = true }
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if readsBlocked { throw CompanionCredentialError.unavailable }; return values[account]
    }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if removalsBlocked { throw CompanionCredentialError.unavailable }; values.removeValue(forKey: account)
    }
}
private actor CleanupRelay: OwnerPairingCleanupTransport {
    private var ids: [String] = []
    private var status = 204
    private var loseReply = false
    func loseNextReply() { loseReply = true }
    func reply(_ status: Int) { self.status = status }
    func calls() -> [String] { ids }
    func deletePairing(_ id: String) async throws -> Int {
        ids.append(id)
        if loseReply { loseReply = false; throw CompanionRelayError.invalid }
        return status
    }
}
private struct CleanupFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-pairing-cleanup-" + UUID().uuidString)
    let secrets = CleanupSecrets()
    let relay = CleanupRelay()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func profile() throws -> CompanionProfile {
        try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"), secrets: secrets)
    }
    func prepare() throws {
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
    }
    func reserve(_ byte: UInt8) throws -> CompanionAbandonedPairing {
        let p = try profile(), reserved = try p.reservePairing()
        _ = try p.beginPairingCreation(deviceID: reserved.deviceID)
        let id = CompanionWire.base64(Data(repeating: byte, count: 16))
        try p.captureCreatedPairing(deviceID: reserved.deviceID, created: CompanionCreatedPairing(id: id,
            secret: CompanionWire.base64(Data(repeating: byte + 1, count: 16)), expiresAt: "2026-10-15T12:00:00Z"))
        return CompanionAbandonedPairing(deviceID: reserved.deviceID, pairingID: id)
    }
    func cleanup() throws -> CompanionOwnerPairingCleanup { CompanionOwnerPairingCleanup(profile: try profile(), transport: relay) }
}

@Test func aLostAbandonedPairingDeleteReplyRetainsItsExactIdAcrossRestart() async throws {
    let f = CleanupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let pending = try f.reserve(31); try f.profile().abandonPairing(deviceID: pending.deviceID)
    #expect(try f.profile().abandonedPairings() == [pending])
    await f.relay.loseNextReply()
    await #expect(throws: CompanionRelayError.invalid) { try await f.cleanup().step(deviceID: pending.deviceID) }
    #expect(try f.profile().abandonedPairings() == [pending])
    await f.relay.reply(404) // The first DELETE may already have reached the relay.
    #expect(try await f.cleanup().step(deviceID: pending.deviceID) == .deleted)
    #expect(await f.relay.calls() == [pending.pairingID, pending.pairingID])
    #expect(try f.profile().abandonedPairings().isEmpty)
    #expect(try f.profile().deviceRecords().first?.state == .abandoned)
    #expect(try await f.cleanup().step(deviceID: pending.deviceID) == .nothingPending)
    #expect(await f.relay.calls().count == 2)
}

@Test func aCleanupRefusalSuspendsOwnerAdmissionAndKeepsThePendingId() async throws {
    let f = CleanupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let pending = try f.reserve(33); try f.profile().abandonPairing(deviceID: pending.deviceID)
    await f.relay.reply(401)
    await #expect(throws: CompanionPairingFlowError.relayRejected(401)) { try await f.cleanup().step(deviceID: pending.deviceID) }
    #expect(try f.profile().ownerClaimState() == .checkingRefusal)
    #expect(try f.profile().abandonedPairings() == [pending])
    await #expect(throws: CompanionPairingFlowError.ownerUnavailable(.checkingRefusal)) { try await f.cleanup().step(deviceID: pending.deviceID) }
    #expect(await f.relay.calls().count == 1)
}

@Test func relayCleanupAcknowledgmentKeepsFailedLocalKeyCleanupAndNeverTargetsAnActiveDevice() async throws {
    let f = CleanupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let pending = try f.reserve(35), active = try f.reserve(37)
    f.secrets.blockRemovals()
    #expect(throws: CompanionCredentialError.unavailable) { try f.profile().abandonPairing(deviceID: pending.deviceID) }
    try f.profile().store.write { try $0.execute("UPDATE devices SET state = 'active' WHERE device = ?", .text(active.deviceID)) }
    #expect(try await f.cleanup().step(deviceID: active.deviceID) == .nothingPending)
    #expect(try await f.cleanup().step(deviceID: pending.deviceID) == .deleted)
    let retained = try #require(try f.profile().deviceRecords().first(where: { $0.deviceID == pending.deviceID }))
    #expect(retained.state == .abandoned && retained.cleanupPending)
    #expect(try f.profile().abandonedPairings().isEmpty)
    #expect(await f.relay.calls() == [pending.pairingID])
}

@Test func abandonedPairingPagesAreBoundedKeylessAndExcludeUnabandonedAndUnknownResults() async throws {
    let f = CleanupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let a = try f.reserve(39), b = try f.reserve(41), waiting = try f.reserve(43)
    try f.profile().abandonPairing(deviceID: a.deviceID); try f.profile().abandonPairing(deviceID: b.deviceID)
    let unknown = try f.profile().reservePairing(); try f.profile().abandonPairing(deviceID: unknown.deviceID)
    let first = try f.profile().abandonedPairings(limit: 1)
    let cursor = try #require(first.first?.deviceID)
    let second = try f.profile().abandonedPairings(limit: 1, after: cursor)
    #expect((first + second).map(\.deviceID) == [a.deviceID, b.deviceID].sorted())
    #expect(!(first + second).contains(where: { $0.deviceID == waiting.deviceID || $0.deviceID == unknown.deviceID }))
    f.secrets.blockReads()
    _ = CompanionOwnerPairingCleanup(profile: try f.profile()) // Constructor and idle step must remain keyless.
    #expect(try await CompanionOwnerPairingCleanup(profile: f.profile()).step(deviceID: waiting.deviceID) == .nothingPending)
    #expect(try f.profile().abandonedPairings().count == 2)
    #expect(throws: CompanionOwnerPairingError.invalid) { try f.profile().abandonedPairings(limit: 21) }
    #expect(throws: CompanionOwnerPairingError.invalid) { try f.profile().abandonedPairings(after: "bad id") }
}

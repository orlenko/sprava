import Foundation
import Testing
@testable import Companion
import SpravaKit

private let removalAt = "2026-10-15T12:00:00Z", removalDay = "2026-10-15"
private func removalID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }
private final class RemovalSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    var failRemove = false
    var failAccount: String?
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; if entries[account] != nil { return false }; entries[account] = bytes; return true
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemove || failAccount == account { throw CompanionCredentialError.unavailable }; entries.removeValue(forKey: account)
    }
}
private struct RemovalForbiddenSecrets: CompanionCredentialStorage {
    func read(account: String) throws -> Data? { throw CompanionCredentialError.unavailable }
    func insert(account: String, bytes: Data) throws -> Bool { throw CompanionCredentialError.unavailable }
}
private struct RemovalFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-device-removal-" + UUID().uuidString)
    let secrets = RemovalSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    func profile() throws -> CompanionProfile { try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets) }
    func prepare(_ id: String = removalID(70)) throws -> CompanionProfile {
        let p = try profile()
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 23, count: 32).base64EncodedString())
        _ = try p.prepareAccount(); try p.recordClaimState(.claimed); try addDevice(id, p); return p
    }
    func addDevice(_ id: String, _ p: CompanionProfile) throws {
        try p.store.write { t in
            try t.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(id))
            try t.execute("INSERT INTO recipients VALUES (1, ?)", .text(id))
        }
        _ = try secrets.insert(account: p.deviceAccount(id), bytes: Data(repeating: 24, count: 32))
    }
    func decision(_ p: CompanionProfile, _ id: String = removalID(70), seq: Int64 = 1) throws -> CompanionDecisionRecord {
        let action = CompanionRequestedAction(kind: .done, madeAt: removalAt, binderID: removalID(72), itemID: .str("item"),
                                             seenVersion: 1, date: nil, text: nil)
        let request = CompanionAuthenticatedRequest(deviceID: id, requestID: removalID(UInt8(73 + seq)), epoch: 1, sequence: seq, action: action)
        guard case .deciding(let d) = try p.beginDecision(request, plan: CompanionDecisionPlan(outcome: .applied, effect: .none),
                                                       today: removalDay, now: removalAt) else { throw CompanionDecisionError.invalid }; return d
    }
    func dirtyOutcomes(_ p: CompanionProfile) throws -> CompanionOutcomesPublication {
        let d = try decision(p); try p.finishDecision(d, today: removalDay, decidedAt: removalAt)
        return try #require(try p.prepareOutcomes(deviceID: removalID(70), generatedAt: removalAt))
    }
}
private actor RemovalPause {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?, release: CheckedContinuation<Void, Never>?
    func pause() async { await withCheckedContinuation { release = $0; entered = true; observer?.resume(); observer = nil } }
    func wait() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func open() { release?.resume(); release = nil }
}

@Test func removalCommitsTheBarrierAndRetiresOutcomesBeforeAnyDeviceKeyDeletion() async throws {
    let f = RemovalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare(), id = removalID(70)
    let publication = try f.dirtyOutcomes(p)
    let account = try #require(try p.currentAccount()).key.withUnsafeBytes { Data($0) }
    let receipt = try await CompanionDeviceRemoval(profile: p, locks: CompanionDeviceDecisionLocks()).record(deviceID: id)
    #expect(receipt.keyCleanupPending && receipt.relayDeletionPending && receipt.rotationPending)
    #expect(try p.deviceRecords().first?.state == .revoked)
    #expect(try f.secrets.read(account: p.deviceAccount(id)) != nil)
    #expect(try p.currentAccount()?.key.withUnsafeBytes { Data($0) } == account)
    #expect(try p.store.read { try $0.rows("SELECT outcomes_generation, outcomes_built, outcomes_reserved, outcomes_published FROM decision_state") } ==
            [[.integer(1), .integer(1), .integer(1), .integer(0)]])
    #expect(try p.store.read { try $0.rows("SELECT count(*) FROM outcomes_upload") } == [[.integer(0)]])
    #expect(try p.store.read { try $0.rows("SELECT count(*) FROM outcome_tombstones") } == [[.integer(1)]])
    #expect(try p.pendingOutcomes(deviceID: id) == nil)
    #expect(try !p.completeOutcomes(publication)); try p.supersedeOutcomes(publication)
    #expect(throws: CompanionDecisionError.unavailable) { try f.decision(p, seq: 2) }
    #expect(throws: CompanionPublicationError.unavailable) { try p.admitPublicationEpoch() }
    #expect(throws: CompanionPublicationError.unavailable) { try p.prepareIndex(generatedAt: removalAt) }
    #expect(try p.store.read { try $0.rows("SELECT index_reserved FROM profile") } == [[.integer(0)]])
}

@Test func decidingRequestsAndFailedRemovalCommitsPreserveEveryEarlierRecord() async throws {
    let f = RemovalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare(), id = removalID(70)
    let pending = try f.decision(p), worker = CompanionDeviceRemoval(profile: p, locks: CompanionDeviceDecisionLocks())
    await #expect(throws: CompanionDeviceRemovalError.decisionPending) { try await worker.record(deviceID: id) }
    #expect(try p.pendingDecision(deviceID: id)?.bytes == pending.bytes)
    #expect(try !p.rotationPending() && p.deviceRemoval(deviceID: id) == nil)
    #expect(try p.deviceRecords().first?.state == .active)
    try p.finishDecision(pending, today: removalDay, decidedAt: removalAt)
    let upload = try #require(try p.prepareOutcomes(deviceID: id, generatedAt: removalAt))
    #expect(throws: CompanionCredentialError.unavailable) {
        try p.recordDeviceRemoval(id, beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(try p.deviceRecords().first?.state == .active)
    #expect(try !p.rotationPending() && p.deviceRemoval(deviceID: id) == nil)
    #expect(try p.pendingOutcomes(deviceID: id)?.bytes == upload.bytes)
    #expect(try f.secrets.read(account: p.deviceAccount(id)) != nil)
}

@Test func removalCleanupIsRestartableAndDuplicatesDoNotRequestAnotherRotation() async throws {
    let f = RemovalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare(), id = removalID(70)
    _ = try await CompanionDeviceRemoval(profile: p, locks: CompanionDeviceDecisionLocks()).record(deviceID: id)
    f.secrets.failRemove = true
    #expect(throws: CompanionCredentialError.unavailable) { try p.finishRemovedDeviceKeyCleanup(deviceID: id) }
    let reopened = try f.profile()
    #expect(try reopened.deviceRemoval(deviceID: id)?.keyCleanupPending == true)
    f.secrets.failRemove = false
    let receipt = try reopened.finishRemovedDeviceKeyCleanup(deviceID: id)
    #expect(!receipt.keyCleanupPending && receipt.relayDeletionPending && receipt.rotationPending)
    #expect(try f.secrets.read(account: p.deviceAccount(id)) == nil)
    #expect(try reopened.currentAccount()?.number == 1)
    #expect(try reopened.finishRemovedDeviceKeyCleanup(deviceID: id) == receipt)
    // A later rotation consumes this intent; a duplicate removal must not create a fresh one.
    try reopened.store.write { try $0.execute("UPDATE rotation_state SET pending = 0") }
    let repeated = try await CompanionDeviceRemoval(profile: reopened, locks: CompanionDeviceDecisionLocks()).record(deviceID: id)
    #expect(!repeated.rotationPending && !repeated.keyCleanupPending && repeated.relayDeletionPending)
}

@Test func removalWaitsForTheSharedDecisionLockAndItsCleanupPagesAreKeylessAndBounded() async throws {
    let f = RemovalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare(), id = removalID(70)
    let locks = CompanionDeviceDecisionLocks(), pause = RemovalPause(), worker = CompanionDeviceRemoval(profile: p, locks: locks)
    let held = Task { try await locks.withLock(deviceID: id) { await pause.pause() } }
    await pause.wait()
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await worker.record(deviceID: id) }
    #expect(try p.deviceRecords().first?.state == .active && !p.rotationPending())
    await pause.open(); try await held.value
    _ = try await worker.record(deviceID: id)
    try f.addDevice(removalID(71), p); _ = try await worker.record(deviceID: removalID(71))
    let keyless = try CompanionProfile(database: f.folder.appendingPathComponent("state.sqlite"), relay: f.relay, secrets: RemovalForbiddenSecrets())
    let first = try keyless.pendingDeviceRemovals(limit: 1)
    #expect(first.removals.count == 1 && first.next != nil)
    let next = try keyless.pendingDeviceRemovals(limit: 1, after: first.next)
    #expect(next.removals.count == 1 && next.next == nil && next.removals[0].deviceID != first.removals[0].deviceID)
    #expect(try keyless.rotationPending())
    #expect(throws: CompanionDeviceRemovalError.invalid) { try keyless.pendingDeviceRemovals(limit: 21) }
    #expect(throws: CompanionDeviceRemovalError.invalid) { try keyless.deviceRemoval(deviceID: "bad") }
}

@Test func removalRetriesPartialCleanupOfUnacknowledgedPairingSecrets() async throws {
    let f = RemovalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare(), id = removalID(70)
    try p.store.write { t in
        try t.execute("UPDATE devices SET key_ready = 1 WHERE device = ?", .text(id))
        try t.execute("INSERT INTO pairings (device, pairing, expires, ephemeral_cleanup) VALUES (?, ?, ?, 1)",
                      .text(id), .text(removalID(79)), .text("2026-10-15T13:00:00Z"))
    }
    _ = try f.secrets.insert(account: p.pairingAccount(id), bytes: Data(repeating: 25, count: 32))
    _ = try f.secrets.insert(account: p.createdAccount(id), bytes: Data("recorded creation".utf8))
    let account = try #require(try p.currentAccount()).key.withUnsafeBytes { Data($0) }
    _ = try await CompanionDeviceRemoval(profile: p, locks: CompanionDeviceDecisionLocks()).record(deviceID: id)
    f.secrets.failAccount = p.pairingAccount(id)
    #expect(throws: CompanionCredentialError.unavailable) { try p.finishRemovedDeviceKeyCleanup(deviceID: id) }
    #expect(try f.secrets.read(account: p.deviceAccount(id)) == nil)
    #expect(try p.deviceRemoval(deviceID: id)?.keyCleanupPending == true)
    #expect(try p.deviceRecords().first?.keyReady == true)
    f.secrets.failAccount = nil
    let reopened = try f.profile(), receipt = try reopened.finishRemovedDeviceKeyCleanup(deviceID: id)
    #expect(!receipt.keyCleanupPending && receipt.relayDeletionPending && receipt.rotationPending)
    #expect(try f.secrets.read(account: p.pairingAccount(id)) == nil)
    #expect(try f.secrets.read(account: p.createdAccount(id)) == nil)
    #expect(try reopened.deviceRecords().first?.keyReady == false)
    #expect(try reopened.store.read { try $0.rows("SELECT ephemeral_cleanup FROM pairings") } == [[.integer(0)]])
    #expect(try reopened.currentAccount()?.key.withUnsafeBytes { Data($0) } == account)
}

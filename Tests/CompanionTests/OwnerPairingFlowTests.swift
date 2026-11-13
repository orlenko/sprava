import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class FlowClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "2026-10-15T11:50:00Z"
    func now() -> String { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: String) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
private final class FlowSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values.removeValue(forKey: account) }
}
private actor FlowClaimRelay: OwnerClaimTransport {
    func health() async throws -> CompanionRelayReply<CompanionRelayHealth> {
        CompanionRelayReply(status: 200, value: CompanionRelayHealth(instance: "0123456789abcdef0123456789abcdef", claimed: true))
    }
    func claim(_ body: Data) async throws -> Int { Issue.record("No claim allowed in this fixture"); return 409 }
}
private actor FlowRelay: OwnerPairingTransport {
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let id = CompanionWire.base64(Data(repeating: 21, count: 16))
    let secret = CompanionWire.base64(Data(repeating: 22, count: 16))
    private var starts: [(String, Data)] = []
    private var polls = 0
    private var createStatus = 200
    private var pollStatus = 200
    private var lost = false
    private var onPoll: @Sendable () -> Void = {}
    func failCreate() { lost = true }
    func status(create: Int = 200, poll: Int = 200) { createStatus = create; pollStatus = poll }
    func duringPoll(_ action: @escaping @Sendable () -> Void) { onPoll = action }
    func counts() -> (Int, Int) { (starts.count, polls) }
    func createPairing(deviceID: String, publicKey: Data) async throws -> CompanionRelayReply<CompanionCreatedPairing> {
        starts.append((deviceID, publicKey))
        if lost { lost = false; throw CompanionRelayError.invalid }
        return CompanionRelayReply(status: createStatus, value: createStatus == 200 ?
            CompanionCreatedPairing(id: id, secret: secret, expiresAt: "2099-01-01T00:00:00Z") : nil)
    }
    func phoneKey(_ kind: String, count: Int = 32) throws -> SymmetricKey {
        let (d, a) = try #require(starts.last)
        let shared = try phone.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: a))
        return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(id.utf8),
            sharedInfo: Data("sprava-companion/v0 \(kind)".utf8) + a + phone.publicKey.rawRepresentation +
                (try CompanionWire.decode(d)), outputByteCount: count)
    }
    func pairing(_ id: String) async throws -> CompanionRelayReply<CompanionRelayPairing> {
        polls += 1; onPoll()
        if pollStatus != 200 { return CompanionRelayReply(status: pollStatus, value: nil) }
        let (d, _) = try #require(starts.last)
        let base = JSONObject([("label", .string("Pocket")), ("pad", .string(""))])
        let pad = String(repeating: " ", count: 512 - JSONWriter.compact(.object(base)).utf8.count)
        let hello = try CompanionSealedObject.seal(name: "pairings/\(id)/hello", epoch: 0, key: phoneKey("wrap"),
            plaintext: Data(JSONWriter.compact(.object(JSONObject([("label", .string("Pocket")), ("pad", .string(pad))]))).utf8))
        return CompanionRelayReply(status: 200, value: CompanionRelayPairing(state: .joined,
            deviceID: d, publicKey: phone.publicKey.rawRepresentation, hello: hello))
    }
}
private struct FlowFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-pairing-flow-" + UUID().uuidString)
    let secrets = FlowSecrets()
    let clock = FlowClock()
    let relay = FlowRelay()
    let identity = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    func profile() throws -> CompanionProfile {
        try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: identity, secrets: secrets)
    }
    func prepare() throws {
        _ = try CompanionOwnerVault(backend: secrets).prepare(identity, setupCode: Data(repeating: 14, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
    }
    func flow() throws -> CompanionOwnerPairingFlow {
        let p = try profile(), c = try CompanionOwnerConnection(profile: p, transport: FlowClaimRelay())
        return CompanionOwnerPairingFlow(profile: p, connection: c, transport: relay, now: { clock.now() })
    }
}

@Test func pairingWaitsForExplicitApprovalAndThePhoneOpensTheDurablyRecordedDelivery() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let flow = try f.flow(), started = try await flow.start()
    #expect(started.deadline == "2026-10-15T12:00:00Z") // Relay-supplied 2099 cannot extend the lifetime.
    // A protected create result can survive without its SQLite reference after an interrupted capture.
    try f.profile().store.write { try $0.execute("DELETE FROM pairings WHERE device = ?", .text(started.deviceID)) }
    let restarted = try f.flow(), resumed = try #require(try await restarted.resume(deviceID: started.deviceID))
    #expect(resumed.created.secret == started.created.secret && resumed.ownerPublicKey == started.ownerPublicKey)
    #expect(await f.relay.counts().0 == 1)
    guard case .confirmation(let approval) = try await restarted.poll(deviceID: started.deviceID) else { Issue.record("Expected approval"); return }
    let code = try await f.relay.phoneKey("confirm", count: 4).withUnsafeBytes { Data($0) }
    #expect(approval.confirmation == String(format: "%06u", code.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) } % 1_000_000))
    #expect(try f.profile().pairingDelivery(deviceID: started.deviceID) == nil)
    #expect(try f.profile().deviceRecords().first?.state == .pairing)
    let delivery = try await restarted.confirm(approval)
    let owner = try #require(try CompanionOwnerVault(backend: f.secrets).load(f.identity))
    let wrapped = try CompanionSealedObject.open(name: "pairings/\(started.created.id)/key", epoch: 1,
        key: await f.relay.phoneKey("wrap"), bytes: delivery.wrappedKey)
    let keys = try CompanionSealedObject.open(name: delivery.keysName, epoch: 1, key: await f.relay.phoneKey("device"),
        bytes: delivery.deviceKeys, owner: owner.signingKey.publicKey)
    #expect(keys["account_key"] == wrapped["account_key"] && wrapped["device_id"]?.stringValue == started.deviceID)
}

@Test func anUnknownCreateResultIsAbandonedAndNeverPostedAgainAfterRestart() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    await f.relay.failCreate()
    let flow = try f.flow()
    await #expect(throws: CompanionRelayError.invalid) { try await flow.start() }
    let failed = try #require(try f.profile().deviceRecords().first)
    #expect(failed.state == .abandoned)
    #expect(try await f.flow().resume(deviceID: failed.deviceID) == nil)
    let new = try await flow.start()
    let createCount = await f.relay.counts().0
    #expect(new.deviceID != failed.deviceID && createCount == 2)
    // Simulate a crash after the durable attempt marker, before the HTTP result was recorded.
    let p = try f.profile(), pending = try p.reservePairing()
    try p.startPairingSchedule(pending.deviceID, now: f.clock.now())
    _ = try p.beginPairingCreation(deviceID: pending.deviceID)
    #expect(try await f.flow().resume(deviceID: pending.deviceID) == nil)
    #expect(try p.deviceRecords().first(where: { $0.deviceID == pending.deviceID })?.state == .abandoned)
    #expect(await f.relay.counts().0 == 2)
}

@Test func pollingIsPacedAcrossRestartAndExpiryDuringAReplyCannotShowAnApproval() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let flow = try f.flow(), started = try await flow.start()
    _ = try await flow.poll(deviceID: started.deviceID)
    guard case .waiting(let next) = try await f.flow().poll(deviceID: started.deviceID) else { Issue.record("Poll was not paced"); return }
    let pollCount = await f.relay.counts().1
    #expect(next == "2026-10-15T11:50:02Z" && pollCount == 1)
    f.clock.set("2026-10-15T11:50:02Z")
    await f.relay.duringPoll { f.clock.set("2026-10-15T12:00:00Z") }
    await #expect(throws: CompanionOwnerPairingError.expired) { try await flow.poll(deviceID: started.deviceID) }
    #expect(try f.profile().deviceRecords().first?.state == .abandoned)
    #expect(try f.profile().pairingDelivery(deviceID: started.deviceID) == nil)
}

@Test func aPairingTokenRefusalRetiresClaimAdmissionBeforeAnyFurtherOwnerCall() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let flow = try f.flow(), started = try await flow.start()
    await f.relay.status(poll: 401)
    await #expect(throws: CompanionPairingFlowError.relayRejected(401)) { try await flow.poll(deviceID: started.deviceID) }
    #expect(try f.profile().ownerClaimState() == .needsReset)
    await #expect(throws: CompanionPairingFlowError.ownerUnavailable(.needsReset)) { try await flow.start() }
    #expect(await f.relay.counts().0 == 1)
}

@Test func anApprovalCannotActivateAfterTheLocalDeadlineEvenWhenTheRelayClaimsItIsValid() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let flow = try f.flow(), started = try await flow.start()
    guard case .confirmation(let approval) = try await flow.poll(deviceID: started.deviceID) else { Issue.record("Expected approval"); return }
    f.clock.set("2026-10-15T12:00:00Z")
    await #expect(throws: CompanionOwnerPairingError.expired) { try await flow.confirm(approval) }
    #expect(try f.profile().pairingDelivery(deviceID: started.deviceID) == nil)
    #expect(try f.profile().deviceRecords().first?.state == .abandoned)
}

@Test func restartingRestoresThePinnedCodeWithoutAnotherRelayPollOrImplicitApproval() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let flow = try f.flow(), started = try await flow.start()
    #expect(try await flow.approval(deviceID: started.deviceID) == nil)
    guard case .confirmation(let first) = try await flow.poll(deviceID: started.deviceID) else { Issue.record("Expected approval"); return }
    let restarted = try f.flow()
    let restored = try #require(try await restarted.approval(deviceID: started.deviceID))
    #expect(restored.deviceID == first.deviceID && restored.pairingID == first.pairingID)
    #expect(restored.label == first.label && restored.confirmation == first.confirmation && restored.digest == first.digest)
    #expect(await f.relay.counts().1 == 1)
    #expect(try f.profile().deviceRecords().first?.state == .pairing)
    #expect(try f.profile().pairingDelivery(deviceID: started.deviceID) == nil)
    _ = try await restarted.confirm(restored)
    #expect(try f.profile().deviceRecords().first?.state == .active)
    #expect(try await restarted.approval(deviceID: started.deviceID) == nil)
}

@Test func aRecordedPairingCodeCannotBeRestoredAfterExpiryOrOwnerRefusal() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let flow = try f.flow(), started = try await flow.start()
    _ = try await flow.poll(deviceID: started.deviceID)
    f.clock.set(started.deadline)
    await #expect(throws: CompanionOwnerPairingError.expired) { try await f.flow().approval(deviceID: started.deviceID) }
    #expect(try f.profile().deviceRecords().first?.state == .abandoned)
    #expect(try f.profile().pairingDelivery(deviceID: started.deviceID) == nil)

    let refused = FlowFixture(); defer { try? FileManager.default.removeItem(at: refused.folder) }; try refused.prepare()
    let refusedFlow = try refused.flow(), pending = try await refusedFlow.start()
    _ = try await refusedFlow.poll(deviceID: pending.deviceID)
    try refused.profile().recordClaimState(.needsReset)
    await #expect(throws: CompanionPairingFlowError.ownerUnavailable(.needsReset)) { try await refused.flow().approval(deviceID: pending.deviceID) }
    #expect(try refused.profile().pairingDelivery(deviceID: pending.deviceID) == nil)
}

@Test func aChangedRecordedApprovalIsRefusedWithoutOverwritingItsTranscript() async throws {
    let f = FlowFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let flow = try f.flow(), started = try await flow.start()
    _ = try await flow.poll(deviceID: started.deviceID)
    let changed = CompanionWire.base64(Data(repeating: 77, count: 32))
    try f.profile().store.write { try $0.execute("UPDATE pairings SET approval = ? WHERE device = ?", .text(changed), .text(started.deviceID)) }
    await #expect(throws: CompanionOwnerPairingError.invalid) { try await f.flow().approval(deviceID: started.deviceID) }
    let stored = try f.profile().store.read { try $0.rows("SELECT approval FROM pairings WHERE device = ?", .text(started.deviceID)).first?.first?.text }
    #expect(stored == changed)
    #expect(try f.profile().deviceRecords().first?.state == .pairing)
    #expect(try f.profile().pairingDelivery(deviceID: started.deviceID) == nil)
}

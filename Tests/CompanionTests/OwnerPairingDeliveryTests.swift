import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class DeliveryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = "2026-10-15T11:50:00Z"
    func now() -> String { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ value: String) { lock.lock(); defer { lock.unlock() }; self.value = value }
}
private final class DeliverySecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Data] = [:]
    var failRemove = false
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemove { throw CompanionCredentialError.unavailable }
        values.removeValue(forKey: account)
    }
}
private actor DeliveryClaimRelay: OwnerClaimTransport {
    private var healthCalls = 0
    func count() -> Int { healthCalls }
    func health() async throws -> CompanionRelayReply<CompanionRelayHealth> {
        healthCalls += 1
        return CompanionRelayReply(status: 200, value: CompanionRelayHealth(instance: "0123456789abcdef0123456789abcdef", claimed: true))
    }
    func claim(_ body: Data) async throws -> Int { Issue.record("No claim expected"); return 409 }
}
private actor DeliveryRelay: OwnerDeliveryTransport {
    enum Step: Sendable { case keys(Int), wrap(Int), state(CompanionRelayPairing.State), stateStatus(Int), lostKeys, lostWrap }
    private var plans: [Step]
    private var calls: [String] = []
    private var keys: [Data] = []
    private var wraps: [Data] = []
    init(_ plans: [Step]) { self.plans = plans }
    func snapshot() -> ([String], [Data], [Data]) { (calls, keys, wraps) }
    func putObject(name: String, bytes: Data) async throws -> Int {
        calls.append("keys"); keys.append(bytes)
        guard !plans.isEmpty else { throw CompanionRelayError.invalid }
        switch plans.removeFirst() {
        case .keys(let code): return code
        case .lostKeys: throw CompanionRelayError.invalid
        default: Issue.record("Unexpected keys upload"); throw CompanionRelayError.invalid
        }
    }
    func deliverKey(pairingID: String, bytes: Data) async throws -> Int {
        calls.append("wrap"); wraps.append(bytes)
        guard !plans.isEmpty else { throw CompanionRelayError.invalid }
        switch plans.removeFirst() {
        case .wrap(let code): return code
        case .lostWrap: throw CompanionRelayError.invalid
        default: Issue.record("Wrapped key arrived before keys"); throw CompanionRelayError.invalid
        }
    }
    func pairingState(_ id: String) async throws -> CompanionRelayReply<CompanionRelayPairing.State> {
        calls.append("state")
        guard !plans.isEmpty else { throw CompanionRelayError.invalid }
        switch plans.removeFirst() {
        case .state(let state): return CompanionRelayReply(status: 200, value: state)
        case .stateStatus(let code): return CompanionRelayReply(status: code, value: nil)
        default: Issue.record("Unexpected state poll"); throw CompanionRelayError.invalid
        }
    }
}
private struct DeliveryFixture {
    let folder: URL
    let secrets = DeliverySecrets(), clock = DeliveryClock()
    let profile: CompanionProfile
    let delivery: CompanionPairingDelivery
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-pairing-delivery-" + UUID().uuidString)
        let relay = try CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
        let owner = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 15, count: 32).base64EncodedString())
        profile = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
        _ = try profile.prepareAccount(); try profile.recordClaimState(.claimed)
        let r = try profile.reservePairing(), phone = Curve25519.KeyAgreement.PrivateKey()
        try profile.startPairingSchedule(r.deviceID, now: clock.now())
        _ = try profile.beginPairingCreation(deviceID: r.deviceID)
        let p = CompanionWire.base64(Data(repeating: 11, count: 16))
        try profile.captureCreatedPairing(deviceID: r.deviceID, created: CompanionCreatedPairing(id: p,
            secret: CompanionWire.base64(Data(repeating: 12, count: 16)), expiresAt: "2026-10-15T12:00:00Z"))
        let z = try phone.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: r.ownerPublicKey))
        let w = z.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(p.utf8), sharedInfo: Data("sprava-companion/v0 wrap".utf8) +
            r.ownerPublicKey + phone.publicKey.rawRepresentation + (try CompanionWire.decode(r.deviceID)), outputByteCount: 32)
        let base = JSONObject([("label", .string("Pocket")), ("pad", .string(""))])
        let pad = String(repeating: " ", count: 512 - JSONWriter.compact(.object(base)).utf8.count)
        let hello = try CompanionSealedObject.seal(name: "pairings/\(p)/hello", epoch: 0, key: w,
            plaintext: Data(JSONWriter.compact(.object(JSONObject([("label", .string("Pocket")), ("pad", .string(pad))]))).utf8))
        let approval = try #require(try profile.observePairing(deviceID: r.deviceID, response: CompanionRelayPairing(state: .joined,
            deviceID: r.deviceID, publicKey: phone.publicKey.rawRepresentation, hello: hello)))
        delivery = try profile.confirmPairing(approval, credentials: owner, now: clock.now())
    }
    func worker(_ relay: DeliveryRelay, claim: DeliveryClaimRelay = DeliveryClaimRelay(),
                recoverRefusals: Bool = true) throws -> CompanionOwnerPairingDelivery {
        let p = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: profile.relay, secrets: secrets)
        let c = try CompanionOwnerConnection(profile: p, transport: claim)
        return CompanionOwnerPairingDelivery(profile: p, connection: c, transport: relay, now: { clock.now() }, recoverRefusals: recoverRefusals)
    }
}

@Test func deliveryRetriesExactBytesInOrderAndRestartedAcknowledgmentCleanupDoesNotLoseKd() async throws {
    let f = try DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let relay = DeliveryRelay([.lostKeys, .keys(204), .lostWrap, .wrap(204), .state(.keyed), .state(.acknowledged)])
    let first = try f.worker(relay), d = f.delivery.deviceID
    await #expect(throws: CompanionRelayError.invalid) { try await first.step(deviceID: d) }
    guard case .waiting(let next) = try await f.worker(relay).step(deviceID: d) else { Issue.record("Retry was not paced"); return }
    #expect(next == "2026-10-15T11:50:02Z")
    f.clock.set(next)
    await #expect(throws: CompanionRelayError.invalid) { try await f.worker(relay).step(deviceID: d) }
    f.clock.set("2026-10-15T11:50:06Z")
    guard case .waiting(let ackAt) = try await f.worker(relay).step(deviceID: d) else { Issue.record("Expected acknowledgment wait"); return }
    #expect(ackAt == "2026-10-15T11:50:08Z")
    f.clock.set(ackAt); f.secrets.failRemove = true
    await #expect(throws: CompanionCredentialError.unavailable) { try await f.worker(relay).step(deviceID: d) }
    #expect(try f.profile.pairingDelivery(deviceID: d)?.acknowledged == true)
    f.secrets.failRemove = false
    guard case .acknowledged = try await f.worker(relay).step(deviceID: d) else { Issue.record("Cleanup did not resume"); return }
    let (calls, keys, wraps) = await relay.snapshot()
    #expect(calls == ["keys", "keys", "wrap", "wrap", "state", "state"])
    #expect(keys == [f.delivery.deviceKeys, f.delivery.deviceKeys] && wraps == [f.delivery.wrappedKey, f.delivery.wrappedKey])
    #expect(f.secrets.values[f.profile.deviceAccount(d)] != nil)
    #expect(f.secrets.values[f.profile.pairingAccount(d)] == nil && f.secrets.values[f.profile.createdAccount(d)] == nil)
}

@Test func conflictingUploadsBlockDurablyWithoutSendingAWrappedKeyOrRegeneratingAnything() async throws {
    for code in [409, 410] {
        let f = try DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        let relay = DeliveryRelay([.keys(code)]), d = f.delivery.deviceID
        await #expect(throws: CompanionPairingDeliveryError.conflict(code)) { try await f.worker(relay).step(deviceID: d) }
        f.clock.set("2026-10-15T11:50:05Z")
        await #expect(throws: CompanionPairingDeliveryError.conflict(code)) { try await f.worker(relay).step(deviceID: d) }
        #expect(await relay.snapshot().0 == ["keys"])
        #expect(try f.profile.pairingDelivery(deviceID: d)?.deviceKeys == f.delivery.deviceKeys)
        #expect(try f.profile.deviceRecords().first?.state == .active)
    }
}

@Test func expiryForgetsOnlyEphemeralSecretsAndARefusedTokenStopsLaterDeliveryCalls() async throws {
    for expired in [false, true] {
        let f = try DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        let relay = DeliveryRelay(expired ? [] : [.keys(401)]), d = f.delivery.deviceID
        if expired {
            f.clock.set("2026-10-15T12:00:00Z")
            guard case .notConfirmed = try await f.worker(relay).step(deviceID: d) else { Issue.record("Expected expiry"); return }
            #expect(f.secrets.values[f.profile.pairingAccount(d)] == nil)
        } else {
            await #expect(throws: CompanionPairingFlowError.relayRejected(401)) { try await f.worker(relay).step(deviceID: d) }
            await #expect(throws: CompanionPairingFlowError.ownerUnavailable(.needsReset)) { try await f.worker(relay).step(deviceID: d) }
        }
        #expect(f.secrets.values[f.profile.deviceAccount(d)] != nil)
        #expect(try f.profile.deviceRecords().first?.state == .active)
        #expect(await relay.snapshot().0 == (expired ? [] : ["keys"]))
    }
}


@Test(arguments: [0, 1, 2])
func deliveryCanDeferRefusalRecoveryWithoutLosingRecordedBytes(stage: Int) async throws {
    let f = try DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let plans: [[DeliveryRelay.Step]] = [
        [.keys(401)], [.keys(204), .wrap(401)], [.keys(204), .wrap(204), .stateStatus(401)],
    ]
    let relay = DeliveryRelay(plans[stage]), claim = DeliveryClaimRelay(), d = f.delivery.deviceID
    let worker = try f.worker(relay, claim: claim, recoverRefusals: false)
    await #expect(throws: CompanionPairingFlowError.relayRejected(401)) { try await worker.step(deviceID: d) }
    #expect(await claim.count() == 0)
    let reopened = try CompanionProfile(database: f.folder.appendingPathComponent("state.sqlite"),
                                       relay: f.profile.relay, secrets: f.secrets)
    #expect(try reopened.ownerClaimState() == .checkingRefusal)
    let retained = try #require(try reopened.pairingDelivery(deviceID: d))
    #expect(retained.deviceKeys == f.delivery.deviceKeys && retained.wrappedKey == f.delivery.wrappedKey)
    #expect(!retained.acknowledged)
    #expect(try reopened.deviceRecords().first?.state == .active)
    #expect(f.secrets.values[f.profile.deviceAccount(d)] != nil)
    f.clock.set("2026-10-15T11:50:10Z")
    let restarted = try f.worker(relay, claim: claim, recoverRefusals: false)
    await #expect(throws: CompanionPairingFlowError.ownerUnavailable(.checkingRefusal)) {
        try await restarted.step(deviceID: d)
    }
    #expect(await claim.count() == 0)
    let sent = await relay.snapshot()
    #expect(sent.0 == Array(["keys", "wrap", "state"].prefix(stage + 1)))
    #expect(sent.1 == [f.delivery.deviceKeys])
    #expect(sent.2 == (stage == 0 ? [] : [f.delivery.wrappedKey]))
}

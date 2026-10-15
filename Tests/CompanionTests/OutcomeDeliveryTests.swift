import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class DeliverySecrets: CompanionCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private final class DeliveryClock: @unchecked Sendable { var value = "2026-10-15T12:00:00Z" }
private actor OutcomeTransport: OwnerPublicationTransport {
    var statuses: [Int]
    var calls: [(String, Data)] = []
    let paused: Bool
    var waiter: CheckedContinuation<Void, Never>?
    var response: CheckedContinuation<Int, Never>?
    init(_ statuses: [Int], paused: Bool = false) { self.statuses = statuses; self.paused = paused }
    func putObject(name: String, bytes: Data) async throws -> Int {
        calls.append((name, bytes)); waiter?.resume(); waiter = nil
        if paused { return await withCheckedContinuation { response = $0 } }
        guard !statuses.isEmpty else { throw URLError(.timedOut) }
        return statuses.removeFirst()
    }
    func started() async { if calls.isEmpty { await withCheckedContinuation { waiter = $0 } } }
    func release() { response?.resume(returning: 204); response = nil }
    func recorded() -> [(String, Data)] { calls }
}
private struct DeliveryFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-outcome-delivery-" + UUID().uuidString)
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    let secrets = DeliverySecrets()
    let clock = DeliveryClock()
    let device = CompanionWire.base64(Data(repeating: 73, count: 16))
    func profile() throws -> CompanionProfile { try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets) }
    func prepare() throws -> CompanionProfile {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 19, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(device)) }
        _ = try secrets.insert(account: p.deviceAccount(device), bytes: Data(repeating: 74, count: 32))
        return p
    }
    func decide(_ p: CompanionProfile, _ seq: Int64) throws {
        let r = CompanionWire.base64(Data(repeating: UInt8(seq), count: 16))
        let request = CompanionAuthenticatedRequest(deviceID: device, requestID: r, epoch: 1, sequence: seq, action: nil)
        guard case .deciding(let intent) = try p.beginDecision(request, today: "2026-10-15", now: clock.value) else { throw CompanionDecisionError.invalid }
        _ = try p.finishDecision(intent, today: "2026-10-15", decidedAt: clock.value)
    }
    func publisher(_ p: CompanionProfile, _ transport: OutcomeTransport) -> CompanionOwnerPublication {
        CompanionOwnerPublication(profile: p, transport: transport, now: { clock.value })
    }
}

@Test func outcomeDeliveryRetriesRecordedCiphertextAfterRestartAndPublishesNewerDecisionsOnTheNextCall() async throws {
    let f = DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try f.decide(p, 1)
    let lost = OutcomeTransport([])
    do { _ = try await f.publisher(p, lost).uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value); Issue.record("Expected lost reply") }
    catch let e as URLError { #expect(e.code == .timedOut) }
    let first = try #require(try p.pendingOutcomes(deviceID: f.device)); try f.decide(p, 2)
    let transport = OutcomeTransport([204, 204]), publisher = f.publisher(try f.profile(), transport)
    if case .waiting(let name, let next) = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value) {
        #expect(name == first.name && next == "2026-10-15T12:00:02Z")
    } else { Issue.record("Expected restart pacing") }
    #expect(await transport.recorded().isEmpty)
    f.clock.value = "2026-10-15T12:00:02Z"
    _ = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value)
    #expect(try p.store.read { try $0.rows("SELECT outcomes_generation, outcomes_built FROM decision_state") } == [[.integer(2), .integer(1)]])
    _ = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value)
    let calls = await transport.recorded(), lostCalls = await lost.recorded()
    #expect(calls.count == 2 && lostCalls.count == 1 && calls[0].1 == first.bytes && calls[0].1 == lostCalls[0].1)
    #expect(calls.map { $0.0 } == [first.name, "devices/" + f.device + "/outcomes/2"])
    if case .idle = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value) { }
    else { Issue.record("Clean outcomes must be idle") }
    #expect(await transport.recorded().count == 2)
}

@Test func outcomeConflictsRetireNamesAndOwnerRefusalSuspendsAllFurtherCalls() async throws {
    let f = DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try f.decide(p, 1)
    let transport = OutcomeTransport([409, 410, 401]), publisher = f.publisher(p, transport)
    for revision in [1, 2] {
        if case .superseded(let name) = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value) {
            #expect(name == "devices/" + f.device + "/outcomes/" + String(revision))
        } else { Issue.record("Expected retired revision") }
        #expect(await transport.recorded().count == revision)
    }
    do { _ = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value); Issue.record("Expected refusal") }
    catch CompanionOwnerConnectionError.relayRejected(401) { }
    let restarted = try f.profile()
    #expect(try restarted.ownerClaimState() == .checkingRefusal)
    do { _ = try await f.publisher(restarted, transport).uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value); Issue.record("Expected suspended owner") }
    catch CompanionPairingFlowError.ownerUnavailable(.checkingRefusal) { }
    #expect(await transport.recorded().count == 3)
}

@Test func outcomeUploadAllowsDecisionsDuringTheAwaitButCannotCompleteAfterRevocation() async throws {
    let f = DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try f.decide(p, 1)
    let transport = OutcomeTransport([], paused: true), publisher = f.publisher(p, transport)
    let upload = Task { try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value) }
    await transport.started()
    do { _ = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value); Issue.record("Expected busy uploader") }
    catch CompanionOwnerConnectionError.busy { }
    try f.decide(p, 2)
    try p.store.write { try $0.execute("UPDATE devices SET state = 'revoked'") }
    f.secrets.values.removeValue(forKey: p.deviceAccount(f.device))
    await transport.release()
    if case .superseded = try await upload.value { } else { Issue.record("Revocation must refuse completion") }
    #expect(try p.store.read { try $0.rows("SELECT outcomes_generation, outcomes_built FROM decision_state") } == [[.integer(2), .integer(0)]])
    if case .idle = try await f.publisher(try f.profile(), transport).uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value) { }
    else { Issue.record("Revoked device must not retry") }
    #expect(await transport.recorded().count == 1)
}

@Test func epochZeroOutcomeDeliveryRemainsAvailableWhileARevokedRecipientBlocksAccountEpochPublication() async throws {
    let f = DeliveryFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try f.decide(p, 1)
    let other = CompanionWire.base64(Data(repeating: 75, count: 16))
    try p.store.write { t in
        try t.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'revoked', 0, 1, 0)", .text(other))
        try t.execute("INSERT INTO recipients VALUES (1, ?)", .text(other))
    }
    let transport = OutcomeTransport([204]), publisher = f.publisher(p, transport)
    if case .uploaded = try await publisher.uploadOutcomes(deviceID: f.device, generatedAt: f.clock.value) { }
    else { Issue.record("Active device outcomes use only its immutable key") }
    do { _ = try await publisher.uploadIndex(generatedAt: f.clock.value); Issue.record("Expected blocked account epoch") }
    catch CompanionPublicationError.unavailable { }
    #expect(await transport.recorded().count == 1)
}

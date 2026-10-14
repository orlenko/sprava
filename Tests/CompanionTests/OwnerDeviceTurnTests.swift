import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private func turnID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }
private let turnDevice = turnID(91), turnAt = "2026-10-15T12:00:00Z", turnDay = "2026-10-15"
private func turnPlan(_ request: CompanionAuthenticatedRequest) -> CompanionDecisionPlan {
    let id = UUID().uuidString.lowercased()
    let event = JSONValue.obj([("id", .string(id)), ("text", .str("Invented note")),
        ("extensions", .obj([("sprava", .obj([("companion", .obj([
            ("device_id", .string(request.deviceID)), ("request_id", .string(request.requestID))]))]))]))])
    return CompanionDecisionPlan(outcome: .applied, effect: .capture(id: id, bytes: Data(JSONWriter.compact(event).utf8)))
}
private enum TurnFixtureError: Error, Equatable { case disk }
private final class TurnSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
private struct TurnFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-device-turn-" + UUID().uuidString)
    let key = SymmetricKey(data: Data(repeating: 92, count: 32))
    func prepare() throws -> CompanionProfile {
        let p = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"),
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: TurnSecrets())
        _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(turnDevice)) }
        _ = try p.secrets.insert(account: p.deviceAccount(turnDevice), bytes: key.withUnsafeBytes { Data($0) })
        return p
    }
    func body(_ id: UInt8, sequence: Int64) throws -> Data {
        let fields: [(String, JSONValue)] = [("type", .str("note")), ("seq", .number(JSONNumber(text: String(sequence)))),
            ("made_at", .string(turnAt)), ("text", .str("Invented note"))]
        let size = JSONWriter.compact(.obj(fields + [("pad", .str(""))])).utf8.count
        let payload = JSONValue.obj(fields + [("pad", .string(String(repeating: " ", count: 1024 - size)))])
        return try CompanionSealedObject.seal(name: "requests/\(turnDevice)/\(turnID(id))", epoch: 1,
            key: key, plaintext: Data(JSONWriter.compact(payload).utf8))
    }
    func request(_ id: UInt8, sequence: Int64 = 1) -> CompanionAuthenticatedRequest {
        CompanionAuthenticatedRequest(deviceID: turnDevice, requestID: turnID(id), epoch: 1, sequence: sequence,
            action: CompanionRequestedAction(kind: .note, madeAt: turnAt, binderID: nil, itemID: nil,
                seenVersion: nil, date: nil, text: "Invented note"))
    }
}
private actor TurnPause {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { continuation in
            release = continuation; entered = true; observer?.resume(); observer = nil
        }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func open() { release?.resume(); release = nil }
}
private actor TurnTransport: RequestCollectionTransport {
    let profile: CompanionProfile
    var entries: [CompanionListedRequest]
    let bodies: [String: Data]
    var statuses: [Int]
    let deleteBytes: Int
    let refuseAfterFetch: Bool
    let pause: TurnPause?
    var calls: [String] = []
    init(profile: CompanionProfile, entries: [UInt8], bodies: [String: Data], statuses: [Int] = [],
         deleteBytes: Int = 0, refuseAfterFetch: Bool = false, pause: TurnPause? = nil) {
        self.profile = profile; self.bodies = bodies; self.statuses = statuses
        self.deleteBytes = deleteBytes; self.refuseAfterFetch = refuseAfterFetch; self.pause = pause
        self.entries = entries.enumerated().map { CompanionListedRequest(requestID: turnID($0.element), ordinal: Int64($0.offset + 1), receivedAt: turnAt) }
    }
    func listRequests(deviceID: String, after: Int64?, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestPage> {
        calls.append("list"); if let pause { await pause.pause() }
        return CompanionRelayReply(status: 200, value: CompanionRequestPage(requests: entries, next: nil), receivedBytes: 100)
    }
    func fetchRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestDownload> {
        calls.append("get:" + requestID)
        if refuseAfterFetch { try profile.recordClaimState(.checkingRefusal) }
        let bytes = try #require(bodies[requestID])
        return CompanionRelayReply(status: 200, value: .body(bytes), receivedBytes: bytes.count)
    }
    func deleteRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        calls.append("delete:" + requestID)
        guard case .decided = try profile.decisionStatus(deviceID: deviceID, requestID: requestID) else {
            Issue.record("Request deleted without durable outcome"); throw TurnFixtureError.disk
        }
        let status = statuses.isEmpty ? 204 : statuses.removeFirst()
        if status == 204 { entries.removeAll { $0.requestID == requestID } }
        return CompanionRelayReply(status: status, value: nil, receivedBytes: status == 204 ? deleteBytes : 7)
    }
    func recorded() -> [String] { calls }
}
private final class TurnAdapter: CompanionDecisionAdapter, @unchecked Sendable {
    let profile: CompanionProfile
    let blocked: String?
    let diskFailure: Bool
    private let lock = NSLock()
    private var applied: [String] = []
    init(_ profile: CompanionProfile, blocked: String? = nil, diskFailure: Bool = false) {
        self.profile = profile; self.blocked = blocked; self.diskFailure = diskFailure
    }
    func recorded() -> [String] { lock.lock(); defer { lock.unlock() }; return applied }
    private func check(_ requestID: String) throws {
        if blocked == requestID { throw CompanionDeviceDecisionFailure.binderUnavailable }
        if diskFailure { throw TurnFixtureError.disk }
    }
    private func apply(_ record: CompanionDecisionRecord) throws {
        #expect(try profile.pendingDecision(deviceID: turnDevice)?.bytes == record.bytes)
        lock.lock(); defer { lock.unlock() }; applied.append(record.request.requestID)
    }
    func withPreparedDecision<Result>(for request: CompanionAuthenticatedRequest,
        _ body: (CompanionDecisionPlan, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        try check(request.requestID); return try body(turnPlan(request), apply)
    }
    func withRecoveredDecision<Result>(for record: CompanionDecisionRecord,
        _ body: (CompanionDecisionProof, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        try check(record.request.requestID); return try body(.idempotent, apply)
    }
}

@Test func deviceTurnDecidesInSequenceOrderAndNeverDeletesBeforeDurableCommit() async throws {
    let f = TurnFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let a = try f.body(1, sequence: 2), b = try f.body(2, sequence: 1)
    let transport = TurnTransport(profile: p, entries: [1, 2], bodies: [turnID(1): a, turnID(2): b])
    let adapter = TurnAdapter(p)
    let result = try await CompanionOwnerDeviceTurn(profile: p, locks: CompanionDeviceDecisionLocks(), transport: transport)
        .run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: adapter)
    #expect(result.jobFailure == nil && !result.needsRetry && result.decisionsCommitted == 2)
    #expect(result.fetches == 2 && result.checkedRequests == 2 && result.downloadedBytes == 100 + a.count + b.count)
    #expect(adapter.recorded() == [turnID(2), turnID(1)])
    #expect(await transport.recorded() == ["list", "get:" + turnID(1), "get:" + turnID(2), "delete:" + turnID(2), "delete:" + turnID(1)])
}

@Test func aPendingDeviceDecisionRecoversBeforeListingAndItsFailureStopsCollection() async throws {
    for blocked in [false, true] {
        let f = TurnFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
        let request = f.request(1)
        _ = try p.beginDecision(request, plan: turnPlan(request), today: turnDay, now: turnAt)
        let transport = TurnTransport(profile: p, entries: [1], bodies: [:])
        let adapter = TurnAdapter(p, blocked: blocked ? turnID(1) : nil)
        let result = try await CompanionOwnerDeviceTurn(profile: p, locks: CompanionDeviceDecisionLocks(), transport: transport)
            .run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: adapter)
        #expect(result.jobFailure == nil && result.needsRetry == blocked && result.decisionsCommitted == (blocked ? 0 : 1))
        #expect(await transport.recorded() == (blocked ? [] : ["delete:" + turnID(1), "list"]))
        #expect((try p.pendingDecision(deviceID: turnDevice) != nil) == blocked)
    }
}

@Test func aBinderFailureLeavesEveryLaterRequestUndecidedAndRetainsEarlierProgress() async throws {
    let f = TurnFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let transport = TurnTransport(profile: p, entries: [1, 2, 3], bodies: [turnID(1): try f.body(1, sequence: 1),
        turnID(2): try f.body(2, sequence: 2), turnID(3): try f.body(3, sequence: 3)])
    let adapter = TurnAdapter(p, blocked: turnID(2))
    let result = try await CompanionOwnerDeviceTurn(profile: p, locks: CompanionDeviceDecisionLocks(), transport: transport)
        .run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: adapter)
    #expect(result.needsRetry && result.jobFailure == nil && result.decisionsCommitted == 1 && result.checkedRequests == 3)
    #expect(adapter.recorded() == [turnID(1)])
    for id in [2, 3] { if case .none = try p.decisionStatus(deviceID: turnDevice, requestID: turnID(UInt8(id))) {} else { Issue.record("Later request was decided") } }
}

@Test func failedDeletionReturnsCommittedProgressAndTheNextTurnDeletesWithoutRepeatingTheEffect() async throws {
    let f = TurnFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let transport = TurnTransport(profile: p, entries: [1, 2], bodies: [turnID(1): try f.body(1, sequence: 1),
        turnID(2): try f.body(2, sequence: 2)], statuses: [500])
    let adapter = TurnAdapter(p)
    let turn = CompanionOwnerDeviceTurn(profile: p, locks: CompanionDeviceDecisionLocks(), transport: transport)
    let first = try await turn.run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: adapter)
    #expect(first.jobFailure as? CompanionOwnerConnectionError == .relayRejected(500))
    #expect(first.decisionsCommitted == 1 && !first.needsRetry)
    let second = try await turn.run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: adapter)
    #expect(second.jobFailure == nil && second.decisionsCommitted == 1 && second.fetches == 1)
    #expect(adapter.recorded() == [turnID(1), turnID(2)])
    #expect(await transport.recorded().filter { $0 == "get:" + turnID(1) }.count == 1)
}

@Test func recoveryDeletionUsesTheSharedDownloadBudgetAndDoesNotListAfterItIsSpent() async throws {
    let f = TurnFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let request = f.request(1)
    _ = try p.beginDecision(request, plan: turnPlan(request), today: turnDay, now: turnAt)
    let transport = TurnTransport(profile: p, entries: [1], bodies: [:], deleteBytes: 2)
    let result = try await CompanionOwnerDeviceTurn(profile: p, locks: CompanionDeviceDecisionLocks(), transport: transport)
        .run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(downloadBytes: 2), now: { turnAt }, adapter: TurnAdapter(p))
    #expect(result.jobFailure == nil && result.decisionsCommitted == 1 && result.downloadedBytes == 2)
    #expect(await transport.recorded() == ["delete:" + turnID(1)])
}

@Test func ownerRefusalDuringCollectionPreventsEffectsAndDiskErrorsAreJobFailures() async throws {
    for refusal in [false, true] {
        let f = TurnFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
        let transport = TurnTransport(profile: p, entries: [1], bodies: [turnID(1): try f.body(1, sequence: 1)], refuseAfterFetch: refusal)
        let adapter = TurnAdapter(p, diskFailure: !refusal)
        let result = try await CompanionOwnerDeviceTurn(profile: p, locks: CompanionDeviceDecisionLocks(), transport: transport)
            .run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: adapter)
        #expect(result.jobFailure != nil && !result.needsRetry && result.decisionsCommitted == 0 && adapter.recorded().isEmpty)
        #expect(await transport.recorded() == ["list", "get:" + turnID(1)])
    }
}

@Test func aDeviceTurnHoldsTheSharedLockWhileTheRelayIsSuspended() async throws {
    let f = TurnFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let locks = CompanionDeviceDecisionLocks(), pause = TurnPause()
    let turn = CompanionOwnerDeviceTurn(profile: p, locks: locks, transport: TurnTransport(profile: p, entries: [], bodies: [:], pause: pause))
    let pending = Task { try await turn.run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: TurnAdapter(p)) }
    await pause.waitForEntry()
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await locks.withLock(deviceID: turnDevice) { Issue.record("Concurrent device mutation ran") } }
    let contending = try await turn.run(deviceID: turnDevice, allowance: CompanionCollectionAllowance(), now: { turnAt }, adapter: TurnAdapter(p))
    #expect(contending.needsRetry && contending.jobFailure == nil && contending.checkedRequests == 0)
    await pause.open(); #expect(try await pending.value.jobFailure == nil)
}

import Foundation
import Testing
@testable import Companion
import SpravaKit

private func executionID(_ n: UInt8) -> String { CompanionWire.base64(Data(repeating: n, count: 16)) }
private let executionDevice = executionID(81), executionBinder = executionID(82)
private let executionDay = "2026-10-15", executionAt = "2026-10-15T12:00:00Z"
private let effectA = "019a2000-0000-7000-8000-000000000011", effectB = "019a2000-0000-7000-8000-000000000012"
private enum ExecutionFixtureError: Error, Equatable { case interrupted }
private final class ExecutionSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
private struct ExecutionFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-execution-" + UUID().uuidString)
    let secrets = ExecutionSecrets()
    func profile() throws -> CompanionProfile {
        try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"),
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"), secrets: secrets)
    }
    func prepare() throws -> CompanionProfile {
        let p = try profile(); _ = try p.prepareAccount()
        try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(executionDevice)) }
        return p
    }
}
private func executionRequest(_ id: UInt8 = 83, seq: Int64 = 1, note: Bool = false, invalid: Bool = false) -> CompanionAuthenticatedRequest {
    CompanionAuthenticatedRequest(deviceID: executionDevice, requestID: executionID(id), epoch: 1, sequence: seq,
        action: invalid ? nil : CompanionRequestedAction(kind: note ? .note : .done, madeAt: "2099-01-01T00:00:00Z",
            binderID: note ? nil : executionBinder, itemID: note ? nil : .string("item"), seenVersion: note ? nil : 1,
            date: nil, text: note ? "Invented capture" : nil))
}
private func executionOperation(_ request: CompanionAuthenticatedRequest, id: String = effectA) -> CompanionDecisionPlan {
    let bytes = Data(JSONWriter.compact(.obj([("id", .string(id)), ("at", .string(executionAt)),
        ("actor", .obj([("kind", .str("user"))])), ("op", .str("complete")),
        ("args", .obj([("id", .str("item")), ("closed_at", .string(executionAt)), ("source", .str("user"))])),
        ("before_hash", .string(String(repeating: "1", count: 64))), ("after_hash", .string(String(repeating: "2", count: 64))),
        ("note", .string("companion:\(request.deviceID)/\(request.requestID)"))])).utf8)
    return CompanionDecisionPlan(outcome: .applied, effect: .operation(binderID: executionBinder, id: id, bytes: bytes))
}
private final class ExecutionAdapter: CompanionDecisionAdapter {
    var prepare: (CompanionAuthenticatedRequest) throws -> CompanionDecisionPlan = { executionOperation($0) }
    var proof: (CompanionDecisionRecord) throws -> CompanionDecisionProof = { _ in .applied }
    var apply: (CompanionDecisionRecord) throws -> Void = { _ in }
    var prepared = 0, recovered = 0, applications = 0
    func withPreparedDecision<Result>(for request: CompanionAuthenticatedRequest,
        _ body: (CompanionDecisionPlan, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        prepared += 1
        return try body(prepare(request), { self.applications += 1; try self.apply($0) })
    }
    func withRecoveredDecision<Result>(for record: CompanionDecisionRecord,
        _ body: (CompanionDecisionProof, (CompanionDecisionRecord) throws -> Void) throws -> Result) throws -> Result {
        recovered += 1
        return try body(proof(record), { self.applications += 1; try self.apply($0) })
    }
}

@Test func executionFlushesExactIntentBeforeApplyingAndOnlyCountsTheFirstCommit() throws {
    let f = ExecutionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), engine = CompanionDecisionExecution(profile: p), adapter = ExecutionAdapter()
    adapter.apply = { record throws -> Void in
        #expect(try p.pendingDecision(deviceID: executionDevice)?.bytes == record.bytes)
        #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(0)]])
        #expect(try p.store.read { try $0.rows("SELECT count(*) FROM outcome_tombstones") } == [[.integer(0)]])
    }
    let first = try engine.decide(executionRequest(), today: executionDay, now: executionAt, adapter: adapter)
    #expect(first.committed && first.outcome.outcome == .applied)
    let duplicate = try engine.decide(executionRequest(seq: 99), today: executionDay, now: executionAt, adapter: adapter)
    #expect(!duplicate.committed && duplicate.outcome.sequence == 1)
    #expect(adapter.prepared == 1 && adapter.applications == 1)
    #expect(try p.store.read { try $0.rows("SELECT count FROM decision_daily") } == [[.integer(1)]])
}

@Test func anInterruptedEffectRemainsRecoverableAfterRestartAndAnAppliedOpIsNeverAppliedAgain() throws {
    let f = ExecutionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), adapter = ExecutionAdapter()
    adapter.apply = { _ in throw ExecutionFixtureError.interrupted }
    #expect(throws: ExecutionFixtureError.interrupted) {
        try CompanionDecisionExecution(profile: p).decide(executionRequest(), today: executionDay, now: executionAt, adapter: adapter)
    }
    let reopened = try f.profile(), saved = try #require(try reopened.pendingDecision(deviceID: executionDevice))
    adapter.apply = { _ in Issue.record("A proven applied operation must not be repeated") }
    let result = try #require(try CompanionDecisionExecution(profile: reopened).recoverPending(deviceID: executionDevice,
        today: executionDay, now: executionAt, adapter: adapter))
    #expect(result.committed && result.outcome.outcome == .applied && saved.request.requestID == executionID(83))
    #expect(adapter.applications == 1 && adapter.recovered == 1)
    #expect(try reopened.pendingDecision(deviceID: executionDevice) == nil)
}

@Test func provenNotAppliedRecoveryRecordsANewEffectBeforeApplyingAndUncertainRecoveryWritesOnlyItsCard() throws {
    for uncertain in [false, true] {
        let f = ExecutionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        let p = try f.prepare(), request = executionRequest(), adapter = ExecutionAdapter()
        _ = try p.beginDecision(request, plan: executionOperation(request), today: executionDay, now: executionAt)
        let card = Data("{\"explanation\":\"Invented interrupted action\"}".utf8)
        adapter.proof = { _ in uncertain ? .uncertain(conflict: card) : .notApplied(executionOperation(request, id: effectB)) }
        adapter.apply = { record throws -> Void in
            #expect(try p.pendingDecision(deviceID: executionDevice)?.bytes == record.bytes)
            switch record.plan.effect {
            case .operation(_, let id, _): #expect(!uncertain && id == effectB)
            case .conflict(let bytes): #expect(uncertain && bytes == card)
            default: Issue.record("Recovery supplied the wrong effect")
            }
        }
        let result = try #require(try CompanionDecisionExecution(profile: p).recoverPending(deviceID: executionDevice,
            today: executionDay, now: executionAt, adapter: adapter))
        #expect(result.outcome.outcome == (uncertain ? .conflict : .applied) && adapter.applications == 1)
    }
}

@Test func staleRecoveryAndLostFreshReservationsNeverApplyTheWrongRecordedEffect() throws {
    let f = ExecutionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), request = executionRequest(), adapter = ExecutionAdapter(), engine = CompanionDecisionExecution(profile: p)
    adapter.prepare = { request in
        _ = try p.beginDecision(request, plan: executionOperation(request, id: effectB), today: executionDay, now: executionAt)
        return executionOperation(request)
    }
    #expect(throws: CompanionDecisionError.busy) { try engine.decide(request, today: executionDay, now: executionAt, adapter: adapter) }
    #expect(adapter.applications == 0)
    adapter.proof = { previous in
        _ = try p.recoverDecision(previous, recovery: .provenNotApplied(executionOperation(request)), now: executionAt)
        return .notApplied(executionOperation(request, id: effectB))
    }
    #expect(throws: CompanionDecisionError.busy) { try engine.recoverPending(deviceID: executionDevice, today: executionDay, now: executionAt, adapter: adapter) }
    #expect(adapter.applications == 0)
    let pending = try #require(try p.pendingDecision(deviceID: executionDevice))
    if case .operation(_, let id, _) = pending.plan.effect { #expect(id == effectA) } else { Issue.record("Expected unchanged newer intent") }
}

@Test func capturesAndConflictCardsRecoverIdempotentlyButThatProofIsRefusedForOperations() throws {
    for kind in 0..<3 {
        let f = ExecutionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        let p = try f.prepare(), request = executionRequest(note: kind == 0), adapter = ExecutionAdapter()
        let bytes = Data(JSONWriter.compact(.obj([("id", .string(effectA)), ("text", .str("Invented capture")),
            ("extensions", .obj([("sprava", .obj([("companion", .obj([("device_id", .string(executionDevice)),
                ("request_id", .string(request.requestID))]))]))]))])).utf8)
        let plan = kind == 0 ? CompanionDecisionPlan(outcome: .applied, effect: .capture(id: effectA, bytes: bytes)) :
            kind == 1 ? CompanionDecisionPlan(outcome: .conflict, effect: .conflict(bytes: bytes)) : executionOperation(request)
        _ = try p.beginDecision(request, plan: plan, today: executionDay, now: executionAt)
        adapter.proof = { _ in .idempotent }
        adapter.apply = { record throws -> Void in #expect(try p.pendingDecision(deviceID: executionDevice)?.bytes == record.bytes) }
        let engine = CompanionDecisionExecution(profile: p)
        if kind == 2 {
            #expect(throws: CompanionDecisionError.invalid) { try engine.recoverPending(deviceID: executionDevice, today: executionDay, now: executionAt, adapter: adapter) }
            #expect(adapter.applications == 0)
            #expect(try p.pendingDecision(deviceID: executionDevice) != nil)
        } else {
            #expect(try engine.recoverPending(deviceID: executionDevice, today: executionDay, now: executionAt, adapter: adapter)?.outcome.outcome == plan.outcome)
            #expect(adapter.applications == 1)
            #expect(try engine.recoverPending(deviceID: executionDevice, today: executionDay, now: executionAt, adapter: adapter) == nil)
        }
    }
}

@Test func automaticRejectionsNeedNoAdapterAndFailedIntentOrCommitWritesNeverLoseRecovery() throws {
    let f = ExecutionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), adapter = ExecutionAdapter(), engine = CompanionDecisionExecution(profile: p)
    #expect(try engine.decide(executionRequest(invalid: true), today: executionDay, now: executionAt, adapter: adapter).outcome.outcome == .rejected)
    #expect(adapter.prepared == 0 && adapter.applications == 0)
    let request = executionRequest(84, seq: 2)
    try p.store.write { try $0.execute("CREATE TRIGGER fail_intent BEFORE INSERT ON request_decisions BEGIN SELECT RAISE(ABORT, 'invented failure'); END") }
    #expect(throws: (any Error).self) { try engine.decide(request, today: executionDay, now: executionAt, adapter: adapter) }
    #expect(adapter.applications == 0)
    #expect(try p.pendingDecision(deviceID: executionDevice) == nil)
    try p.store.write { try $0.execute("DROP TRIGGER fail_intent"); try $0.execute("CREATE TRIGGER fail_commit BEFORE INSERT ON outcome_tombstones BEGIN SELECT RAISE(ABORT, 'invented failure'); END") }
    #expect(throws: (any Error).self) { try engine.decide(request, today: executionDay, now: executionAt, adapter: adapter) }
    #expect(adapter.applications == 1)
    #expect(try p.pendingDecision(deviceID: executionDevice) != nil)
    try p.store.write { try $0.execute("DROP TRIGGER fail_commit") }
    #expect(try engine.recoverPending(deviceID: executionDevice, today: executionDay, now: executionAt, adapter: adapter)?.committed == true)
    #expect(adapter.applications == 1)
}

import Foundation
import Testing
@testable import Companion
import SpravaKit

private let journalDevice = CompanionWire.base64(Data(repeating: 61, count: 16))
private func journalID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }
private let journalDay = "2026-10-15", journalAt = "2026-10-15T12:00:00Z"
private final class JournalSecrets: CompanionCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private struct JournalFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-decisions-" + UUID().uuidString)
    let secrets = JournalSecrets()
    func profile() throws -> CompanionProfile {
        try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"),
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"), secrets: secrets)
    }
    func prepare() throws -> CompanionProfile {
        let p = try profile(); _ = try p.prepareAccount()
        try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(journalDevice)) }
        return p
    }
}
private func journalRequest(_ r: UInt8 = 62, seq: Int64 = 1, note: Bool = false, invalid: Bool = false) -> CompanionAuthenticatedRequest {
    let action = CompanionRequestedAction(kind: note ? .note : .done, madeAt: "2099-01-01T00:00:00Z",
        binderID: journalID(63), itemID: note ? nil : .string("item"), seenVersion: note ? nil : 1, date: nil, text: note ? "Invented note" : nil)
    return CompanionAuthenticatedRequest(deviceID: journalDevice, requestID: journalID(r), epoch: 1, sequence: seq, action: invalid ? nil : action)
}
private func deciding(_ lookup: CompanionDecisionLookup) throws -> CompanionDecisionRecord {
    guard case .deciding(let record) = lookup else { throw CompanionDecisionError.invalid }; return record
}
private let noChange = CompanionDecisionPlan(outcome: .applied, effect: .none)
private func operationPlan(_ request: CompanionAuthenticatedRequest, _ id: String) -> CompanionDecisionPlan {
    let bytes = Data(JSONWriter.compact(.object(JSONObject([("id", .string(id)), ("actor", .object(JSONObject([("kind", .string("user"))]))),
        ("op", .string("complete")), ("args", .object(JSONObject([("id", .string("item"))]))),
        ("note", .string("companion:\(request.deviceID)/\(request.requestID)"))]))).utf8)
    return CompanionDecisionPlan(outcome: .applied, effect: .operation(binderID: request.action!.binderID!, id: id, bytes: bytes))
}
private func capturePlan(_ request: CompanionAuthenticatedRequest, id: String = "019a2000-0000-7000-8000-000000000001") -> CompanionDecisionPlan {
    let bytes = Data(JSONWriter.compact(.object(JSONObject([
        ("id", .string(id)), ("text", .string(request.action!.text!)),
        ("extensions", .object(JSONObject([("sprava", .object(JSONObject([("companion", .object(JSONObject([
            ("device_id", .string(request.deviceID)), ("request_id", .string(request.requestID))])))])))])))
    ]))).utf8)
    return CompanionDecisionPlan(outcome: .applied, effect: .capture(id: id, bytes: bytes))
}

@Test func aDecisionSurvivesRestartWithExactEffectBytesAndOnlyItsCommitMovesReplayKnowledge() throws {
    let f = JournalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let request = journalRequest(note: true), record = try deciding(p.beginDecision(request, plan: capturePlan(request), today: journalDay, now: journalAt))
    let reopened = try f.profile(), pending = try #require(try reopened.pendingDecision(deviceID: journalDevice))
    #expect(pending.bytes == record.bytes && pending.request.action?.text == "Invented note")
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(0)]])
    let tombstone = try reopened.finishDecision(pending, today: journalDay, decidedAt: journalAt)
    #expect(tombstone.outcome == .applied && tombstone.sequence == 1)
    #expect(try p.pendingDecision(deviceID: journalDevice) == nil)
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(1)]])
    #expect(try p.store.read { try $0.rows("SELECT outcomes_generation FROM decision_state") } == [[.integer(1)]])
    #expect(try p.store.read { try $0.rows("SELECT count FROM decision_daily") } == [[.integer(1)]])
    #expect(try p.finishDecision(record, today: journalDay, decidedAt: "2026-10-15T12:01:00Z").decidedAt == journalAt)
    if case .decided(let duplicate) = try p.beginDecision(journalRequest(seq: 999), plan: noChange, today: journalDay, now: journalAt) {
        #expect(duplicate.sequence == 1 && duplicate.outcome == .applied)
    } else { Issue.record("A tombstone must never be replaced") }
    #expect(try p.store.read { try $0.rows("SELECT count FROM decision_daily") } == [[.integer(1)]])
}

@Test func theFirstIntentIsImmutableAndNoLaterRequestCanOvertakeIt() throws {
    let f = JournalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let first = try deciding(p.beginDecision(journalRequest(), plan: noChange, today: journalDay, now: journalAt))
    let duplicate = try deciding(p.beginDecision(journalRequest(seq: 99), plan: CompanionDecisionPlan(outcome: .conflict, effect: .conflict(bytes: Data("{}".utf8))), today: journalDay, now: journalAt))
    #expect(duplicate.bytes == first.bytes && duplicate.request.sequence == 1)
    #expect(throws: CompanionDecisionError.busy) { try p.beginDecision(journalRequest(64, seq: 2), plan: noChange, today: journalDay, now: journalAt) }
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(0)]])
}

@Test func authenticatedInvalidActionsGetARejectionWithoutTheirPayloadAndSequenceGapsAreAllowed() throws {
    let f = JournalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let record = try deciding(p.beginDecision(journalRequest(seq: 13, invalid: true), plan: noChange, today: journalDay, now: journalAt))
    #expect(record.plan.outcome == .rejected && record.request.action == nil)
    if case .rejection(.invalid) = record.plan.effect { } else { Issue.record("Invalid actions need an invalid rejection") }
    #expect(try p.finishDecision(record, today: journalDay, decidedAt: journalAt).sequence == 13)
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(13)]])
}

@Test func staleSequencesAreRejectedButSequencesBelowTheTombstoneFloorStayUnknownWithoutAnEffect() throws {
    let f = JournalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try p.store.write { try $0.execute("UPDATE devices SET highest_seq = 5") }
    let stale = try deciding(p.beginDecision(journalRequest(seq: 2), plan: noChange, today: journalDay, now: journalAt))
    if case .rejection(.staleSequence) = stale.plan.effect { } else { Issue.record("Expected replay rejection") }
    _ = try p.finishDecision(stale, today: journalDay, decidedAt: journalAt)
    // A future pruning seam raises this durable floor in the same transaction as deleting older tombstones.
    try p.store.write { try $0.execute("UPDATE decision_state SET tombstone_floor = 3") }
    let unknown = try deciding(p.beginDecision(journalRequest(64, seq: 1), plan: noChange, today: journalDay, now: journalAt))
    #expect(unknown.plan.outcome == .unknown)
    if case .none = unknown.plan.effect { } else { Issue.record("Unknown requests must never have an effect") }
    #expect(try p.finishDecision(unknown, today: journalDay, decidedAt: journalAt).outcome == .unknown)
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(5)]])
}

@Test func aFailedIntentOrCompletionTransactionCannotLeaveHalfAReplayRecordOrLoseThePendingEffect() throws {
    let f = JournalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try p.store.write { try $0.execute("CREATE TRIGGER fail_intent BEFORE INSERT ON request_decisions BEGIN SELECT RAISE(ABORT, 'invented failure'); END") }
    #expect(throws: (any Error).self) { try p.beginDecision(journalRequest(), plan: noChange, today: journalDay, now: journalAt) }
    #expect(try p.pendingDecision(deviceID: journalDevice) == nil)
    try p.store.write { try $0.execute("DROP TRIGGER fail_intent") }
    let record = try deciding(p.beginDecision(journalRequest(), plan: noChange, today: journalDay, now: journalAt))
    try p.store.write { try $0.execute("CREATE TRIGGER fail_commit BEFORE UPDATE OF highest_seq ON devices BEGIN SELECT RAISE(ABORT, 'invented failure'); END") }
    #expect(throws: (any Error).self) { try p.finishDecision(record, today: journalDay, decidedAt: journalAt) }
    #expect(try f.profile().pendingDecision(deviceID: journalDevice)?.bytes == record.bytes)
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM outcome_tombstones") } == [[.integer(0)]])
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(0)]])
    try p.store.write { try $0.execute("DROP TRIGGER fail_commit") }
    #expect(try p.finishDecision(record, today: journalDay, decidedAt: journalAt).outcome == .applied)
}

@Test func theDailyCapUsesTheMacDayAndAPhoneNoteCannotBeSilentlyCommittedWithoutItsCapture() throws {
    let f = JournalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let request = journalRequest(note: true)
    #expect(throws: CompanionDecisionError.invalid) { try p.beginDecision(request, plan: noChange, today: journalDay, now: journalAt) }
    #expect(try p.pendingDecision(deviceID: journalDevice) == nil)
    let accented = CompanionAuthenticatedRequest(deviceID: request.deviceID, requestID: request.requestID, epoch: 1, sequence: 1,
        action: CompanionRequestedAction(kind: .note, madeAt: journalAt, binderID: nil, itemID: nil, seenVersion: nil, date: nil, text: "e\u{301}"))
    if case .capture(let id, let bytes) = capturePlan(accented).effect {
        var value = try #require(CompanionWire.parse(bytes, limit: 262144).objectValue)
        value.entries = value.entries.map { $0.key == "text" ? ("text", .string("é")) : $0 }
        let altered = CompanionDecisionPlan(outcome: .applied, effect: .capture(id: id, bytes: Data(JSONWriter.compact(.object(value)).utf8)))
        #expect(throws: CompanionDecisionError.invalid) { try p.beginDecision(accented, plan: altered, today: journalDay, now: journalAt) }
    }
    try p.store.write { try $0.execute("INSERT INTO decision_daily VALUES (?, ?, 499)", .text(journalDevice), .text(journalDay)) }
    let record = try deciding(p.beginDecision(request, plan: capturePlan(request), today: journalDay, now: journalAt))
    _ = try p.finishDecision(record, today: journalDay, decidedAt: journalAt)
    #expect(throws: CompanionDecisionError.dailyCap) { try p.beginDecision(journalRequest(64, seq: 2), plan: noChange, today: journalDay, now: journalAt) }
    let next = try deciding(p.beginDecision(journalRequest(64, seq: 2), plan: noChange, today: "2026-10-16", now: "2026-10-16T00:00:00Z"))
    _ = try p.finishDecision(next, today: "2026-10-16", decidedAt: "2026-10-16T00:00:00Z")
    #expect(throws: CompanionDecisionError.dailyCap) { try p.beginDecision(journalRequest(65, seq: 3), plan: noChange, today: journalDay, now: journalAt) }
}

@Test func provenRecoveryReplacesOnlyTheMatchingIntentAndUncertainOpsBecomeConflictCardsWithoutReapplication() throws {
    let f = JournalFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    let request = journalRequest(), oldID = "019a2000-0000-7000-8000-000000000001", newID = "019a2000-0000-7000-8000-000000000002"
    let original = try deciding(p.beginDecision(request, plan: operationPlan(request, oldID), today: journalDay, now: journalAt))
    #expect(throws: CompanionDecisionError.invalid) { try p.recoverDecision(original, recovery: .provenNotApplied(operationPlan(request, oldID)), now: journalAt) }
    let revised = try deciding(p.recoverDecision(original, recovery: .provenNotApplied(operationPlan(request, newID)), now: journalAt))
    #expect(revised.bytes != original.bytes && revised.request.sequence == original.request.sequence)
    let stale = try deciding(p.recoverDecision(original, recovery: .uncertain(conflict: Data("{}".utf8)), now: journalAt))
    #expect(stale.bytes == revised.bytes)
    #expect(throws: CompanionDecisionError.invalid) { try p.finishDecision(original, today: journalDay, decidedAt: journalAt) }
    let conflict = try deciding(f.profile().recoverDecision(revised, recovery: .uncertain(conflict: Data("{\"message\":\"Invented uncertain effect\"}".utf8)), now: journalAt))
    #expect(conflict.plan.outcome == .conflict)
    if case .conflict = conflict.plan.effect { } else { Issue.record("Unknown op recovery must create a card") }
    #expect(try p.store.read { try $0.rows("SELECT highest_seq FROM devices") } == [[.integer(0)]])
    #expect(try p.finishDecision(conflict, today: journalDay, decidedAt: journalAt).outcome == .conflict)
    if case .decided(let done) = try p.recoverDecision(original, recovery: .provenNotApplied(operationPlan(request, newID)), now: journalAt) {
        #expect(done.outcome == .conflict)
    } else { Issue.record("A late recovery cannot replace a tombstone") }
}

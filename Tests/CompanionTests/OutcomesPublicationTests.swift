import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private let outcomeDevice = CompanionWire.base64(Data(repeating: 71, count: 16))
private func outcomeRequest(_ number: Int64) -> String {
    var value = number.bigEndian
    return CompanionWire.base64(withUnsafeBytes(of: &value) { Data($0) } + Data(repeating: 0, count: 8))
}
private final class OutcomeSecrets: CompanionCredentialStorage, @unchecked Sendable {
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private struct OutcomeFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-outcomes-" + UUID().uuidString)
    let secrets = OutcomeSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    func profile() throws -> CompanionProfile { try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets) }
    func prepare() throws -> CompanionProfile {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 19, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        try p.store.write { try $0.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'active', 0, 1, 0)", .text(outcomeDevice)) }
        _ = try secrets.insert(account: p.deviceAccount(outcomeDevice), bytes: Data(repeating: 72, count: 32))
        return p
    }
    func decide(_ p: CompanionProfile, _ seq: Int64, finish: Bool = true) throws {
        let request = CompanionAuthenticatedRequest(deviceID: outcomeDevice, requestID: outcomeRequest(seq), epoch: 1, sequence: seq, action: nil)
        guard case .deciding(let record) = try p.beginDecision(request, today: "2026-10-15", now: "2026-10-15T12:00:00Z") else {
            throw CompanionDecisionError.invalid
        }
        if finish { _ = try p.finishDecision(record, today: "2026-10-15", decidedAt: "2026-10-15T12:00:00Z") }
    }
    func open(_ p: CompanionProfile, _ publication: CompanionOutcomesPublication) throws -> CompanionOpenedObject {
        let owner = try #require(try CompanionOwnerVault(backend: secrets).load(relay))
        let kd = try #require(try secrets.read(account: p.deviceAccount(outcomeDevice)))
        return try CompanionSealedObject.openPayload(name: publication.name, epoch: 0, key: SymmetricKey(data: kd), bytes: publication.bytes, owner: owner.signingKey.publicKey)
    }
}
private let outcomesAt = "2026-10-15T12:00:00Z"

@Test func onlyCommittedDecisionsBecomeSignedPaddedEpochZeroOutcomesAndRestartRetriesExactBytes() throws {
    let f = OutcomeFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    #expect(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt) == nil)
    try f.decide(p, 1); try f.decide(p, 2, finish: false)
    let first = try #require(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt))
    let retry = try #require(try f.profile().prepareOutcomes(deviceID: outcomeDevice, generatedAt: "2026-10-15T12:01:00Z"))
    #expect(first.revision == 1 && first.changes == 1 && retry.bytes == first.bytes)
    let opened = try f.open(p, first), entries = try #require(opened.value["outcomes"]?.arrayValue)
    #expect(opened.plaintextLength == 640 && opened.value["device_id"] == .string(outcomeDevice) && CompanionWire.unsigned(opened.value["revision"]) == 1)
    #expect(entries.count == 1 && entries[0]["request_id"] == .string(outcomeRequest(1)) && entries[0]["outcome"] == .string("rejected"))
    #expect(opened.value["pad"]?.stringValue?.utf8.allSatisfy { $0 == 32 } == true)
    #expect(try p.completeOutcomes(first))
    #expect(try p.pendingOutcomes(deviceID: outcomeDevice) == nil)
    #expect(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt) == nil)
}

@Test func aDecisionCommittedDuringUploadStaysDirtyAndAStaleCompletionCannotMoveTheBuiltCounter() throws {
    let f = OutcomeFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try f.decide(p, 1)
    let first = try #require(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt))
    try f.decide(p, 2)
    #expect(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt)?.bytes == first.bytes)
    #expect(try p.completeOutcomes(first))
    #expect(try p.store.read { try $0.rows("SELECT outcomes_generation, outcomes_built FROM decision_state") } == [[.integer(2), .integer(1)]])
    let second = try #require(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt))
    #expect(second.revision == 2 && second.changes == 2)
    #expect(try p.completeOutcomes(first) == false)
    #expect(try p.completeOutcomes(second))
    #expect(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt) == nil)
}

@Test func outcomeCommitFailuresAndMissingKeysLeaveCountersDirtyAndRetiredNamesAreNeverReused() throws {
    let f = OutcomeFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try f.decide(p, 1)
    #expect(throws: CompanionCredentialError.unavailable) {
        try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt, beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(try p.pendingOutcomes(deviceID: outcomeDevice) == nil)
    #expect(try p.store.read { try $0.rows("SELECT outcomes_reserved, outcomes_built FROM decision_state") } == [[.integer(0), .integer(0)]])
    let first = try #require(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt))
    try p.supersedeOutcomes(first)
    let second = try #require(try f.profile().prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt))
    #expect(second.revision == 2 && second.bytes != first.bytes)
    #expect(try p.completeOutcomes(first) == false)
    try p.store.write { try $0.execute("CREATE TRIGGER fail_outcomes BEFORE UPDATE OF outcomes_built ON decision_state BEGIN SELECT RAISE(ABORT, 'invented failure'); END") }
    #expect(throws: (any Error).self) { try p.completeOutcomes(second) }
    #expect(try f.profile().pendingOutcomes(deviceID: outcomeDevice)?.bytes == second.bytes)
    try p.store.write { try $0.execute("DROP TRIGGER fail_outcomes") }
    #expect(try p.completeOutcomes(second))
    try f.decide(p, 2); f.secrets.values.removeValue(forKey: p.deviceAccount(outcomeDevice))
    let count = f.secrets.values.count
    #expect(throws: CompanionCredentialError.unavailable) { try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt) }
    #expect(f.secrets.values.count == count)
}

@Test func revokedDevicesCannotPrepareRetryOrCompleteOutcomesWithoutTheirKey() throws {
    let f = OutcomeFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try f.decide(p, 1)
    let first = try #require(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt))
    try p.store.write { try $0.execute("UPDATE devices SET state = 'revoked'") }
    f.secrets.values.removeValue(forKey: p.deviceAccount(outcomeDevice))
    #expect(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt) == nil)
    #expect(try p.pendingOutcomes(deviceID: outcomeDevice) == nil)
    #expect(try p.completeOutcomes(first) == false)
}

@Test func outcomesSelectTheNewestTwoThousandFromThirtyDaysAndRetainUnknownAsNonfinal() throws {
    let f = OutcomeFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
    try p.store.write { t in
        try t.execute("INSERT INTO decision_state (device, outcomes_generation) VALUES (?, 2002)", .text(outcomeDevice))
        for seq in Int64(1)...2002 {
            try t.execute("INSERT INTO outcome_tombstones VALUES (?, ?, ?, ?, ?)", .text(outcomeDevice), .text(outcomeRequest(seq)), .integer(seq),
                .text(seq == 2002 ? "unknown" : "applied"), .text(seq == 1 ? "2026-09-14T12:00:00Z" : outcomesAt))
        }
    }
    let publication = try #require(try p.prepareOutcomes(deviceID: outcomeDevice, generatedAt: outcomesAt)), opened = try f.open(p, publication)
    let entries = try #require(opened.value["outcomes"]?.arrayValue)
    #expect(entries.count == 2000 && opened.plaintextLength == 256512)
    #expect(CompanionWire.unsigned(entries.first?["seq"]) == 2002 && entries.first?["outcome"] == .string("unknown"))
    #expect(CompanionWire.unsigned(entries.last?["seq"]) == 3)
}

import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing
@testable import BinderStore

@Suite struct CompanionOperationTransactionTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let effect = "019a2000-0000-7000-8000-000000000005"
    let tag = "companion:AAAAAAAAAAAAAAAAAAAAAA/BBBBBBBBBBBBBBBBBBBBBA"
    let item = "estate-example-2026-007"
    let user = JSONObject([("kind", .string("user")), ("client", .string("sprava/0.1"))])
    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0"), store = TekaStore(folder: folder)
        store.testHookFullSync = { _ in 0 }
        try store.adopt(survey: JSONObject(), owner: JSONObject([("device", .string("test"))]), now: now)
        return (folder, store)
    }
    func drop() -> TekaStore.OpBody { .init(op: "drop", args: JSONObject([("id", .string(item))]), actor: user) }

    @Test func aReservationFailureLeavesNoEffectAndTheExactRecordedLineAppliesOnceAfterRestart() throws {
        let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
        struct ReservationFailed: Error {}
        let original = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        var bytes = Data(), retained: CompanionOperationTransaction?
        #expect(throws: ReservationFailed.self) {
            try store.withCompanionTransaction(now: now) { transaction throws -> Void in
                retained = transaction
                bytes = try transaction.prepare(drop(), effectID: effect, tag: tag, now: now)
                throw ReservationFailed() // Models the higher decision journal failing to flush its intent.
            }
        }
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == original)
        #expect(throws: TekaStore.Refused.self) { try retained!.currentState() }
        let restarted = TekaStore(folder: folder); restarted.testHookFullSync = { _ in 0 }
        try restarted.withCompanionTransaction(now: now) { transaction throws -> Void in
            #expect(try transaction.proof(effectID: effect, tag: tag) == .notApplied)
            #expect(try transaction.applyRecorded(bytes))
            #expect(try transaction.proof(effectID: effect, tag: tag) == .tookEffect)
        }
        let log = try Data(contentsOf: folder.appendingPathComponent(".sprava/ops.ndjson"))
        #expect(log.suffix(bytes.count + 1) == bytes + Data([10]))
        let parsed = try JSONParser.parse(bytes).value
        #expect(parsed["id"] == .string(effect) && parsed["note"] == .string(tag))
        #expect(parsed["args"]?["source"] == .string("user") && parsed["args"]?["closed_at"] == parsed["at"])
        try restarted.withCompanionTransaction(now: now) { transaction throws -> Void in
            #expect(try transaction.applyRecorded(bytes) == false)
            var tampered = try #require(parsed.objectValue); tampered.set("at", .string("2026-10-15T12:00:00Z"))
            #expect(throws: TekaStore.Refused.self) { try transaction.applyRecorded(Data(JSONWriter.compact(.object(tampered)).utf8)) }
        }
        #expect(try restarted.readOpLog().ops.filter { $0["id"] == .string(effect) }.count == 1)
    }

    @Test func aCanonicalRecordedOpLoggedBeforeRenameBecomesUnknownAndIsNeverAppliedAgain() throws {
        let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
        struct Crash: Error {}
        store.testHookAfterAppend = { throw Crash() }
        var bytes = Data()
        #expect(throws: Crash.self) {
            try store.withCompanionTransaction(now: now) { transaction throws -> Void in
                bytes = try transaction.prepare(drop(), effectID: effect, tag: tag, now: now)
                _ = try transaction.applyRecorded(bytes)
            }
        }
        store.testHookAfterAppend = nil
        try store.withCompanionTransaction(now: now) { transaction throws -> Void in
            #expect(try transaction.proof(effectID: effect, tag: tag) == .unknown)
            #expect(throws: TekaStore.Refused.self) { try transaction.applyRecorded(bytes) }
            #expect(try transaction.currentState().catalog["open_items"]?.arrayValue?.contains { $0["id"] == .string(item) } == true)
        }
        #expect(try store.readOpLog().ops.last?["args"]?["reason"] == .string("companion-review"))
    }

    @Test func aProvenUnwrittenButStaleOperationRefusesInsteadOfRecomputingThePersonsDecision() throws {
        let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
        let bytes = try store.withCompanionTransaction(now: now) { try $0.prepare(drop(), effectID: effect, tag: tag, now: now) }
        _ = try store.apply([.init(op: "update_item", args: JSONObject([("id", .string(item)), ("set", .obj([("due", .string("2027-01-01"))]))]), actor: user)], now: now)
        try store.withCompanionTransaction(now: now) { transaction throws -> Void in
            #expect(try transaction.proof(effectID: effect, tag: tag) == .notApplied)
            #expect(throws: TekaStore.Refused.self) { try transaction.applyRecorded(bytes) }
        }
        #expect(try store.readOpLog().ops.contains { $0["id"] == .string(effect) } == false)
    }

    @Test func phoneTransactionsKeepNormalGuardsAndCannotMoveFilesRenameOrBroadenTheirAllowedMutation() throws {
        let (folder, store) = try adopted(); defer { try? FileManager.default.removeItem(at: folder) }
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        try store.withCompanionTransaction(now: now) { transaction throws -> Void in
            for body in [TekaStore.OpBody(op: "rename_teka", args: JSONObject([("name", .string("Sample"))]), actor: user),
                .init(op: "file_document", args: JSONObject(), actor: user),
                .init(op: "update_item", args: JSONObject([("id", .string(item)), ("set", .obj([("disclosure", .string("public"))]))]), actor: user),
                .init(op: "set_status", args: JSONObject([("id", .string(item)), ("status", .string("waiting"))]), actor: user),
                .init(op: "drop", args: JSONObject([("id", .string(item))]), actor: JSONObject([("kind", .string("brain"))]))] {
                #expect(throws: TekaStore.Refused.self) { try transaction.prepare(body, effectID: effect, tag: tag, now: now) }
            }
            #expect(throws: TekaStore.Refused.self) { try transaction.prepare(drop(), effectID: effect, tag: "untrusted", now: now) }
        }
        // Existing TransactionGuard still refuses completing a recurring item without its next occurrence.
        #expect(throws: (any Error).self) {
            try store.apply([.init(op: "update_item", args: JSONObject([("id", .string(item)), ("set", .obj([
                ("due", .string("2026-10-15")), ("recurrence", .obj([("freq", .string("monthly")), ("day", .int(15))]))]))]), actor: user)], now: now)
        }
        #expect(throws: (any Error).self) {
            try store.withCompanionTransaction(now: now) { try $0.prepare(.init(op: "complete", args: JSONObject([
                ("id", .string(item)), ("next_due", .string("2026-11-15"))]), actor: user), effectID: effect, tag: tag, now: now) }
        }
        #expect(before == (try Data(contentsOf: folder.appendingPathComponent("catalog.json"))))
        #expect(try store.readOpLog().ops.contains { $0["id"] == .string(effect) } == false)
    }
}

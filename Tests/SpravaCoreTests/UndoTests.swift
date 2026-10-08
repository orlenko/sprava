import Foundation
import Testing
@testable import SpravaCore

@Suite(.serialized) struct UndoTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user"))])

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        return (folder, store)
    }

    func items(_ folder: URL) -> [JSONValue] { Teka.read(folder).catalog?["open_items"]?.arrayValue ?? [] }

    @Test func mintsTheNextNumberForTheYear() throws {
        let (folder, store) = try adopted()
        let c = Teka.read(folder).catalog!
        #expect(try IDMint.next(catalog: c, opLog: try store.readOpLog().ops, year: 2026) == "estate-example-2026-013")
        #expect(try IDMint.next(catalog: c, opLog: [], year: 2027) == "estate-example-2027-001")
        #expect(IDMint.prefix(for: "Estate of A. Example") == "estate-of-a-example")
        #expect(IDMint.prefix(for: "Ψ") == "item")
    }

    @Test func undoingACompletionReopensUnderANewID() throws {
        let (folder, store) = try adopted()
        let applied = try store.apply([.init(op: "complete", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-007")), (key: "closed_at", value: .str("2026-10-07T09:00:00Z")),
            (key: "source", value: .str("user"))]), actor: user)], now: now)
        try store.undo(opID: applied[0]["id"]!.stringValue!, now: now)
        let reopened = items(folder).last
        #expect(reopened?["id"] == .str("estate-example-2026-013"))
        #expect(reopened?["title"] == .str("File the estate inventory with the notary"))
        #expect(reopened?["due"] == .str("2026-10-10"))
        #expect(reopened?["provenance"]?["reopened_from"] == .str("estate-example-2026-007"))
        let ops = try store.readOpLog().ops
        #expect(ops.last?["compensates"] == applied[0]["id"])
        #expect(throws: TekaStore.Refused.self) { try store.undo(opID: applied[0]["id"]!.stringValue!, now: now) }
        _ = try Replay.run(ops)
    }

    @Test func undoingAStatusChangeRestoresTheWaitingFields() throws {
        let (folder, store) = try adopted()
        let applied = try store.apply([.init(op: "set_status", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-008")), (key: "status", value: .str("open"))]), actor: user)], now: now)
        #expect(items(folder).first { $0["id"] == .str("estate-example-2026-008") }?["waiting_on"] == nil)
        try store.undo(opID: applied[0]["id"]!.stringValue!, now: now)
        let item = items(folder).first { $0["id"] == .str("estate-example-2026-008") }
        #expect(item?["status"] == .str("waiting"))
        #expect(item?["follow_up_at"] == .str("2026-10-09"))
        #expect(item?["waiting_on"] != nil)
    }

    @Test func undoingAnEditRestoresAndRemoves() throws {
        let (folder, store) = try adopted()
        let applied = try store.apply([.init(op: "update_item", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-007")),
            (key: "set", value: .obj([("priority", .str("low")), ("estimate_min", .int(30)), ("importance", .str("low"))]))]), actor: user)], now: now)
        try store.undo(opID: applied[0]["id"]!.stringValue!, now: now)
        let item = items(folder).first { $0["id"] == .str("estate-example-2026-007") }
        #expect(item?["priority"] == .str("high"))
        #expect(item?["estimate_min"] == .int(90))   // the fixture's own value comes back
        #expect(item?["importance"] == nil)          // a field the edit added is removed again
    }

    @Test func factsCannotBeUndone() throws {
        let (_, store) = try adopted()
        let first = try store.readOpLog().ops[0]["id"]!.stringValue!
        #expect(throws: TekaStore.Refused.self) { try store.undo(opID: first, now: now) }
    }
}

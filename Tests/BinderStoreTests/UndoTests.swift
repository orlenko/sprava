import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

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

    /// A lifeproj v2 binder holding `items`, adopted.
    func inline(_ items: String) throws -> (URL, TekaStore) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-undo-\(UUID().uuidString)/tax", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(#"{"meta":{"schema_version":2,"name":"tax"},"documents":[],"open_items":[\#(items)],"processing_log":[]}"#.utf8)
            .write(to: folder.appendingPathComponent("catalog.json"))
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        return (folder, store)
    }

    func edit(_ store: TekaStore, _ id: String, _ set: [(String, JSONValue)]) throws -> String {
        try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .string(id)), (key: "set", value: .obj(set))]),
                               actor: user)], now: now)[0]["id"]!.stringValue!
    }

    // Layer 5 review, finding 1: undoing an older occurrence never sets back a series a later completion advanced.
    @Test func anOlderOccurrenceIsNotUndoneThroughALaterOne() throws {
        let (folder, store) = try inline(#"{"id":"r-1","title":"Invented monthly report","status":"open","priority":"normal","due":"2026-10-15","recurrence":{"every":"month"}}"#)
        func advance(_ from: String, _ to: String) throws -> String {
            try store.apply([.init(op: "complete", args: JSONObject([(key: "id", value: .str("r-1")), (key: "occurrence_due", value: .string(from)),
                                                                     (key: "next_due", value: .string(to))]), actor: user)], now: now)[0]["id"]!.stringValue!
        }
        let october = try advance("2026-10-15", "2026-11-15")
        let november = try advance("2026-11-15", "2026-12-15")
        #expect(throws: Undo.Unsupported.self) { try store.undo(opID: october, now: now) }
        #expect(items(folder).first?["due"] == .str("2026-12-15"))
        // Newest first works, and then the older one.
        try store.undo(opID: november, now: now)
        #expect(items(folder).first?["due"] == .str("2026-11-15"))
        try store.undo(opID: october, now: now)
        #expect(items(folder).first?["due"] == .str("2026-10-15"))
    }

    // Layer 5 review, finding 7: undo restores the derivation flags of the fields it restores, and no others.
    @Test func undoLeavesTheFlagsOfOtherFieldsAsTheyAre() throws {
        let (folder, store) = try inline(#"{"id":"d-1","title":"Invented reply","status":"open","priority":"normal","due":"2026-11-01","derived":["due"]},"#
            + #"{"id":"w-1","title":"Invented wait","status":"waiting","priority":"normal","due":"2026-11-01","waiting_on":"an invented office","follow_up_at":"2026-10-20","derived":["due","follow_up_at"]}"#)
        func item(_ id: String) -> JSONValue? { items(folder).first { $0["id"] == .string(id) } }
        // A priority change, then the inferred date is confirmed: undoing the first never marks the date inferred again.
        let priority = try edit(store, "d-1", [("priority", .str("high"))])
        _ = try edit(store, "d-1", [("due", .str("2026-11-01"))])
        #expect(item("d-1")?["derived"] == nil)
        try store.undo(opID: priority, now: now)
        #expect(item("d-1")?["priority"] == .str("normal"))
        #expect(item("d-1")?["derived"] == nil)
        // The same after a status change; the restored follow-up date gets its own flag back.
        let status = try store.apply([.init(op: "set_status", args: JSONObject([(key: "id", value: .str("w-1")), (key: "status", value: .str("blocked")),
                                                                                (key: "follow_up_at", value: .str("2026-10-25"))]), actor: user)], now: now)
        #expect(item("w-1")?["derived"] == .array([.str("due")]))
        _ = try edit(store, "w-1", [("due", .str("2026-11-01"))])
        try store.undo(opID: status[0]["id"]!.stringValue!, now: now)
        #expect(item("w-1")?["status"] == .str("waiting"))
        #expect(item("w-1")?["follow_up_at"] == .str("2026-10-20"))
        #expect(item("w-1")?["derived"] == .array([.str("follow_up_at")]))
        _ = try Replay.run(try store.readOpLog().ops)
    }
}

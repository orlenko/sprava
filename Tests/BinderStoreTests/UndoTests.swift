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

    // Layer 5 second calibrated review, finding 3: a completion without `occurrence_due` is undone to the due date
    // the item had before it.
    @Test func anOccurrenceWithoutItsDueIsUndone() throws {
        let (folder, store) = try inline(#"{"id":"r-1","title":"Invented monthly report","status":"open","priority":"normal","due":"2026-10-15","recurrence":{"every":"month"}}"#)
        let applied = try store.apply([.init(op: "complete", args: JSONObject([(key: "id", value: .str("r-1")), (key: "next_due", value: .str("2026-11-15"))]),
                                             actor: user)], now: now)
        #expect(items(folder).first?["due"] == .str("2026-11-15"))
        try store.undo(opID: applied[0]["id"]!.stringValue!, now: now)
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

    // Layer 5 second review, finding 1: an undo aborted by an outside edit is retried, never taken for done.
    @Test func anAbortedUndoIsRetriedAndAnAbortedOpIsNotUndone() throws {
        let (folder, store) = try adopted()
        let edit = try self.edit(store, "estate-example-2026-007", [("priority", .str("low"))])
        // An editor saves the catalog while the compensation's log lines are flushed.
        let url = folder.appendingPathComponent("catalog.json")
        let text = try String(contentsOf: url, encoding: .utf8)
            .replacingOccurrences(of: "Collect photos of the house", with: "Collect invented photos of the house")
        store.testHookAfterAppend = {
            store.testHookAfterAppend = nil
            try Data(text.utf8).write(to: url)
        }
        try store.undo(opID: edit, now: now)
        let ops = try store.readOpLog().ops
        let aborted = try #require(ops.first { $0["op"] == .str("abort") }?["args"]?["ops"]?.arrayValue?.first?.stringValue)
        #expect(ops.filter { $0["compensates"] == .string(edit) }.count == 2)
        #expect(items(folder).first { $0["id"] == .str("estate-example-2026-007") }?["priority"] == .str("high"))
        #expect(items(folder).contains { $0["title"] == .str("Collect invented photos of the house for the family") })
        // Undone once for real: a second undo is refused, and so is undoing the aborted line itself.
        #expect(throws: TekaStore.Refused.self) { try store.undo(opID: edit, now: now) }
        #expect(throws: TekaStore.Refused.self) { try store.undo(opID: aborted, now: now) }
        _ = try Replay.run(try store.readOpLog().ops)
    }

    // Layer 5 second review, finding 4: a reopened item keeps its provenance and the flags of fields still inferred.
    @Test func reopeningKeepsProvenanceAndDerivedFlags() throws {
        let (folder, store) = try adopted()
        func close(_ id: String) throws -> String {
            try store.apply([.init(op: "complete", args: JSONObject([(key: "id", value: .string(id)), (key: "closed_at", value: .str("2026-10-07T09:00:00Z")),
                                                                     (key: "source", value: .str("user"))]), actor: user)], now: now)[0]["id"]!.stringValue!
        }
        try store.undo(opID: try close("estate-example-2026-007"), now: now)
        let first = try #require(items(folder).last)
        #expect(first["provenance"]?["reopened_from"] == .str("estate-example-2026-007"))
        #expect(first["provenance"]?["events"] == .array([.str("019a0f52-2c1a-7d5e-9f10-2a3b4c5d6e7f")]))
        #expect(first["provenance"]?["proposal"] == .str("019a0f53-0a1b-7c2d-8e3f-4a5b6c7d8e9f"))
        #expect(first["provenance"]?["approved_by"] == .str("user"))
        try store.undo(opID: try close("estate-example-2026-012"), now: now)
        let second = try #require(items(folder).last)
        #expect(second["provenance"]?["reopened_from"] == .str("estate-example-2026-012"))
        #expect(second["follow_up_at"] == .str("2026-10-06"))
        #expect(second["derived"] == .array([.str("follow_up_at")]))
        _ = try Replay.run(try store.readOpLog().ops)
    }

    // Layer 5 third review, finding 3: undoing the drop of a repeating item is refused, never reopened as a one-off.
    @Test func undoingTheDropOfARepeatingItemIsRefused() throws {
        let (folder, store) = try adopted()
        let applied = try store.apply([.init(op: "drop", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-010")), (key: "closed_at", value: .str("2026-10-07T09:00:00Z")),
            (key: "source", value: .str("user"))]), actor: user)], now: now)
        let count = items(folder).count
        #expect(throws: Undo.Unsupported.self) { try store.undo(opID: applied[0]["id"]!.stringValue!, now: now) }
        #expect(items(folder).count == count)
        #expect(try store.readOpLog().ops.last?["id"] == applied[0]["id"])
    }
}

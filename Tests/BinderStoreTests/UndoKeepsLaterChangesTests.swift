import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// A late Undo goes field by field (binder-v0 §6.10, conversation.md §17.2): fields changed since keep their newer
/// values, the compensating op carries `expect` for the fields it restores, and the guard refuses an op whose
/// `expect` no longer matches the record. Invented binders only.
@Suite(.serialized) struct UndoKeepsLaterChangesTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user"))])
    static let id = JSONValue.str("estate-example-2026-007")

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        return (folder, store)
    }

    func item(_ folder: URL) -> JSONValue? {
        Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["id"] == Self.id }
    }

    /// The error `body` throws, as text; a test fails when it throws nothing.
    func refusal(_ body: () throws -> Void) -> String {
        do { try body() } catch { return "\(error)" }
        Issue.record("nothing was refused")
        return ""
    }

    func edit(_ store: TekaStore, _ fields: [(String, JSONValue)], extra: [(String, JSONValue)] = []) throws -> [JSONObject] {
        try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: Self.id), (key: "set", value: .obj(fields))]),
                               actor: user, extra: extra)], now: now)
    }

    @Test func aFieldChangedSinceKeepsItsNewerValue() throws {
        let (folder, store) = try adopted()
        let original = try #require(item(folder))
        let first = try edit(store, [("priority", .str("low")), ("estimate_min", .int(30))])
        _ = try edit(store, [("priority", .str("normal"))])   // the person's later change

        let outcome = try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now)
        #expect(outcome.kept == ["priority"])
        #expect(item(folder)?["priority"] == .str("normal"))
        #expect(item(folder)?["estimate_min"] == original["estimate_min"])
        let line = try #require(try store.readOpLog().ops.last)
        #expect(line["compensates"] == first[0]["id"])
        #expect(line["expect"] == .obj([("set", .obj([("estimate_min", .int(30))]))]))
        #expect(line["args"]?["set"]?["priority"] == nil)
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test func anEditWhoseEveryFieldChangedSinceIsRefusedWithNothingWritten() throws {
        let (folder, store) = try adopted()
        let first = try edit(store, [("priority", .str("low"))])
        _ = try edit(store, [("priority", .str("normal"))])
        let count = try store.readOpLog().ops.count
        #expect(throws: Undo.Unsupported.self) { try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now) }
        #expect(try store.readOpLog().ops.count == count)
        #expect(item(folder)?["priority"] == .str("normal"))
    }

    @Test func anUndoWithNothingChangedSinceRestoresAllAndKeepsNothing() throws {
        let (folder, store) = try adopted()
        let original = try #require(item(folder))
        let first = try edit(store, [("priority", .str("low")), ("importance", .str("low"))])
        let outcome = try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now)
        #expect(outcome.kept == [])
        #expect(item(folder)?["priority"] == original["priority"])
        #expect(item(folder)?["importance"] == nil)
        let expect = try #require(try store.readOpLog().ops.last?["expect"])
        #expect(expect["set"] == .obj([("priority", .str("low")), ("importance", .str("low"))]))
    }

    @Test func theGuardRefusesAStaleExpectation() throws {
        let (folder, store) = try adopted()
        let before = try #require(item(folder))
        let stale: [(String, JSONValue)] = [("compensates", .str("019a2000-0000-7000-8000-000000000001")),
                                            ("expect", .obj([("set", .obj([("priority", .str("low"))]))]))]
        #expect(refusal { _ = try edit(store, [("priority", .str("normal"))], extra: stale) }.contains("priority changed since"))
        let absent: [(String, JSONValue)] = [("compensates", .str("019a2000-0000-7000-8000-000000000001")),
                                             ("expect", .obj([("absent", .array([.str("priority")]))]))]
        #expect(refusal { _ = try edit(store, [("priority", .str("normal"))], extra: absent) }.contains("priority changed since"))
        #expect(item(folder) == before)
    }

    @Test func aRecordHashBindsAnOpToTheRevisionItRead() throws {
        let (folder, store) = try adopted()
        let read = try Canonical.hash(try #require(item(folder)))
        _ = try edit(store, [("priority", .str("low"))])   // a change made after the op's author read the item
        #expect(refusal { _ = try edit(store, [("estimate_min", .int(45))], extra: [("expect", .obj([("record", .string(read))]))]) }
            .contains("the record changed since"))
        #expect(item(folder)?["estimate_min"] != .int(45))
        let current = try Canonical.hash(try #require(item(folder)))
        _ = try edit(store, [("estimate_min", .int(45))], extra: [("expect", .obj([("record", .string(current))]))])
        #expect(item(folder)?["estimate_min"] == .int(45))
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test func expectOnAnOpWithoutAnExistingRecordIsRefused() throws {
        let (_, store) = try adopted()
        let item = JSONObject([(key: "title", value: .str("Invented new item")), (key: "status", value: .str("open")),
                               (key: "priority", value: .str("normal")), (key: "no_deadline", value: .bool(true))])
        #expect(refusal {
            _ = try store.applyMinting([.init(op: "add_item", args: JSONObject([(key: "item", value: .object(item))]), actor: user,
                                          extra: [("expect", .obj([("record", .str("sha256:" + String(repeating: "0", count: 64)))]))])], now: now)
        }.contains("expect applies only to an op on an existing record"))
    }
}

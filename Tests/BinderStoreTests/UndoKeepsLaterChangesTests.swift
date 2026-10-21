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

    @Test func aFieldSetBackToTheUndoneValueSinceKeepsTheLaterChoice() throws {
        let (folder, store) = try adopted()
        let original = try #require(item(folder))
        let first = try edit(store, [("priority", .str("low")), ("estimate_min", .int(30))])
        _ = try edit(store, [("priority", .str("high"))])
        _ = try edit(store, [("priority", .str("low")), ("estimate_min", .int(45))])   // chosen again, with another change

        #expect(throws: (any Error).self) { try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now) }
        #expect(item(folder)?["priority"] == .str("low") && item(folder)?["estimate_min"] == .int(45))

        // With only the cycled field changed since, the other field still goes back and the cycled one is kept.
        let (folder2, store2) = try adopted()
        let second = try edit(store2, [("priority", .str("low")), ("estimate_min", .int(30))])
        _ = try edit(store2, [("priority", .str("high"))])
        _ = try edit(store2, [("priority", .str("low"))])
        let outcome = try store2.undoChange(opID: second[0]["id"]!.stringValue!, now: now)
        #expect(outcome.kept == ["priority"])
        #expect(item(folder2)?["priority"] == .str("low") && item(folder2)?["estimate_min"] == original["estimate_min"])
    }

    @Test func aValueApprovedAgainUnchangedIsKept() throws {
        let (folder, store) = try adopted()
        let original = try #require(item(folder))
        let first = try edit(store, [("priority", .str("low")), ("estimate_min", .int(30))])
        _ = try edit(store, [("priority", .str("low"))], extra: [("proposal", .str(UUID().uuidString.lowercased())),
                                                                 ("approved_by", .str("user"))])
        let outcome = try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now)
        #expect(outcome.kept == ["priority"])
        #expect(item(folder)?["priority"] == .str("low") && item(folder)?["estimate_min"] == original["estimate_min"])
    }

    /// Undoes `first` after `since` and checks it was refused whole: no undo logged and the item as it was.
    func refusedWhole(_ folder: URL, _ store: TekaStore, _ first: [JSONObject], since: () throws -> Void) throws {
        try since()
        let was = item(folder)
        #expect(throws: Undo.Unsupported.self) { try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now) }
        #expect(item(folder) == was)
        #expect(!(try store.readOpLog().ops.contains { $0["compensates"] != nil }))
    }

    @Test func aPartialUndoNeverSplitsContentFromItsPrivacy() throws {
        // The undone edit set a privacy marker, and the item changed since in another field.
        var (folder, store) = try adopted()
        var first = try edit(store, [("redact", .bool(true)), ("priority", .str("low"))])
        try refusedWhole(folder, store, first) { _ = try edit(store, [("title", .str("Invented private title"))]) }

        // The undone edit made a confidential title public and lifted the redaction; a later edit changed the priority.
        // Undoing it field by field would bring the confidential title back unredacted.
        (folder, store) = try adopted()
        _ = try edit(store, [("title", .str("Invented confidential title")), ("redact", .bool(true))])
        first = try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: Self.id),
            (key: "set", value: .obj([("title", .str("Invented public title"))])), (key: "unset", value: .array([.str("redact")]))]),
                                       actor: user)], now: now)
        try refusedWhole(folder, store, first) { _ = try edit(store, [("priority", .str("high"))]) }

        // The undone edit touched no marker, but the redaction was lifted since.
        (folder, store) = try adopted()
        _ = try edit(store, [("title", .str("Invented confidential title")), ("redact", .bool(true))])
        first = try edit(store, [("title", .str("Invented public title"))])
        try refusedWhole(folder, store, first) {
            _ = try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: Self.id),
                (key: "unset", value: .array([.str("redact")]))]), actor: user)], now: now)
        }

        // Another program removed the redaction the undone edit set; the ratchet still holds the item redacted.
        (folder, store) = try adopted()
        _ = try edit(store, [("tags", .array([.str("invented-private-tag")]))])
        first = try edit(store, [("redact", .bool(true)), ("tags", .array([])), ("priority", .str("low"))])
        try refusedWhole(folder, store, first) {
            let url = folder.appendingPathComponent("catalog.json")
            var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
            var items = catalog["open_items"]?.arrayValue ?? []
            let at = try #require(items.firstIndex { $0["id"] == Self.id })
            var changed = try #require(items[at].objectValue)
            changed.remove("redact")
            items[at] = .object(changed)
            catalog.set("open_items", .array(items))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
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

    @Test func undoingAnAddedItemEditedSinceIsRefusedAndKeepsIt() throws {
        let (folder, store) = try adopted()
        let added = JSONValue.str("estate-example-2026-108")
        let applied = try store.apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([("id", added),
            ("title", .str("Invented new task")), ("status", .str("open")), ("priority", .str("low")), ("no_deadline", .bool(true))]))]),
                                             actor: user)], now: now)
        _ = try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: added), (key: "set", value: .obj([("priority", .str("high"))]))]),
                                   actor: user)], now: now)
        let lines = try store.readOpLog().ops.count
        #expect(refusal { try store.undo(opID: applied[0]["id"]!.stringValue!, now: now) }.contains("the item changed since"))
        #expect(try store.readOpLog().ops.count == lines)
        let open = Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["id"] == added }
        #expect(open?["priority"] == .str("high"))
    }

    @Test func undoingAnAddedItemBindsTheDropToTheItemAsAdded() throws {
        let (folder, store) = try adopted()
        let added = JSONValue.str("estate-example-2026-109")
        let applied = try store.apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([("id", added),
            ("title", .str("Invented new task")), ("status", .str("open")), ("priority", .str("low")), ("no_deadline", .bool(true))]))]),
                                             actor: user)], now: now)
        let item = try #require(Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["id"] == added })
        try store.undo(opID: applied[0]["id"]!.stringValue!, now: now)
        let line = try #require(try store.readOpLog().ops.last)
        #expect(line["op"] == .str("drop"))
        #expect(line["expect"] == .obj([("record", .string(try Canonical.hash(item)))]))
    }

    @Test func anAddedItemEditedAndSetBackIsNotDroppedByUndo() throws {
        let (folder, store) = try adopted()
        let added = JSONValue.str("estate-example-2026-109")
        let applied = try store.apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([("id", added),
            ("title", .str("Invented new task")), ("status", .str("open")), ("priority", .str("low")), ("no_deadline", .bool(true))]))]),
                                             actor: user)], now: now)
        for priority in ["high", "low"] {
            _ = try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: added),
                (key: "set", value: .obj([("priority", .string(priority))]))]), actor: user)], now: now)
        }
        #expect(throws: (any Error).self) { try store.undo(opID: applied[0]["id"]!.stringValue!, now: now) }
        #expect(Teka.read(folder).catalog?["open_items"]?.arrayValue?.contains { $0["id"] == added } == true)
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

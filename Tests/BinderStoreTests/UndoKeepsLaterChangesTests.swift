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

    @Test func anUndoThatKeepsALaterChangeNeverLiftsItsRedaction() throws {
        let (folder, store) = try adopted()
        let clerk = JSONObject([(key: "kind", value: .str("clerk")), (key: "model", value: .str("invented-model"))])
        func privateUpdate(_ who: String) throws -> [JSONObject] {
            let proposal = JSONValue.str(UUID().uuidString.lowercased())
            return try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: Self.id), (key: "set", value: .obj([
                ("waiting_on", .string(who)), ("redact", .bool(true)), ("kind", .str("reply-owed"))]))]), actor: clerk,
                extra: [("proposal", proposal), ("approved_by", .str("user"))])], now: now)
        }
        let original = try #require(item(folder))
        #expect(original["redact"] == nil && original["kind"] != nil)
        let first = try privateUpdate("Invented Party A")
        _ = try privateUpdate("Invented Party B")

        let outcome = try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now)
        #expect(Set(outcome.kept) == ["waiting_on", "redact"])
        #expect(item(folder)?["waiting_on"] == .str("Invented Party B"))
        #expect(item(folder)?["redact"] == .bool(true))
        // The earlier kind comes back: the item keeps one, so nothing is shown that its redaction hides.
        #expect(item(folder)?["kind"] == original["kind"])
    }

    @Test func anUndoAfterAnUnrelatedLaterEditNeverLiftsItsRedaction() throws {
        let (folder, store) = try adopted()
        let first = try edit(store, [("redact", .bool(true)), ("priority", .str("low"))])
        _ = try edit(store, [("title", .str("Invented private title"))])   // a later change to another field

        let outcome = try store.undoChange(opID: first[0]["id"]!.stringValue!, now: now)
        #expect(outcome.kept == ["redact"])
        #expect(item(folder)?["redact"] == .bool(true) && item(folder)?["title"] == .str("Invented private title"))
        #expect(item(folder)?["priority"] != .str("low"))
    }

    @Test func loosensNamesThePrivacyRatchetsWidenings() {
        let redacted = JSONObject([(key: "redact", value: .bool(true)), (key: "tags", value: .array([.str("a")])), (key: "kind", value: .str("task"))])
        #expect(Undo.loosens("redact", back: nil, current: redacted))
        #expect(!Undo.loosens("redact", back: .bool(true), current: redacted))
        #expect(Undo.loosens("tags", back: .array([.str("a"), .str("b")]), current: redacted))
        #expect(!Undo.loosens("tags", back: .array([]), current: redacted))
        #expect(Undo.loosens("kind", back: nil, current: redacted))
        #expect(Undo.loosens("slice_title", back: nil, current: JSONObject([(key: "slice_title", value: .str("Invented"))])))
        #expect(!Undo.loosens("tags", back: .array([.str("b")]), current: JSONObject()))
        #expect(!Undo.loosens("due", back: nil, current: redacted))
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

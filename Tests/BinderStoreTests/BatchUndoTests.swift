@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Undo of a whole batch, such as one turn of a conversation (binder-v0 §6.10): reversed in reverse `seq` order as one
/// new batch, each op against the records as the reversals before it leave them; an op changed since is left as it is
/// and reported, and the others apply. Invented binders only.
@Suite(.serialized) struct BatchUndoTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user"))])
    static let a = JSONValue.str("estate-example-2026-007")
    static let b = JSONValue.str("estate-example-2026-008")
    static let added = JSONValue.str("estate-example-2026-120")

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        return (folder, store)
    }

    func items(_ folder: URL) -> [JSONValue] { Teka.read(folder).catalog?["open_items"]?.arrayValue ?? [] }
    func item(_ folder: URL, _ id: JSONValue) -> JSONValue? { items(folder).first { $0["id"] == id } }
    /// Items without their update times, which an undo sets anew.
    func content(_ folder: URL) -> [JSONValue] {
        items(folder).map { .object(JSONObject(($0.objectValue ?? JSONObject()).entries.filter { $0.key != "updated_at" })) }
    }

    func edit(_ id: JSONValue, _ fields: [(String, JSONValue)]) -> TekaStore.OpBody {
        .init(op: "update_item", args: JSONObject([(key: "id", value: id), (key: "set", value: .obj(fields))]), actor: user)
    }
    func add(_ id: JSONValue) -> TekaStore.OpBody {
        .init(op: "add_item", args: JSONObject([(key: "item", value: .obj([("id", id), ("title", .str("Invented new task")),
            ("status", .str("open")), ("priority", .str("low")), ("no_deadline", .bool(true))]))]), actor: user)
    }

    @Test func aWholeTurnIsUndoneAsOneNewBatch() throws {
        let (folder, store) = try adopted()
        let before = content(folder)
        let turn = try store.apply([edit(Self.a, [("priority", .str("low"))]),
                                    .init(op: "dismiss", args: JSONObject([(key: "id", value: Self.b)]), actor: user),
                                    add(Self.added), edit(Self.added, [("title", .str("Invented renamed task"))])], now: now)
        let batch = try #require(turn[0]["batch"]?.stringValue)

        let outcome = try store.undoBatch(batch, now: now)
        #expect(outcome.notUndone.isEmpty && outcome.kept.isEmpty)
        #expect(content(folder) == before)
        let lines = outcome.ops
        #expect(Set(lines.compactMap { $0["batch"] }).count == 1 && lines.count == 4)
        #expect(lines.map { $0["compensates"] } == turn.reversed().map { $0["id"] })
        _ = try Replay.run(try store.readOpLog().ops)
    }

    @Test func anOpChangedSinceIsLeftAndTheOthersApply() throws {
        let (folder, store) = try adopted()
        let original = try #require(item(folder, Self.a))
        let turn = try store.apply([edit(Self.a, [("priority", .str("low"))]), edit(Self.b, [("priority", .str("low"))])], now: now)
        _ = try store.apply([edit(Self.b, [("priority", .str("high"))])], now: now)   // the person's later change

        let outcome = try store.undoBatch(try #require(turn[0]["batch"]?.stringValue), now: now)
        #expect(item(folder, Self.a)?["priority"] == original["priority"])
        #expect(item(folder, Self.b)?["priority"] == .str("high"))
        #expect(outcome.notUndone.map(\.op) == [turn[1]["id"]!.stringValue!])
        #expect(outcome.ops.count == 1)
    }

    @Test func anEarlierOpOnARecordWhoseLaterOpWasLeftIsLeftToo() throws {
        let (folder, store) = try adopted()
        let turn = try store.apply([edit(Self.a, [("priority", .str("low"))]), edit(Self.a, [("priority", .str("high"))]),
                                    edit(Self.b, [("priority", .str("low"))])], now: now)
        _ = try store.apply([edit(Self.a, [("priority", .str("low"))])], now: now)   // the person's later choice

        let outcome = try store.undoBatch(try #require(turn[0]["batch"]?.stringValue), now: now)
        #expect(item(folder, Self.a)?["priority"] == .str("low"))
        #expect(Set(outcome.notUndone.map(\.op)) == Set([turn[0]["id"]!.stringValue!, turn[1]["id"]!.stringValue!]))
        #expect(outcome.ops.map { $0["compensates"] } == [turn[2]["id"]])
    }

    @Test func aTurnWithNothingLeftToUndoWritesNothing() throws {
        let (folder, store) = try adopted()
        let turn = try store.apply([edit(Self.a, [("priority", .str("low"))]), edit(Self.b, [("priority", .str("low"))])], now: now)
        let batch = try #require(turn[0]["batch"]?.stringValue)
        _ = try store.undoBatch(batch, now: now)
        let lines = try store.readOpLog().ops.count
        #expect(throws: TekaStore.Refused.self) { try store.undoBatch(batch, now: now) }
        #expect(try store.readOpLog().ops.count == lines)
        #expect(throws: TekaStore.Refused.self) { try store.undoBatch("0199e9e6-3c00-7000-8000-00000000dead", now: now) }
        #expect(item(folder, Self.a) != nil)
    }

    @Test func aTurnThatRedactedAndRetitledComesBackWhole() throws {
        let (folder, store) = try adopted()
        let original = try #require(item(folder, Self.a))
        let turn = try store.apply([edit(Self.a, [("redact", .bool(true))]), edit(Self.a, [("title", .str("Invented private title"))])], now: now)
        let outcome = try store.undoBatch(try #require(turn[0]["batch"]?.stringValue), now: now)
        #expect(outcome.kept.isEmpty && outcome.notUndone.isEmpty)
        #expect(item(folder, Self.a)?["redact"] == original["redact"] && item(folder, Self.a)?["title"] == original["title"])
    }
}

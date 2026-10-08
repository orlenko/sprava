import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Hub
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the second hostile review (increments 2 and 3). Each test names the finding it pins.
@Suite(.serialized) struct ReviewRegression2Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    let user = JSONObject([(key: "kind", value: .str("user"))])

    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-review2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func binder(_ root: URL, name: String, catalog: String) throws -> URL {
        let f = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try Data(catalog.utf8).write(to: f.appendingPathComponent("catalog.json"))
        return f
    }

    func cat(_ f: URL) throws -> JSONObject {
        try JSONParser.parse(try Data(contentsOf: f.appendingPathComponent("catalog.json"))).value.objectValue!
    }

    func item(_ id: String, _ title: String = "Invented task", due: String = "2026-11-01", priority: String = "normal") -> String {
        #"{"id":"\#(id)","title":"\#(title)","status":"open","priority":"\#(priority)","due":"\#(due)"}"#
    }

    func lifeproj(name: String, items: [String], log: String = "[]") -> String {
        #"{"meta":{"schema_version":2,"name":"\#(name)"},"documents":[],"open_items":[\#(items.joined(separator: ","))],"processing_log":\#(log)}"#
    }

    func spool(_ root: URL) throws -> URL {
        let s = root.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: s.appendingPathComponent("outbox"), withIntermediateDirectories: true)
        chmod(s.path, 0o700)
        chmod(s.appendingPathComponent("outbox").path, 0o700)
        return s
    }

    func complete(_ id: String) -> TekaStore.OpBody {
        .init(op: "complete", args: JSONObject([(key: "id", value: .string(id)), (key: "closed_at", value: .str("2026-10-07T00:00:00Z")),
                                                (key: "source", value: .str("user"))]), actor: user)
    }

    // 1. A meta.name edit must not let one binder drain another's check-offs, nor publish outside the spool.
    @Test func aNameMismatchBlocksDrainAndPublish() throws {
        let root = try scratch()
        func text(_ name: String) -> String { lifeproj(name: name, items: [item("item-0003")]) }
        let f = try binder(root, name: "tax", catalog: text("tax"))
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let s = try spool(root)
        let other = s.appendingPathComponent("outbox/rent.intake.json")
        try Data(#"{"teka":"rent","completions":[{"id":"rent-item-0003","action":"done","at":"2026-10-07T09:00:00Z"}]}"#.utf8).write(to: other)
        try Data(text("rent").utf8).write(to: f.appendingPathComponent("catalog.json"))
        #expect(try HubLane.drain(f, root: s).applied == 0)
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(try cat(f)["open_items"]?.arrayValue?.count == 1)

        try Data(text("../../escaped").utf8).write(to: f.appendingPathComponent("catalog.json"))
        #expect(try HubLane.publish(f, root: s, now: now) == .notPublished("the binder needs attention"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("escaped.agenda.json").path))
        #expect(throws: TekaStore.Refused.self) { try HubLane.spoolFile(s, "../x", ".agenda.json") }
    }

    // 9. A minted id never projects onto an open item's slice id; the guard refuses a colliding add.
    @Test func mintingSkipsSliceCollisions() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("2026-001"), item("x-1")]))
        let store = TekaStore(folder: f)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let s = try spool(root)
        try FileManager.default.createDirectory(at: s.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        chmod(s.appendingPathComponent("inbox").path, 0o700)
        let done = try store.apply([complete("x-1")], now: now)
        let undone = try store.undo(opID: done[0]["id"]!.stringValue!, now: now)
        #expect(undone[0]["args"]?["item"]?["id"] == .str("tax-2026-002"))
        if case .published = try HubLane.publish(f, root: s, now: now) {} else { Issue.record("publish failed") }
        var clash = try JSONParser.parse(Data(item("tax-2026-001").utf8)).value.objectValue!
        clash.set("created_at", .str("2026-10-07T00:00:00Z"))
        clash.set("updated_at", .str("2026-10-07T00:00:00Z"))
        #expect(throws: TransactionGuard.Rejection.self) {
            try store.apply([.init(op: "add_item", args: JSONObject([(key: "item", value: .object(clash))]), actor: user)], now: now)
        }
    }

    // 13. A completion for an id already closed is acknowledged, with or without `at`.
    @Test func aCompletionForAClosedIDIsAcknowledged() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("a-1")]))
        let s = try spool(root)
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let outbox = s.appendingPathComponent("outbox/tax.intake.json")
        let body = Data(#"{"teka":"tax","completions":[{"id":"tax-a-1","action":"done"}]}"#.utf8)
        try body.write(to: outbox)
        #expect(try HubLane.drain(f, root: s, now: now).applied == 1)
        try body.write(to: outbox)
        let again = try HubLane.drain(f, root: s, now: now)
        #expect(again.acknowledged == 1 && again.applied == 0)
        #expect(!FileManager.default.fileExists(atPath: outbox.path))
    }
}

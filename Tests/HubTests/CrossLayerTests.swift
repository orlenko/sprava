import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Hub
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the hub's adaptation to the reviewed lower layers: what a closure and a redacted item publish,
/// a binder whose stamp lost its disclosure, and the slice key. Every value is invented.
@Suite(.serialized) struct CrossLayerTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    let user = JSONObject([(key: "kind", value: .str("user"))])

    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-hub-cross-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func item(_ id: String) -> String {
        #"{"id":"\#(id)","title":"Invented task","status":"open","priority":"normal","due":"2026-11-01"}"#
    }

    func cat(_ f: URL) throws -> JSONObject {
        try JSONParser.parse(try Data(contentsOf: f.appendingPathComponent("catalog.json"))).value.objectValue!
    }

    func write(_ c: JSONObject, _ f: URL) throws {
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: f.appendingPathComponent("catalog.json"))
    }

    /// An adopted binder `tax` with two open items, published once to a spool with an inbox and an outbox.
    func adoptedTax(_ root: URL) throws -> (URL, URL) {
        let f = root.appendingPathComponent("tax", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let text = #"{"meta":{"schema_version":2,"name":"tax"},"documents":[],"open_items":[\#(item("a-1")),\#(item("a-2"))],"processing_log":[]}"#
        try Data(text.utf8).write(to: f.appendingPathComponent("catalog.json"))
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let s = root.appendingPathComponent("spool")
        for sub in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: s.appendingPathComponent(sub), withIntermediateDirectories: true)
            chmod(s.appendingPathComponent(sub).path, 0o700)
        }
        chmod(s.path, 0o700)
        guard case .published = try HubLane.publish(f, root: s, now: now) else { throw TekaStore.Refused(reason: "first publish failed") }
        return (f, s)
    }

    /// Edits open items outside Sprava: `change` runs on each item with the given id.
    func editOutside(_ f: URL, _ id: String, _ change: (inout JSONObject) -> Void) throws {
        var c = try cat(f)
        let items = (c["open_items"]?.arrayValue ?? []).map { v -> JSONValue in
            guard var o = v.objectValue, o["id"] == .string(id) else { return v }
            change(&o)
            return .object(o)
        }
        c.set("open_items", .array(items))
        try write(c, f)
    }

    func sliceText(_ s: URL) throws -> String {
        try String(decoding: Data(contentsOf: s.appendingPathComponent("inbox/tax.agenda.json")), as: UTF8.self)
    }

    func slice(_ s: URL) throws -> JSONValue {
        try JSONParser.parse(try Data(contentsOf: s.appendingPathComponent("inbox/tax.agenda.json"))).value
    }

    func close(_ f: URL, _ id: String) throws {
        let args = JSONObject([(key: "id", value: .string(id)), (key: "closed_at", value: .str("2026-10-07T10:00:00Z")),
                               (key: "source", value: .str("user"))])
        try TekaStore(folder: f).apply([.init(op: "complete", args: args, actor: user)], now: now)
    }

    // A closed item is shown once as `done` with nothing of its own but its id (binder-v0 §8.2): a tag and a hub
    // title an outside edit gave a redacted item before it closed never reach the hub, whether or not the hub saw the
    // item. A closed item the hub saw keeps the id it saw; one it never saw is aliased, as redacted.
    @Test func aClosedRedactedItemPublishesNoUnconfirmedTagOrTitle() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try editOutside(f, "a-1") {
            $0.set("redact", .bool(true))
            $0.set("tags", .array([.str("invented-private-tag")]))
            $0.set("slice_title", .str("Invented outside title"))
        }
        var c = try cat(f)
        var items = c["open_items"]?.arrayValue ?? []
        items.append(try JSONParser.parse(Data(#"{"id":"a-3","title":"Invented new task","status":"open","priority":"normal","due":"2026-11-02","redact":true,"tags":["invented-private-tag"],"slice_title":"Invented outside title"}"#.utf8)).value)
        c.set("open_items", .array(items))
        try write(c, f)
        try close(f, "a-1")
        try close(f, "a-3")

        #expect(try HubLane.publish(f, root: s, now: now) == .published(items: 3, overwrittenByOther: false))
        let text = try sliceText(s)
        #expect(!text.contains("invented-private-tag"))
        #expect(!text.contains("Invented outside title"))
        #expect(!text.contains("Invented new task"))
        let published = try slice(s)["items"]?.arrayValue ?? []
        let done = published.filter { $0["status"] == .str("done") }
        #expect(done.count == 2)
        #expect(done.allSatisfy { $0["title"] == .str("[closed]") && $0["tags"] == .array([]) && $0["due"] == .null })
        #expect(done.contains { $0["id"] == .str("tax-a-1") })              // the id the hub saw
        #expect(!done.contains { $0["id"] == .str("tax-a-3") })             // never seen, redacted: aliased
        // Shown once: the next publish leaves them out.
        _ = try HubLane.publish(f, root: s, now: now, force: true)
        #expect(try slice(s)["items"]?.arrayValue?.count == 1)
    }

    // A slice_title an outside edit added to a redacted item is not published; the item stays `[redacted]`. One the
    // person set with their own op is.
    @Test func anOutsideSliceTitleOnARedactedItemIsNotPublished() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try editOutside(f, "a-1") { $0.set("redact", .bool(true)) }
        _ = try HubLane.publish(f, root: s, now: now)
        try editOutside(f, "a-1") { $0.set("slice_title", .str("Invented outside title")) }
        _ = try HubLane.publish(f, root: s, now: now, force: true)
        #expect(!(try sliceText(s)).contains("Invented outside title"))
        #expect(try slice(s)["items"]?.arrayValue?.first?["title"] == .str("[redacted]"))

        let set = JSONObject([(key: "id", value: .str("a-1")), (key: "set", value: .obj([("slice_title", .str("Invented hub title"))]))])
        try TekaStore(folder: f).apply([.init(op: "update_item", args: set, actor: user)], now: now)
        _ = try HubLane.publish(f, root: s, now: now, force: true)
        #expect(try slice(s)["items"]?.arrayValue?.first?["title"] == .str("Invented hub title"))
    }

    // A stamped catalog whose meta.disclosure was removed outside says nothing about what may leave it: its slice is
    // withdrawn by the record in its cursors, it publishes nothing more, and its outbox is not drained.
    @Test func aStampWithoutDisclosureWithdrawsAndDoesNotDrain() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        var c = try cat(f)
        var meta = c["meta"]?.objectValue ?? JSONObject()
        meta.set("format", .str("teka"))
        meta.set("format_version", .str("0"))
        meta.remove("disclosure")
        c.set("meta", .object(meta))
        try write(c, f)
        #expect(Teka.read(f).federationBlocked)

        let outbox = s.appendingPathComponent("outbox/tax.intake.json")
        let body = Data(#"{"completions":[{"id":"tax-a-1","action":"done","at":"2026-10-07T09:00:00Z"}]}"#.utf8)
        try body.write(to: outbox)
        let out = HubLane.sync(f, root: s, now: now)
        #expect(out.drainError == nil && out.drained == HubLane.DrainResult())
        #expect(out.published == .removed)
        #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax.agenda.json").path))
        #expect(try Data(contentsOf: outbox) == body)
        #expect(try cat(f)["open_items"]?.arrayValue?.count == 2)
        // Nothing is recorded any more, so a later pass says the binder needs attention and writes nothing.
        #expect(try HubLane.publish(f, root: s, now: now) == .notPublished("the binder needs attention"))
        #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax.agenda.json").path))

        // An invalid level is treated the same way.
        meta.set("disclosure", .str("invented-level"))
        c.set("meta", .object(meta))
        try write(c, f)
        #expect(Teka.read(f).federationBlocked)
        #expect(try HubLane.publish(f, root: s, now: now) == .notPublished("the binder needs attention"))
    }

    // The slice key is 32 random bytes, never all zero.
    @Test func theSliceKeyIsRandom() throws {
        let root = try scratch()
        let (f, _) = try adoptedTax(root)
        let key = try Data(contentsOf: f.appendingPathComponent(".sprava/slice-key"))
        #expect(key.count == 32 && key.contains { $0 != 0 })
    }
}

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

    // MARK: - The review of the hub layer

    func adoptedTax(_ root: URL, items: [String] = ["a-1", "a-2"]) throws -> (URL, URL) {
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: items.map { item($0) }))
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let s = try spool(root)
        guard case .published = try HubLane.publish(f, root: s, now: now) else { throw TekaStore.Refused(reason: "first publish failed") }
        return (f, s)
    }

    /// An outside edit of `meta.disclosure`, which narrows at once.
    func narrowOutside(_ f: URL, to level: String) throws {
        var c = try cat(f)
        var meta = c["meta"]?.objectValue ?? JSONObject()
        meta.set("disclosure", .string(level))
        c.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: f.appendingPathComponent("catalog.json"))
    }

    func openIDs(_ f: URL) throws -> [JSONValue] { try cat(f)["open_items"]?.arrayValue?.compactMap { $0["id"] } ?? [] }

    // Hub 1. Each matching rule is tried across every item before the next: `demo-demo-a` closes that item, never
    // `demo-a` by the prefix rule, and once it is closed a repeat of it is acknowledged without touching `demo-a`.
    @Test func aRawIDMatchWinsOverAnotherItemsPrefixedID() throws {
        let root = try scratch()
        let f = try binder(root, name: "demo", catalog: lifeproj(name: "demo", items: [item("demo-a"), item("demo-demo-a")]))
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let s = try spool(root)
        let outbox = s.appendingPathComponent("outbox/demo.intake.json")
        let body = Data(#"{"completions":[{"id":"demo-demo-a","action":"done","at":"2026-10-07T09:00:00Z"}]}"#.utf8)
        try body.write(to: outbox)
        #expect(try HubLane.drain(f, root: s, now: now).applied == 1)
        #expect(try openIDs(f) == [.str("demo-a")])
        try body.write(to: outbox)
        let again = try HubLane.drain(f, root: s, now: now)
        #expect(again.applied == 0 && again.acknowledged == 1)
        #expect(try openIDs(f) == [.str("demo-a")])
    }

    func rename(_ f: URL, to name: String) throws -> URL {
        let moved = f.deletingLastPathComponent().appendingPathComponent(name, isDirectory: true)
        try FileManager.default.moveItem(at: f, to: moved)
        let args = JSONObject([(key: "name", value: .string(name)), (key: "former", value: .string(f.lastPathComponent)),
                               (key: "until", value: .str("2027-01-01"))])
        try TekaStore(folder: moved).apply([.init(op: "rename_teka", args: args, actor: user)], now: now)
        return moved
    }

    // Hub 2. After a rename the slice under the former name goes when the new one is published, and the former
    // name's outbox is still drained, with ids prefixed by the former name.
    @Test func aRenameMovesTheSliceAndDrainsTheFormerOutbox() throws {
        let root = try scratch()
        let (old, s) = try adoptedTax(root)
        let f = try rename(old, to: "tax-new")
        #expect(try HubLane.publish(f, root: s, now: now) == .published(items: 2, overwrittenByOther: false))
        #expect(FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax-new.agenda.json").path))
        #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax.agenda.json").path))

        let former = s.appendingPathComponent("outbox/tax.intake.json")
        try Data(#"{"completions":[{"id":"tax-a-1","action":"done","at":"2026-10-07T09:00:00Z"}]}"#.utf8).write(to: former)
        #expect(try HubLane.drain(f, root: s, now: now).applied == 1)
        #expect(try openIDs(f) == [.str("a-2")])
        #expect(!FileManager.default.fileExists(atPath: former.path))
    }

    // Hub 2. A narrowing right after a rename withdraws the slice still under the former name.
    @Test func aWithdrawalAfterARenameRemovesTheFormerSlice() throws {
        let root = try scratch()
        let (old, s) = try adoptedTax(root)
        let f = try rename(old, to: "tax-new")
        try narrowOutside(f, to: "none")
        #expect(try HubLane.publish(f, root: s, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax.agenda.json").path))
    }

    final class Outcome: @unchecked Sendable {
        var result: Result<HubLane.PublishResult, Error>?
    }

    // Hub 3. A publish reads the binder under its lock: one that starts while another program holds the lock sees
    // the narrowing made meanwhile and withdraws, instead of writing what it would have read before.
    @Test func aPublishWaitsForTheLockAndSeesTheNarrowing() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let fd = open(f.appendingPathComponent(".teka.lock").path, O_RDWR | O_CREAT, 0o600)
        #expect(fd >= 0 && flock(fd, LOCK_EX) == 0)
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        let (folder, spool, at) = (f, s, now)
        Thread.detachNewThread {
            outcome.result = Result { try HubLane.publish(folder, root: spool, now: at, force: true) }
            done.signal()
        }
        usleep(300_000)
        try narrowOutside(f, to: "none")
        flock(fd, LOCK_UN)
        close(fd)
        done.wait()
        #expect(try outcome.result?.get() == .removed)
        #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax.agenda.json").path))
    }

    // Hub 3. A binder whose lock cannot be taken still withdraws.
    @Test func aDamagedLockStillWithdraws() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let lock = f.appendingPathComponent(".teka.lock")
        try? FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        try narrowOutside(f, to: "none")
        #expect(try HubLane.publish(f, root: s, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: s.appendingPathComponent("inbox/tax.agenda.json").path))
    }

    // Hub 4. A completion the hub adds while the replacement is written and flushed survives: the outbox is
    // compared just before the rename, and the acknowledgement starts again from the hub's version.
    @Test func aHubWriteDuringTheFlushSurvivesTheAcknowledgement() throws {
        let root = try scratch()
        let file = root.appendingPathComponent("tax.intake.json")
        let applied: [(String, JSONValue?)] = [("tax-a-1", .str("2026-10-07T09:00:00Z"))]
        for items in [#""items":[{"title":"routed capture"}],"#, ""] {
            let first = #"{"id":"tax-a-1","action":"done","at":"2026-10-07T09:00:00Z"}"#
            let added = #"{"id":"tax-a-2","action":"done","at":"2026-10-07T09:05:00Z"}"#
            try Data(#"{\#(items)"completions":[\#(first)]}"#.utf8).write(to: file)
            var calls = 0
            let removed = try HubLane.acknowledge(file: file, applied: applied) {
                calls += 1
                if calls == 1 { try? Data(#"{\#(items)"completions":[\#(first),\#(added)]}"#.utf8).write(to: file) }
            }
            #expect(removed == 1 && calls == 2)
            let left = try JSONParser.parse(try Data(contentsOf: file)).value
            #expect(left["completions"]?.arrayValue?.compactMap { $0["id"] } == [.str("tax-a-2")])
        }
    }

    // Hub 5. A collection an outside edit made other than a list of objects refuses the publish; the last slice stays.
    @Test func aMalformedItemCollectionIsNotPublishedAsEmpty() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let original = try cat(f)
        for bad: JSONValue in [.obj([("a", .str("b"))]), .array((original["open_items"]?.arrayValue ?? []) + [.str("junk")])] {
            var c = original
            c.set("open_items", bad)
            try Data(JSONWriter.pretty(.object(c)).utf8).write(to: f.appendingPathComponent("catalog.json"))
            #expect(throws: TekaStore.Refused.self) { try HubLane.publish(f, root: s, now: now, force: true) }
            let slice = try JSONParser.parse(try Data(contentsOf: s.appendingPathComponent("inbox/tax.agenda.json"))).value
            #expect(slice["items"]?.arrayValue?.count == 2)
        }
    }
}

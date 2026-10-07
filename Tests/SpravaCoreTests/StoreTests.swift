import Darwin
import Foundation
import Testing
@testable import SpravaCore

@Suite(.serialized) struct StoreTests {
    let user = JSONObject([(key: "kind", value: .str("user"))])
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    func adopted(_ fixture: String = "sprava-v0") throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: fixture) { folder in
            try Data("# dashboard kept by hand\n".utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
        }
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject([(key: "checker", value: .str("none"))]),
                        owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        return (folder, store)
    }

    func catalog(_ folder: URL) throws -> JSONObject {
        try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue!
    }

    func newItem(_ id: String) -> JSONObject {
        JSONObject([("id", JSONValue.str(id)), ("title", .str("Call the notary")), ("status", .str("open")),
                    ("priority", .str("normal")), ("due", .str("2026-10-12")),
                    ("created_at", .str("2026-10-07T09:00:00Z")), ("updated_at", .str("2026-10-07T09:00:00Z"))]
            .map { (key: $0.0, value: $0.1) })
    }

    @Test func adoptionChangesNothingButSprava() throws {
        let (folder, store) = try adopted()
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(names == [".sprava", ".teka.lock", "DASHBOARD.md", "catalog.json"])
        let original = try Data(contentsOf: folder.appendingPathComponent(".sprava/adopted/catalog.json"))
        #expect(original == (try Data(contentsOf: folder.appendingPathComponent("catalog.json"))))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/adopted/DASHBOARD.md").path))
        let (ops, torn) = try store.readOpLog()
        #expect(ops.count == 1 && !torn)
        #expect(ops[0]["op"] == .str("import_snapshot"))
        #expect(throws: TekaStore.Refused.self) { try store.adopt(survey: JSONObject(), owner: JSONObject()) }
        let mode = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(".sprava").path)[.posixPermissions] as? Int
        #expect(mode == 0o700)
    }

    @Test func appliedOpsReplayAndKeepTheSnapshotCurrent() throws {
        let (folder, store) = try adopted()
        var add = JSONObject()
        add.set("item", .object(newItem("estate-example-2026-030")))
        try store.apply([.init(op: "add_item", args: add, actor: user)], now: now)
        var done = JSONObject()
        done.set("id", .str("estate-example-2026-030"))
        done.set("closed_at", .str("2026-10-07T10:00:00Z"))
        done.set("source", .str("user"))
        try store.apply([.init(op: "complete", args: done, actor: user)], now: now)
        let ops = try store.readOpLog().ops
        #expect(ops.map { $0["op"]?.stringValue ?? "" } == ["import_snapshot", "add_item", "complete"])
        let replayed = try Replay.run(ops)
        let onDisk = try catalog(folder)
        #expect(try Canonical.hash(.object(replayed)) == (try Canonical.hash(.object(onDisk))))
        let snapshot = try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent(".sprava/snapshot.json"))).value
        #expect(snapshot == .object(onDisk))
        // The written catalog is unescaped UTF-8 with two-space indentation and a trailing newline.
        let text = try String(contentsOf: folder.appendingPathComponent("catalog.json"), encoding: .utf8)
        #expect(text.hasSuffix("}\n") && text.contains("\n  \"meta\": {"))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func aRejectedOpWritesNothing() throws {
        let (folder, store) = try adopted()
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        var bad = newItem("estate-example-2026-031")
        bad.remove("due")
        var args = JSONObject()
        args.set("item", .object(bad))
        #expect(throws: TransactionGuard.Rejection.self) { try store.apply([.init(op: "add_item", args: args, actor: user)]) }
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == before)
        #expect(try store.readOpLog().ops.count == 1)
    }

    @Test func aHandEditIsRecordedAsAnExternalEdit() throws {
        let (folder, store) = try adopted()
        // A terminal agent raises an item's priority by hand.
        var c = try catalog(folder)
        var items = c["open_items"]!.arrayValue!
        var first = items[0].objectValue!
        first.set("priority", .str("low"))
        items[0] = .object(first)
        c.set("open_items", .array(items))
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: folder.appendingPathComponent("catalog.json"))

        var undismiss = JSONObject()
        undismiss.set("id", .str("estate-example-2026-011"))
        try store.apply([.init(op: "undismiss", args: undismiss, actor: user)], now: now)
        let ops = try store.readOpLog().ops
        #expect(ops.map { $0["op"]?.stringValue ?? "" } == ["import_snapshot", "external_edit", "undismiss"])
        #expect(ops[1]["args"]?["patch"]?.arrayValue?.first?["path"] == .str("/open_items/0/priority"))
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: false))
        _ = try Replay.run(ops)   // the chain verifies end to end
    }

    @Test func anOverwrittenChangeIsNamed() throws {
        let (folder, store) = try adopted()
        let found = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        var dismiss = JSONObject()
        dismiss.set("id", .str("estate-example-2026-007"))
        try store.apply([.init(op: "dismiss", args: dismiss, actor: user)], now: now)
        // Another program that read the catalog before the change renames its copy over it.
        try found.write(to: folder.appendingPathComponent("catalog.json"))
        var undismiss = JSONObject()
        undismiss.set("id", .str("estate-example-2026-011"))
        try store.apply([.init(op: "undismiss", args: undismiss, actor: user)], now: now)
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: true))
    }

    @Test func aWriteCutShortIsRolledForward() throws {
        let (folder, store) = try adopted()
        let catalogBefore = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let snapshotBefore = try Data(contentsOf: folder.appendingPathComponent(".sprava/snapshot.json"))
        var dismiss = JSONObject()
        dismiss.set("id", .str("estate-example-2026-007"))
        try store.apply([.init(op: "dismiss", args: dismiss, actor: user)], now: now)
        // Simulate a crash between the op-log append and the rename: put the old catalog and snapshot back.
        try catalogBefore.write(to: folder.appendingPathComponent("catalog.json"))
        try snapshotBefore.write(to: folder.appendingPathComponent(".sprava/snapshot.json"))
        var undismiss = JSONObject()
        undismiss.set("id", .str("estate-example-2026-011"))
        try store.apply([.init(op: "undismiss", args: undismiss, actor: user)], now: now)
        #expect(store.lastAbsorbed == .rolledForward(1))
        let ops = try store.readOpLog().ops
        #expect(!ops.contains { $0["op"] == .str("external_edit") })
        let c = try catalog(folder)
        #expect(c["open_items"]!.arrayValue!.first { $0["id"] == .str("estate-example-2026-007") }?["dismissed"] == .bool(true))
    }

    @Test func aTornTailIsSetAsideAndIgnored() throws {
        let (folder, store) = try adopted()
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        let handle = try FileHandle(forWritingTo: log)
        handle.seekToEndOfFile()
        handle.write(Data("{\"id\":\"half".utf8))
        try handle.close()
        #expect(try store.readOpLog().torn)
        var dismiss = JSONObject()
        dismiss.set("id", .str("estate-example-2026-007"))
        try store.apply([.init(op: "dismiss", args: dismiss, actor: user)], now: now)
        let (ops, torn) = try store.readOpLog()
        #expect(!torn && ops.count == 2)
        let tornDir = folder.appendingPathComponent(".sprava/torn")
        #expect(try FileManager.default.contentsOfDirectory(atPath: tornDir.path).count == 1)
    }

    @Test func aHeldLockMakesTheBinderBusy() throws {
        let (folder, store) = try adopted()
        let fd = open(folder.appendingPathComponent(".teka.lock").path, O_RDWR)
        #expect(flock(fd, LOCK_EX | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        #expect(throws: TekaStore.Busy.self) { try store.withLock(timeout: 0.3) {} }
    }
}

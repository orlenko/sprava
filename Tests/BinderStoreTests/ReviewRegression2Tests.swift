import BinderFormat
@testable import BinderStore
import Darwin
import Foundation
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

    func complete(_ id: String) -> TekaStore.OpBody {
        .init(op: "complete", args: JSONObject([(key: "id", value: .string(id)), (key: "closed_at", value: .str("2026-10-07T00:00:00Z")),
                                                (key: "source", value: .str("user"))]), actor: user)
    }

    func note(_ id: String, _ text: String) -> TekaStore.OpBody {
        .init(op: "update_item", args: JSONObject([(key: "id", value: .string(id)), (key: "set", value: .obj([("notes", .string(text))]))]), actor: user)
    }

    // 2. A lock-skipping editor must never break the hash chain; replay and undo keep working.
    @Test func aConcurrentEditorNeverBreaksTheChain() throws {
        let root = try scratch()
        let texts = ["normal", "high", "low"].map { lifeproj(name: "tax", items: [item("a-1", priority: $0), item("b-1", "Other")]) }
        let f = try binder(root, name: "tax", catalog: texts[0])
        let store = TekaStore(folder: f)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: Date())
        let stop = StopFlag()
        let editor = Thread {
            var i = 0
            while !stop.get() {
                i += 1
                let tmp = f.appendingPathComponent("editor.tmp")
                try? Data(texts[i % 3].utf8).write(to: tmp)
                rename(tmp.path, f.appendingPathComponent("catalog.json").path)
                usleep(UInt32.random(in: 200...3000))
            }
        }
        editor.start()
        var applied = 0
        for n in 0..<80 {
            if (try? store.apply([note("b-1", "n\(n)")])) != nil { applied += 1 }
        }
        stop.set()
        Thread.sleep(forTimeInterval: 0.05)
        let ops = try store.readOpLog().ops
        // A change seen after the log flush aborts the batch and retries it (architecture 4.2 step 9), so against an
        // editor that rewrites the file every millisecond or two only some batches get through; none may break the chain.
        #expect(applied > 0, "applied \(applied)")
        _ = try Replay.run(ops)
        // The editor overwrote the notes it raced with, so undo is shown on a change made after it stopped.
        let last = try #require(try store.apply([note("b-1", "after")]).first)
        _ = try store.undo(opID: last["id"]!.stringValue!)
        _ = try Replay.run(try store.readOpLog().ops)
    }

    // 4. A batch cut short at a line boundary is cut from the log before the next append.
    @Test func aShortBatchIsCutBeforeTheNextAppend() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("a-1")]))
        let store = TekaStore(folder: f)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let opsURL = f.appendingPathComponent(".sprava/ops.ndjson")
        let snap = f.appendingPathComponent(".sprava/snapshot.json")
        let savedLog = try Data(contentsOf: opsURL), savedCat = try Data(contentsOf: f.appendingPathComponent("catalog.json")),
            savedSnap = try Data(contentsOf: snap)
        func add(_ id: String) -> TekaStore.OpBody {
            var it = try! JSONParser.parse(item(id)).value.objectValue!
            it.set("created_at", .str("2026-10-07T00:00:00Z"))
            it.set("updated_at", .str("2026-10-07T00:00:00Z"))
            return .init(op: "add_item", args: JSONObject([(key: "item", value: .object(it))]), actor: user)
        }
        let lines = try store.apply([add("b-1"), add("b-2")], batch: "batch-x", now: now)
        try (savedLog + Data((JSONWriter.compact(.object(lines[0])) + "\n").utf8)).write(to: opsURL)
        try savedCat.write(to: f.appendingPathComponent("catalog.json"))
        try savedSnap.write(to: snap)
        try store.apply([add("c-1")], now: now)
        let ops = try store.readOpLog().ops
        #expect(!ops.contains { $0["args"]?["item"]?["id"] == .str("b-1") })
        _ = try Replay.run(ops)
        let torn = try FileManager.default.contentsOfDirectory(atPath: f.appendingPathComponent(".sprava/torn").path)
        #expect(torn.count == 1)
    }

    // 5. S = b with an outside edit: an abort names the never-applied ops; an overwritten change gets a card.
    @Test func aCrashBeforeRenameThenAnOutsideEditAborts() throws {
        let root = try scratch()
        let text = lifeproj(name: "tax", items: [item("a-1"), item("b-1", "Other")])
        let f = try binder(root, name: "tax", catalog: text)
        let store = TekaStore(folder: f)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let snap = try Data(contentsOf: f.appendingPathComponent(".sprava/snapshot.json"))
        let done = try store.apply([complete("a-1")], now: now)
        try Data(text.utf8).write(to: f.appendingPathComponent("catalog.json"))
        try snap.write(to: f.appendingPathComponent(".sprava/snapshot.json"))
        try Data(text.replacingOccurrences(of: #""Other","status":"open","priority":"normal""#,
                                           with: #""Other","status":"open","priority":"high""#).utf8).write(to: f.appendingPathComponent("catalog.json"))
        try store.apply([note("b-1", "x")], now: now)
        let ops = try store.readOpLog().ops
        let abort = try #require(ops.first { $0["op"] == .str("abort") })
        #expect(abort["args"]?["ops"] == .array([done[0]["id"]!]))
        #expect(ops.first { $0["op"] == .str("external_edit") }?["args"]?["patch"]?.arrayValue?.count == 1)
        _ = try Replay.run(ops)
    }

    // 6. A symlinked .sprava is refused by adoption and by every writer.
    @Test func aLinkedSpravaFolderIsRefused() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("a-1")]))
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.appendingPathComponent(".sprava"), withDestinationURL: outside)
        #expect(throws: TekaStore.Refused.self) {
            try Adoption.adopt(f, inRegistry: false, deviceID: "dev", today: CalendarDate(year: 2026, month: 10, day: 7)!, now: now)
        }
        #expect(throws: TekaStore.Refused.self) { try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    // 10. Adoption survives a mechanical fix the guard would refuse, and still writes its cards.
    @Test func adoptionIsResilientToDuplicateIDs() throws {
        let root = try scratch()
        let waiting = #"{"id":"w-1","title":"Invented wait","status":"waiting","priority":"normal","due":"2026-11-01","waiting_on":"someone"}"#
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [
            waiting, waiting, #"{"id":"d-1","title":"Invented done","status":"done","priority":"normal","due":"2026-09-01"}"#]))
        let r = try Adoption.adopt(f, inRegistry: false, deviceID: "dev", today: CalendarDate(year: 2026, month: 10, day: 7)!, now: now)
        #expect(r.proposals.count >= 1)
        #expect(Teka.read(f).isAdopted)
        #expect(!ProposalStore.list(in: f).isEmpty)
    }

    // 11. Undo of a closure that wrote a closed-duplicate entry reopens the item.
    @Test func undoingAClosedDuplicateWorks() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("dup-1")],
                                                              log: #"[{"id":"dup-1","title":"Invented task","action":"done"}]"#))
        let store = TekaStore(folder: f)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let done = try store.apply([complete("dup-1")], now: now)
        _ = try store.undo(opID: done[0]["id"]!.stringValue!, now: now)
        #expect(try cat(f)["open_items"]?.arrayValue?.count == 1)
    }

    // Lower: agent notes that run lifeproj count as lifeproj reaching the binder.
    @Test func agentNotesThatRunLifeprojAreSeen() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("a-1")]))
        #expect(Adoption.survey(f, inRegistry: false)["lifeproj_can_reach"] == .bool(false))
        try "After each session run `lifeproj publish` here.\n".write(to: f.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        #expect(Adoption.survey(f, inRegistry: false)["lifeproj_can_reach"] == .bool(true))
    }

    // Suspected, now pinned: approving a card whose batch already reached the log applies nothing twice.
    @Test func reapprovingAfterACrashAppliesNothingTwice() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("a-1")]))
        let store = TekaStore(folder: f)
        try store.adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        var add = try JSONParser.parse(Data(item("$new:1", "Added").utf8)).value.objectValue!
        add.remove("due")
        add.set("no_deadline", .bool(true))
        let card = Proposal.make(title: "Add", actor: JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))]),
                                 ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(add))]))])], now: now)
        try ProposalStore.save(card, in: f)
        _ = try store.approve(card, now: now)
        // The crash: the card file still says proposed.
        try ProposalStore.save(card, in: f)
        _ = try store.approve(card, now: now)
        #expect(try cat(f)["open_items"]?.arrayValue?.count == 2)
    }
}

final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

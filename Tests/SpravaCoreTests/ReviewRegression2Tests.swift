import Darwin
import Foundation
import Testing
@testable import SpravaCore

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

    func req(_ c: Commands, _ pairs: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(pairs)), now: now)).value
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

    func note(_ id: String, _ text: String) -> TekaStore.OpBody {
        .init(op: "update_item", args: JSONObject([(key: "id", value: .string(id)), (key: "set", value: .obj([("notes", .string(text))]))]), actor: user)
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
        #expect(applied > 40)
        _ = try Replay.run(ops)
        let last = try #require(ops.last { $0["op"] == .str("update_item") })
        _ = try store.undo(opID: last["id"]!.stringValue!)
    }

    // 3. Approving one card must not make a hand-written card verified, and fact ops are never approved.
    @Test func approvingACardDoesNotTrustOtherFiles() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [
            item("a-1"), #"{"id":"a-2","title":"Invented done","status":"done","priority":"normal","due":"2026-09-01"}"#,
        ], log: #"[{"id":"old-1","title":"Old","action":"done"}]"#))
        let c = Commands(support: root.appendingPathComponent("support"), deviceID: "dev")
        #expect(try req(c, [("command", .str("adopt")), ("binder", .string(f.path))])["ok"] == .bool(true))
        let handID = "0199ffff-0000-7000-8000-000000000001"
        let hand = #"{"id":"\#(handID)","format_version":"0","created_at":"2026-10-07T00:00:00Z","actor":{"kind":"import","client":"sprava/0.1"},"state":"proposed","title":"Stamp","ops":[{"op":"migrate","args":{"from":{},"to":{},"patch":[{"op":"replace","path":"/processing_log","value":[]}]}}]}"#
        try Data(hand.utf8).write(to: f.appendingPathComponent(".sprava/proposals/\(handID).json"))
        func list() throws -> [JSONValue] { try req(c, [("command", .str("proposals")), ("binder", .string(f.path))])["proposals"]!.arrayValue! }
        let real = try #require(try list().first { $0["id"] != .string(handID) && $0["state"] == .str("proposed") })
        #expect(try req(c, [("command", .str("approve")), ("binder", .string(f.path)), ("proposal", real["id"]!), ("digest", real["digest"]!)])["ok"] == .bool(true))
        let after = try #require(try list().first { $0["id"] == .string(handID) })
        #expect(after["verified"] == .bool(false))
        #expect(try req(c, [("command", .str("approve")), ("binder", .string(f.path)), ("proposal", .string(handID)), ("digest", after["digest"]!)])["ok"] == .bool(false))
        #expect(try cat(f)["processing_log"]?.arrayValue?.isEmpty == false)

        // Even a card Sprava wrote cannot carry a fact op, and a stamp never replaces data.
        let store = TekaStore(folder: f)
        let fact = Proposal.make(title: "x", actor: user, ops: [JSONObject([(key: "op", value: .str("external_edit")),
                                                                         (key: "args", value: .obj([("patch", .array([]))]))])], now: now)
        #expect(throws: TekaStore.Refused.self) { try store.approve(fact, now: now) }
        let wipe = JSONObject([(key: "op", value: .str("migrate")), (key: "args", value: .obj([("patch", .array([.obj([
            ("op", .str("replace")), ("path", .str("/processing_log")), ("value", .array([]))])]))]))])
        var line = wipe
        line.set("id", .str("x"))
        line.set("at", .str("2026-10-07T00:00:00Z"))
        let catalog = try cat(f)
        #expect(throws: (any Error).self) { try OpApplier.apply(line, to: catalog) }
        #expect(Proposal.describe(wipe, catalog: nil).contains("processing_log"))
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

    @Test func anOverwrittenChangeIsOfferedAgainAsACard() throws {
        let root = try scratch()
        let text = lifeproj(name: "tax", items: [item("a-1"), item("b-1", "Other")])
        let f = try binder(root, name: "tax", catalog: text)
        let c = Commands(support: root.appendingPathComponent("support"), deviceID: "dev")
        #expect(try req(c, [("command", .str("adopt")), ("binder", .string(f.path))])["ok"] == .bool(true))
        let r = try req(c, [("command", .str("apply")), ("binder", .string(f.path)), ("op", .str("complete")),
                            ("args", .obj([("id", .str("a-1")), ("closed_at", .str("2026-10-07T00:00:00Z")), ("source", .str("user"))]))])
        #expect(r["ok"] == .bool(true), "\(r)")
        // Another program that read the catalog before the change writes back its old copy with its own edit.
        let found = try cat(f)
        var old = found
        old.set("open_items", try JSONParser.parse(Data("[\(item("a-1")),\(item("b-1", "Other", priority: "high"))]".utf8)).value)
        old.set("processing_log", .array([]))
        try Data(JSONWriter.pretty(.object(old)).utf8).write(to: f.appendingPathComponent("catalog.json"))
        let r2 = try req(c, [("command", .str("apply")), ("binder", .string(f.path)), ("op", .str("update_item")),
                             ("args", .obj([("id", .str("b-1")), ("set", .obj([("notes", .str("x"))]))]))])
        #expect(r2["ok"] == .bool(true), "\(r2)")
        let edit = try #require(try TekaStore(folder: f).readOpLog().ops.last { $0["op"] == .str("external_edit") })
        #expect(edit["args"]?["hint"] == .str("a change of yours was overwritten by another program"))
        let cards = try req(c, [("command", .str("proposals")), ("binder", .string(f.path))])["proposals"]!.arrayValue!
        let card = try #require(cards.first { ($0["title"]?.stringValue ?? "").hasPrefix("A change of yours was overwritten") })
        #expect(card["verified"] == .bool(true))
        let approved = try req(c, [("command", .str("approve")), ("binder", .string(f.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        #expect(approved["ok"] == .bool(true), "\(approved)")
        #expect(try cat(f)["open_items"]?.arrayValue?.contains { $0["id"] == .str("a-1") } == false)
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

    // 8. Two watchdog exits for one job open its breaker.
    @Test func twoWatchdogExitsOpenTheBreaker() throws {
        let url = try scratch().appendingPathComponent("breakers.json")
        JobRecords.recordWatchdogExit(job: "hub", url: url, now: now)
        #expect(JobRecords.load(url).jobs["hub"]?.breaker == "closed")
        JobRecords.recordWatchdogExit(job: "hub", url: url, now: now)
        var record = try #require(JobRecords.load(url).jobs["hub"])
        #expect(record.breaker == "open")
        let mayRun = record.mayRun(now: now.addingTimeInterval(30))
        #expect(!mayRun)
        record.finish(.ok, at: now, durationMS: 1, threshold: 3)
        #expect(record.watchdogExits == 0)
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

    // 12. A time-zone change after today's summary time sends today's summary at once.
    @Test func aTimeZoneChangeDoesNotSkipTheSummary() throws {
        var toronto = Calendar(identifier: .gregorian)
        toronto.timeZone = TimeZone(identifier: "America/Toronto")!
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = TimeZone(identifier: "Europe/Paris")!
        let at = toronto.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 7, minute: 30))!
        #expect(nextSummaryTime(now: at, lastSent: "2026-10-06", calendar: paris) == at)
        #expect(nextSummaryTime(now: at, lastSent: "2026-10-07", calendar: paris) > at)
        #expect(nextSummaryTime(now: at, lastSent: "2026-10-06", calendar: toronto) > at)
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

    // 14. Keys that differ only by normalization stay two keys in the canonical form.
    @Test func canonicalKeysCompareByCodeUnits() throws {
        let v = try JSONParser.parse(Data("{\"\u{00E9}\":1,\"e\u{0301}\":2}".utf8)).value
        let w = try JSONParser.parse(Data("{\"\u{00E9}\":9,\"e\u{0301}\":2}".utf8)).value
        #expect(try Canonical.hash(v) != (try Canonical.hash(w)))
        #expect(try Canonical.serialize(v) == "{\"e\u{0301}\":2,\"\u{00E9}\":1}")
    }

    // 15. Recurrence and dismissed are not set in this version.
    @Test func recurrenceCannotBeSet() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("a-1")]))
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let c = Commands(support: root.appendingPathComponent("support"), deviceID: "dev")
        let r = try req(c, [("command", .str("apply")), ("binder", .string(f.path)), ("op", .str("update_item")),
                            ("args", .obj([("id", .str("a-1")), ("set", .obj([("recurrence", .obj([("freq", .str("monthly")), ("day", .int(1))]))]))]))])
        #expect(r["ok"] == .bool(false))
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

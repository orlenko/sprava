import BinderStore
import CaptureTestSupport
import Darwin
import Foundation
@testable import Services
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

    func req(_ c: Commands, _ pairs: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(pairs)), now: now)).value
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

    // 15. Recurrence and dismissed are not set in this version. The binder is owned by this Mac and the item has a
    // due date, so the refusal is this version's rule: never the owner check, nor "recurrence needs a due".
    @Test func recurrenceCannotBeSet() throws {
        let root = try scratch()
        let f = try binder(root, name: "tax", catalog: lifeproj(name: "tax", items: [item("a-1")]))
        let c = Commands(support: root.appendingPathComponent("support"), deviceID: "dev")
        try adoptAsCommand(f, commands: c, now: now, today: CalendarDate(year: 2026, month: 10, day: 7)!)
        let r = try req(c, [("command", .str("apply")), ("binder", .string(f.path)), ("op", .str("update_item")),
                            ("args", .obj([("id", .str("a-1")), ("set", .obj([("recurrence", .obj([("freq", .str("monthly")), ("day", .int(1))]))]))]))])
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.stringValue?.contains("recurrence and dismissed are not set or removed in this version") == true, "\(r)")
    }
}

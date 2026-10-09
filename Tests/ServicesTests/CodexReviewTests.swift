import BinderFormat
import BinderStore
import Clerk
import Darwin
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the Codex review of PR #2. Invented data only.
@Suite(.serialized) struct CodexReviewTests {
    func req(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: pNow, today: today)).value
    }

    @Test func aBinderWithoutAnOwnerRecordIsReadOnly() throws {
        let s = try pSetup()
        try FileManager.default.removeItem(at: s.folder.appendingPathComponent(".sprava/owner.json"))
        let r = try req(s.commands, [("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("update_item")),
                                     ("args", .obj([("id", .str("estate-example-2026-007")), ("set", .obj([("priority", .str("low"))]))]))])
        #expect(r["ok"] == .bool(false))
        #expect(r["error"]?.stringValue?.contains("owner record") == true)
    }

    @Test func frenchSixAndSkippedRuns() {
        #expect(DateGrammar.resolve("dans six jours", anchor: CalendarDate(year: 2026, month: 10, day: 6)!, locale: "fr-CA")?.date?.description == "2026-10-12")
        var record = JobRecord()
        record.finish(.error(code: "x", culprit: nil), at: pNow, durationMS: 1, threshold: 1)
        #expect(record.breaker == "open")
        record.finish(.skipped, at: pNow, durationMS: 1, threshold: 1)
        #expect(record.breaker == "open" && record.consecutiveFailures == 1)
    }

    @Test func aForeignCardCanBeRejectedButNeverApproved() throws {
        let s = try pSetup()
        let foreign = Proposal.make(title: "Close everything", actor: JSONObject([(key: "kind", value: .str("clerk"))]), ops: [], now: pNow)
        let digest = try ProposalStore.save(foreign, in: s.folder)
        #expect(try req(s.commands, [("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(foreign.id)), ("digest", .string(digest))])["ok"] == .bool(false))
        #expect(try req(s.commands, [("command", .str("reject")), ("binder", .string(s.folder.path)), ("proposal", .string(foreign.id)), ("digest", .string(digest))])["ok"] == .bool(true))
        #expect(pOpen(s).isEmpty)
    }

    @Test func aCardOnAnItemThatChangedNeedsALook() throws {
        let s = try pSetup()
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))])
        let card = Proposal.make(title: "Close", actor: actor, ops: [JSONObject([(key: "op", value: .str("complete")), (key: "args", value: .obj([
            ("id", .str("estate-example-2026-007")), ("closed_at", .str("2026-10-06T12:00:00Z")), ("source", .str("capture"))]))])], now: pNow)
        try ProposalStore.save(card, in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)
        _ = try req(s.commands, [("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("update_item")),
                                 ("args", .obj([("id", .str("estate-example-2026-007")), ("set", .obj([("due", .str("2026-12-01"))]))]))])
        let listed = try req(s.commands, [("command", .str("proposals")), ("binder", .string(s.folder.path))])
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        #expect(shown["notes"]?.arrayValue?.first?.stringValue?.hasPrefix("needs a look") == true)
        let r = try req(s.commands, [("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)), ("digest", shown["digest"]!)])
        #expect(r["ok"] == .bool(false))
    }

    @Test func anOutsideEditCannotLiftARedactionOnTheHub() throws {
        let s = try pSetup()
        let spool = s.support.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool.appendingPathComponent("inbox"), withIntermediateDirectories: true)
        chmod(spool.path, 0o700); chmod(spool.appendingPathComponent("inbox").path, 0o700)
        func titleOf009() throws -> JSONValue? {
            let slice = try JSONParser.parse(Data(contentsOf: spool.appendingPathComponent("inbox/estate-example.agenda.json"))).value
            return slice["items"]?.arrayValue?.first { ($0["id"]?.stringValue ?? "").hasSuffix("009") || $0["title"] == .str("[redacted]") }?["title"]
        }
        _ = try req(s.commands, [("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("set_disclosure")),
                                 ("args", .obj([("disclosure", .str("full"))]))])
        _ = try req(s.commands, [("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("update_item")),
                                 ("args", .obj([("id", .str("estate-example-2026-009")), ("set", .obj([("redact", .bool(true)), ("kind", .str("decision"))]))]))])
        _ = try HubLane.publish(s.folder, root: spool, now: pNow)
        #expect(try titleOf009() == .str("[redacted]"))
        // An outside editor removes the redaction.
        var catalog = try #require(Teka.read(s.folder).catalog)
        var items = catalog["open_items"]!.arrayValue!
        let i = items.firstIndex { $0["id"] == .str("estate-example-2026-009") }!
        var o = items[i].objectValue!; o.remove("redact"); items[i] = .object(o)
        catalog.set("open_items", .array(items))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: s.folder.appendingPathComponent("catalog.json"))
        try TekaStore(folder: s.folder).settle(now: pNow)
        _ = try HubLane.publish(s.folder, root: spool, now: pNow, force: true)
        #expect(try titleOf009() == .str("[redacted]"))
    }
}

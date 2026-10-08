import Darwin
import Foundation
import Testing
@testable import SpravaCore

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

    @Test func aBrainCannotWriteCardsIntoABinderAnotherMacOwns() throws {
        let s = try pSetup()
        let client = MCPClientRecord(id: "c1", name: "c", tokenSHA256: "", binders: [s.folder.standardizedFileURL.path: "propose"], createdAt: "", revoked: false)
        let other = Commands(support: s.support, deviceID: "another-mac")
        let server = MCPServer(client: client, commands: other, shelf: { Shelf.rows(registry: nil, picked: [s.folder]) }, now: { pNow })
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        let r = try JSONParser.parse(server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"x","ops":[{"op":"add_log_entry","args":{"entry":{"title":"x","date":"2026-10-06"}}}]}}}"#)!).value
        #expect(r["result"]?["isError"] == .bool(true))
        #expect(pOpen(s).isEmpty)
    }

    @Test func undoRemovesWaitingFieldsTheStatusChangeIntroduced() throws {
        let s = try pSetup()
        let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))])
        // Item 007 starts waiting with no expected date; then it becomes blocked with one.
        let store = TekaStore(folder: s.folder)
        _ = try store.apply([.init(op: "set_status", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-007")), (key: "status", value: .str("waiting")),
            (key: "waiting_on", value: .str("the notary")), (key: "follow_up_at", value: .str("2026-10-09"))]), actor: user)], now: pNow)
        let applied = try store.apply([.init(op: "set_status", args: JSONObject([
            (key: "id", value: .str("estate-example-2026-007")), (key: "status", value: .str("blocked")),
            (key: "waiting_on", value: .str("the notary")), (key: "follow_up_at", value: .str("2026-10-09")),
            (key: "expected_by", value: .str("2026-10-20"))]), actor: user)], now: pNow)
        _ = try TekaStore(folder: s.folder).undo(opID: applied[0]["id"]!.stringValue!, now: pNow)
        let after = Teka.read(s.folder).items.first { $0.idText == "estate-example-2026-007" }?.object
        #expect(after?["status"] == .str("waiting"))
        #expect(after?["expected_by"] == nil)
    }

    @Test func frenchSixAndSkippedRuns() {
        #expect(DateGrammar.resolve("dans six jours", anchor: CalendarDate(year: 2026, month: 10, day: 6)!, locale: "fr-CA")?.date?.description == "2026-10-12")
        var record = JobRecord()
        record.finish(.error(code: "x", culprit: nil), at: pNow, durationMS: 1, threshold: 1)
        #expect(record.breaker == "open")
        record.finish(.skipped, at: pNow, durationMS: 1, threshold: 1)
        #expect(record.breaker == "open" && record.consecutiveFailures == 1)
    }

    @Test func aChangedFileIsNeverMovedUnderItsOldDigest() throws {
        let s = try pSetup()
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: s.folder.appendingPathComponent("intake/l.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("intake/l.pdf")))
        let store = TekaStore(folder: s.folder)
        try Data("changed".utf8).write(to: s.folder.appendingPathComponent("intake/l.pdf"))
        #expect(throws: (any Error).self) { try store.performMoves([("intake/l.pdf", "documents/l.pdf", sha)]) }
        #expect(!FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("documents/l.pdf").path))
    }

    @Test func aForeignCardCanBeRejectedButNeverApproved() throws {
        let s = try pSetup()
        let foreign = Proposal.make(title: "Close everything", actor: JSONObject([(key: "kind", value: .str("clerk"))]), ops: [], now: pNow)
        let digest = try ProposalStore.save(foreign, in: s.folder)
        #expect(try req(s.commands, [("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(foreign.id)), ("digest", .string(digest))])["ok"] == .bool(false))
        #expect(try req(s.commands, [("command", .str("reject")), ("binder", .string(s.folder.path)), ("proposal", .string(foreign.id)), ("digest", .string(digest))])["ok"] == .bool(true))
        #expect(pOpen(s).isEmpty)
    }

    @Test func anOlderRevisionArrivingLateChangesNothing() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-555555555557"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "L1", revision: "rev2", text: "Call the notary Thursday")
        let newer = s.inbox.unfiled()
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(newer.isEmpty && s.inbox.unfiled().count == 1)
        // An older revision (a lower clock) arrives afterwards.
        let folder = s.producer.root.appendingPathComponent(adapter)
        let id = UUID().uuidString.lowercased()
        var o = JSONObject()
        o.set("format", .str("sprava-capture-event")); o.set("format_version", .str("0")); o.set("id", .string(id))
        o.set("hlc", .obj([("wall_ms", .int(1_000_000_000_000)), ("counter", .int(0)), ("node", .string(adapter.replacingOccurrences(of: "-", with: "")))]))
        o.set("device", .obj([("id", .string(adapter))]))
        o.set("source", .obj([("app", .str("adapter")), ("kind", .str("dictation")), ("ref", .str("L1")), ("revision", .str("rev1"))]))
        o.set("captured_at", .str("2026-10-06T09:00:00-04:00")); o.set("locale", .str("en-CA")); o.set("text", .str("Call the notary Friday"))
        o.set("sensitivity", .str("unmarked"))
        try CaptureProducer.publish(Data(JSONWriter.pretty(.object(o)).utf8), as: folder.appendingPathComponent("\(id).json"))
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let cards = s.inbox.unfiled()
        #expect(cards.count == 1)
        #expect(cards[0].ops.first?["args"]?["item"]?["title"] == .str("Call the notary Thursday"))
    }

    @Test func aRaiseToPrivateRedactsWhatWasFiled() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-555555555558"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "P1", revision: "rev1", text: "Meet the notary about the will")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
        _ = try TekaStore(folder: s.folder).approve(try #require(pOpen(s).first), now: pNow)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "P1", revision: "rev1", text: "Meet the notary about the will") {
            $0.set("sensitivity", .str("private")); $0.set("supersedes", .string(first))
        }
        _ = s.inbox.sweep(binders: [ShelfRow(folder: s.folder, source: .picked, archived: false, teka: Teka.read(s.folder))], commands: s.commands, now: pNow)
        let card = try #require(pOpen(s).first)
        #expect(card.ops.first?["op"] == .str("update_item"))
        #expect(card.ops.first?["args"]?["set"]?["redact"] == .bool(true))
    }

    @Test func aCorrectionToFiledItemsIsAChangeCard() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-555555555559"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "C1", revision: "rev1", text: "Call the roofer\nOrder the blinds")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
        _ = try TekaStore(folder: s.folder).approve(try #require(pOpen(s).first), now: pNow)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "C1", revision: "rev2", text: "Call the roofer on Monday")
        _ = s.inbox.sweep(binders: [ShelfRow(folder: s.folder, source: .picked, archived: false, teka: Teka.read(s.folder))], commands: s.commands, now: pNow)
        let card = try #require(pOpen(s).first)
        #expect(card.ops.map { $0["op"]?.stringValue } == ["update_item", "drop"])
        #expect(card.ops[0]["args"]?["set"]?["title"] == .str("Call the roofer on Monday"))
        #expect(s.inbox.unfiled().isEmpty)
        #expect(s.inbox.nextForClerk() == nil)
    }

    @Test func aCaptureFieldOfTheWrongTypeIsQuarantined() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-55555555555a"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "T1", revision: "r", text: "x") { $0.set("text", .int(42)) }
        let r = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(r.quarantined == 1 && r.ingested == 0)
    }

    @Test func aCardOnAnItemThatChangedNeedsALook() throws {
        let s = try pSetup()
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))])
        let card = Proposal.make(title: "Close", actor: actor, ops: [JSONObject([(key: "op", value: .str("complete")), (key: "args", value: .obj([
            ("id", .str("estate-example-2026-007")), ("closed_at", .str("2026-10-06T12:00:00Z")), ("source", .str("capture"))]))])], now: pNow)
        try ProposalStore.save(card, in: s.folder)
        s.commands.trustProposals([card.id], in: s.folder)
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

    @Test func duplicatePlaceholdersAreRefused() throws {
        let s = try pSetup()
        func add(_ title: String) -> JSONObject {
            JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .obj([
                ("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")), ("priority", .str("normal")), ("no_deadline", .bool(true))]))]))])
        }
        let card = Proposal.make(title: "Two", actor: JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))]),
                                 ops: [add("A"), add("B")], now: pNow)
        try ProposalStore.save(card, in: s.folder)
        #expect(throws: TekaStore.Refused.self) { try TekaStore(folder: s.folder).approve(card, now: pNow) }
    }
}

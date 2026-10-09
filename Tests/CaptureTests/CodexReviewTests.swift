import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the Codex review of PR #2. Invented data only.
@Suite(.serialized) struct CodexReviewTests {
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

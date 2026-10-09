import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// A second adopted binder beside the setup's, made from the same invented fixture under another name (its items'
/// ids follow the name).
func secondBinder(_ s: PSetup, name: String = "garden-example") throws -> URL {
    let folder = try makeTeka(fixture: "sprava-v0", folderName: name) { folder in
        let url = folder.appendingPathComponent("catalog.json")
        let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "estate-example", with: name)
        try Data(text.utf8).write(to: url)
    }
    try adoptAsCommand(folder, commands: s.commands, now: pNow, today: today)
    for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: pNow) }
    return folder
}

func rowsOf(_ folders: [URL]) -> [ShelfRow] {
    folders.map { ShelfRow(folder: $0, source: .picked, archived: false, teka: Teka.read($0)) }
}

/// A card as the clerk makes one: its ops each name the span of the note they come from.
func clerkCard(_ s: PSetup, event: String, ops: [JSONObject], in folder: URL) throws -> Proposal {
    let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("invented"))])
    let card = Proposal.make(title: "From the clerk's reading", actor: actor, ops: ops,
                             provenance: JSONObject([(key: "events", value: .array([.string(event)])), (key: "filed_by", value: .str("invented model"))]),
                             now: pNow)
    try ProposalStore.save(card, in: folder)
    try s.commands.trustProposals([card.id], in: folder)
    return card
}

func spanOp(_ op: String, _ args: [(String, JSONValue)], event: String, line: (text: String, start: Int, end: Int)) -> JSONObject {
    JSONObject([(key: "op", value: .string(op)), (key: "args", value: .obj(args)),
                (key: "spans", value: .array([.obj([("event", .string(event)), ("start", .int(line.start)), ("end", .int(line.end))])]))])
}

/// Regressions from the ninth calibrated review of the capture layer: a card is withdrawn only once every source span
/// of every op on it, whatever the op, is carried to a card that replaces it or listed as not filed yet. Invented data.
@Suite(.serialized) struct CalibratedReview9Tests {
    let adapter = "11111111-2222-4333-8444-5555555555f9"
    let note = "Call the invented roofer about the gutter\nPaid the invented notary for the inventory"

    func setup() throws -> (PSetup, URL) {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return (s, try secondBinder(s))
    }

    func event(_ s: PSetup, ref: String, revision: String, text: String) throws -> String {
        try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: revision, text: text)
    }

    /// A two-line note read as the clerk would: line 1 an item added in the first binder (approved), line 2 a change to
    /// an existing item of the second (`second`, still waiting). The code-built card was replaced.
    func readAndSplit(_ s: PSetup, b: URL, ref: String, second: (String, [(String, JSONValue)])) throws -> (String, Proposal) {
        let id = try event(s, ref: ref, revision: "rev1", text: note)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        try s.inbox.discard(try #require(s.inbox.unfiled().first).id)
        let lines = CaptureInbox.lines(of: note)
        let item = JSONValue.obj([("id", .str("$new:1")), ("title", .str("Call the invented roofer about the gutter")), ("status", .str("open")),
                                  ("priority", .str("normal")), ("no_deadline", .bool(true)), ("provenance", .obj([("events", .array([.string(id)]))]))])
        let add = try clerkCard(s, event: id, ops: [spanOp("add_item", [("item", item)], event: id, line: lines[0])], in: s.folder)
        _ = try TekaStore(folder: s.folder).approve(add, now: pNow)
        let change = try clerkCard(s, event: id, ops: [spanOp(second.0, second.1, event: id, line: lines[1])], in: b)
        return (id, change)
    }

    func open(_ folder: URL) -> [Proposal] { ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" } }

    /// Whether a card waiting in `folder` still asks for `op` on `item`, from line 2 of `revision`'s words.
    func carries(_ folder: URL, op: String, item: String, revision: String, text: String) -> Bool {
        let line = CaptureInbox.lines(of: text)[1]
        return open(folder).contains { p in
            p.raw["provenance"]?["events"] == .array([.string(revision)]) && p.ops.contains { o in
                o["op"] == .string(op) && o["args"]?["id"] == .string(item) && o["spans"]?.arrayValue?.contains {
                    $0["event"] == .string(revision) && $0["start"] == .int(line.start)
                } == true
            }
        }
    }

    @Test func aCorrectionOfOneLineKeepsAWaitingCompletionInAnotherBinder() throws {
        let (s, b) = try setup()
        let (_, change) = try readAndSplit(s, b: b, ref: "C1", second: ("complete", [
            ("id", .str("garden-example-2026-007")), ("closed_at", .str("2026-10-06T13:00:00Z")), ("source", .str("capture"))]))
        let text = "Call the invented roofer about the gutter on Monday\nPaid the invented notary for the inventory"
        let revision = try event(s, ref: "C1", revision: "rev2", text: text)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(!open(b).contains { $0.id == change.id }, "the card from the earlier words gives way")
        #expect(carries(b, op: "complete", item: "garden-example-2026-007", revision: revision, text: text),
                "the completion its unchanged line asks for still waits in its binder")
    }

    @Test func aBinderAwayDuringACorrectionGetsItsLineCarriedWhenItIsBack() throws {
        let (s, b) = try setup()
        let (_, change) = try readAndSplit(s, b: b, ref: "C2", second: ("update_item", [
            ("id", .str("garden-example-2026-007")), ("set", .obj([("due", .str("2026-10-20"))]))]))
        let away = b.deletingLastPathComponent().appendingPathComponent("away")
        try FileManager.default.moveItem(at: b, to: away)
        let text = "Call the invented roofer about the gutter on Monday\nPaid the invented notary for the inventory"
        let revision = try event(s, ref: "C2", revision: "rev2", text: text)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(s.inbox.hasDeferredWork(in: b))
        try FileManager.default.moveItem(at: away, to: b)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(!open(b).contains { $0.id == change.id })
        #expect(carries(b, op: "update_item", item: "garden-example-2026-007", revision: revision, text: text),
                "the date change its unchanged line asks for is carried when the binder is back")
        #expect(!s.inbox.hasDeferredWork(in: b))
    }

    @Test func aChangedLineIsListedAsNotFiledYetRatherThanLost() throws {
        let (s, b) = try setup()
        let (_, change) = try readAndSplit(s, b: b, ref: "C3", second: ("complete", [
            ("id", .str("garden-example-2026-007")), ("closed_at", .str("2026-10-06T13:00:00Z")), ("source", .str("capture"))]))
        let text = "Call the invented roofer about the gutter\nPaid the invented notary for the inventory and the deed"
        let revision = try event(s, ref: "C3", revision: "rev2", text: text)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(!open(b).contains { $0.id == change.id })
        let waiting = open(b) + open(s.folder) + s.inbox.unfiled()
        #expect(waiting.flatMap { s.inbox.notFiled($0) }.contains("Paid the invented notary for the inventory and the deed")
                || waiting.contains { $0.ops.contains { $0["args"]?["item"]?["title"] == .str("Paid the invented notary for the inventory and the deed") } })
        _ = revision
    }

    @Test func aCardWhoseCarryCannotBeMadeStays() throws {
        let (s, b) = try setup()
        let (_, change) = try readAndSplit(s, b: b, ref: "C4", second: ("complete", [
            ("id", .str("garden-example-2026-007")), ("closed_at", .str("2026-10-06T13:00:00Z")), ("source", .str("capture"))]))
        // The binder's cards can be read but no new one saved there: nothing is withdrawn, and the work stays owed.
        chmod(ProposalStore.dir(b).path, 0o500)
        defer { chmod(ProposalStore.dir(b).path, 0o700) }
        let text = "Call the invented roofer about the gutter on Monday\nPaid the invented notary for the inventory"
        let revision = try event(s, ref: "C4", revision: "rev2", text: text)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(open(b).contains { $0.id == change.id })
        chmod(ProposalStore.dir(b).path, 0o700)
        _ = s.inbox.sweep(binders: rowsOf([s.folder, b]), commands: s.commands, now: pNow)
        #expect(!open(b).contains { $0.id == change.id })
        #expect(carries(b, op: "complete", item: "garden-example-2026-007", revision: revision, text: text))
    }
}

import BinderFormat
import BinderStore
import Darwin
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// Approving cards through the command table: approving one card trusts no other file, a change another program
/// overwrote comes back as a card, and recurrence cannot be set. Invented data only.
@Suite(.serialized) struct CardApprovalTests {
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

    // 12. A time-zone change after today's summary time sends today's summary at once.

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
}

/// What the person sends with an approval is taken whole or the approval is refused: a change on the card that cannot
/// be read never approves the card unchanged, and their words about a document are never cut. Invented data only.
@Suite(.serialized) struct ApprovalRequestTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    let clerk = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))])

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func adopted() throws -> (Commands, URL) {
        let c = Commands(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-request-\(UUID().uuidString)"),
                         deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        #expect(try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])["ok"] == .bool(true))
        return (c, folder)
    }

    /// Saves a card Sprava wrote with `ops` and returns the request fields that approve it as listed.
    func approval(_ ops: [JSONObject], _ c: Commands, _ folder: URL) throws -> (Proposal, [(String, JSONValue)]) {
        let card = Proposal.make(title: "Invented card", actor: clerk, ops: ops, now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        return (card, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", .string(card.id)),
                       ("digest", shown["digest"]!)])
    }

    func state(_ id: String, in folder: URL) -> String? { ProposalStore.list(in: folder).first { $0.0.id == id }?.0.state }

    @Test func aChangeOnTheCardThatCannotBeReadRefusesTheApproval() throws {
        let add = JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .obj([
            ("id", .str("$new:1")), ("title", .str("Invented errand")), ("status", .str("open")), ("priority", .str("normal")),
            ("no_deadline", .bool(true))]))]))])
        let (c, folder) = try adopted()
        let (card, approve) = try approval([add], c, folder)
        for wrong: (String, JSONValue) in [("edits", .obj([("index", .int(0)), ("skip", .bool(true))])), ("edits", .null),
                                           ("document_folder", .int(3)), ("obtained", .str("email"))] {
            let r = try call(c, approve + [wrong])
            #expect(r["ok"] == .bool(false), "\(wrong.0): \(r)")
            #expect(state(card.id, in: folder) == "proposed")
            #expect(!Teka.read(folder).items.contains { $0.title == "Invented errand" })
        }
        #expect(try call(c, approve)["ok"] == .bool(true))
        #expect(Teka.read(folder).items.contains { $0.title == "Invented errand" })
    }

    @Test func whatThePersonSaidIsKeptWholeOrRefused() throws {
        let (c, folder) = try adopted()
        let intake = folder.appendingPathComponent("intake", isDirectory: true)
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("invented letter".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        let filing = JSONObject([(key: "op", value: .str("file_document")), (key: "args", value: .obj([
            ("document", .obj([("id", .str("estate-example-doc-2026-003")), ("title", .str("Invented letter")),
                               ("path", .str("documents/letter.pdf")), ("sha256", .string(sha))])),
            ("from", .str("intake/letter.pdf"))]))])
        let (card, approve) = try approval([filing], c, folder)
        func filed() -> JSONValue? {
            Teka.read(folder).catalog?["documents"]?.arrayValue?.first { $0["path"] == .str("documents/letter.pdf") }
        }

        let tooLong = String(repeating: "Invented words about the letter. ", count: 19)   // 627 characters
        let refused = try call(c, approve + [("obtained", .obj([("channel", .str("paper")), ("said", .string(tooLong))]))])
        #expect(refused["ok"] == .bool(false), "\(refused)")
        #expect(filed() == nil && state(card.id, in: folder) == "proposed")
        #expect(FileManager.default.fileExists(atPath: intake.appendingPathComponent("letter.pdf").path))

        let whole = String(repeating: "w", count: 500)
        let r = try call(c, approve + [("obtained", .obj([("channel", .str("paper")), ("said", .string(whole))]))])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(filed()?["provenance"]?["obtained"]?["said"] == .string(whole))
    }
}

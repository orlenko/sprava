import BinderFormat
import BinderStore
@testable import Brains
import Capture
import Darwin
import Extract
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// What a brain may see and send: a binder name two binders share is refused, open counts match the Now page,
/// invisible characters are refused, a read-only client cannot finish a reading, at most fifty ops a proposal and at
/// most 64 entries in any object or list of an op.
/// Invented data only.
@Suite(.serialized) struct MCPScopeTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    struct Setup {
        let server: MCPServer
        let folders: [URL]
        let commands: Commands
        var folder: URL { folders[0] }
    }

    func adopted(mutate: ((inout [String: Any]) -> Void)? = nil) throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        if let mutate {
            let url = folder.appendingPathComponent("catalog.json")
            var catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            mutate(&catalog)
            try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted]).write(to: url)
        }
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        return folder
    }

    func setup(level: String = "propose", binders: Int = 1, documents: Bool = false, mutate: ((inout [String: Any]) -> Void)? = nil) throws -> Setup {
        let folders = try (0..<binders).map { _ in try adopted(mutate: mutate) }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-mcp-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "t")
        let client = MCPClientRecord(id: "claude-code-1", name: "Claude Code", tokenSHA256: "",
                                     binders: Dictionary(uniqueKeysWithValues: folders.map { ($0.standardizedFileURL.path, level) }),
                                     createdAt: "", revoked: false, documents: documents ? true : nil)
        let now = self.now
        let server = MCPServer(client: client, commands: commands, shelf: { Shelf.rows(registry: nil, picked: folders) }, now: { now })
        return Setup(server: server, folders: folders, commands: commands)
    }

    func tool(_ s: MCPServer, _ name: String, _ arguments: JSONValue) throws -> JSONValue {
        let line = JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", .int(1)), ("method", .str("tools/call")),
                                            ("params", .obj([("_meta", .obj([("io.modelcontextprotocol/protocolVersion", .str("2026-07-28"))])),
                                                             ("name", .string(name)), ("arguments", arguments)]))]))
        let reply = try #require(s.handle(line: line))
        return try #require(try JSONParser.parse(reply).value["result"])
    }

    func addItem(_ n: Int, title: String = "Call the notary") -> JSONValue {
        .obj([("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .string("$new:\(n)")), ("title", .string(title)), ("status", .str("open")),
                                                                     ("priority", .str("normal")), ("no_deadline", .bool(true))]))]))])
    }

    func propose(_ s: MCPServer, title: String = "Invented card", ops: [JSONValue], requestID: String? = nil) throws -> JSONValue {
        var fields: [(String, JSONValue)] = [("binder", .str("estate-example")), ("title", .string(title)), ("ops", .array(ops))]
        if let requestID { fields.append(("request_id", .string(requestID))) }
        return try tool(s, "propose_ops", .obj(fields))
    }

    // MARK: - cloud review of #328: request ids and bounded proposal reads

    @Test func aRequestIDReusedForDifferentWorkIsRefused() throws {
        let s = try setup()
        let first = try propose(s.server, title: "Invented card", ops: [addItem(1)], requestID: "invented-request-1")
        #expect(first["isError"] == .bool(false))
        let id = first["structuredContent"]?["proposal_id"]
        // A retry with the same work gets the same card.
        let retry = try propose(s.server, title: "Invented card", ops: [addItem(1)], requestID: "invented-request-1")
        #expect(retry["isError"] == .bool(false) && retry["structuredContent"]?["proposal_id"] == id)
        // Other work under the same id is refused, never reported as proposed.
        let other = try propose(s.server, title: "Other invented card", ops: [addItem(1, title: "Book the movers")], requestID: "invented-request-1")
        #expect(other["isError"] == .bool(true))
        #expect(other["structuredContent"]?["error"]?.stringValue?.contains("differs") == true)
        #expect(ProposalStore.list(in: s.folder).count == 1)
    }

    @Test func proposalLookupsNeverReadTheWholeCollection() throws {
        let s = try setup()
        let made = try propose(s.server, ops: [addItem(1)])
        let id = try #require(made["structuredContent"]?["proposal_id"])
        // More stray files than a bounded read holds.
        let dir = s.folder.appendingPathComponent(".sprava/proposals")
        for _ in 0..<120 { try Data("{}".utf8).write(to: dir.appendingPathComponent("\(UUIDv7.make()).json")) }
        // get_proposal reads the one file it names.
        let got = try tool(s.server, "get_proposal", .obj([("binder", .str("estate-example")), ("proposal_id", id)]))
        #expect(got["isError"] == .bool(false) && got["structuredContent"]?["state"] == .str("proposed"))
        // A request id needs the collection, which is refused rather than read whole.
        let retried = try propose(s.server, ops: [addItem(2)], requestID: "invented-request-2")
        #expect(retried["isError"] == .bool(true))
        #expect(retried["structuredContent"]?["error"]?.stringValue?.contains("cannot be read safely") == true)
    }

    // MARK: - p8-Q7: a name two binders share is refused

    @Test func aSharedBinderNameIsRefused() throws {
        let s = try setup(binders: 2)
        let r = try propose(s.server, ops: [addItem(1)])
        #expect(r["isError"] == .bool(true))
        #expect(r["structuredContent"]?["error"]?.stringValue?.contains("share this name") == true)
        for folder in s.folders { #expect(ProposalStore.list(in: folder).isEmpty) }
    }

    // MARK: - qJwVi: open counts leave out dismissed and closed items

    @Test func theOpenCountMatchesTheNowPage() throws {
        let s = try setup { catalog in
            var items = catalog["open_items"] as? [[String: Any]] ?? []
            if let i = items.firstIndex(where: { $0["id"] as? String == "estate-example-2026-010" }) { items[i]["status"] = "done" }
            catalog["open_items"] = items
        }
        let listed = try tool(s.server, "list_binders", .obj([]))
        // Six entries: one dismissed, one left at status done.
        #expect(Teka.read(s.folder).items.count == 6)
        #expect(listed["structuredContent"]?["binders"]?.arrayValue?.first?["open"] == .int(4))
    }

    // MARK: - qfZ26: text with invisible or direction-changing characters is refused

    @Test func invisibleCharactersInABrainsTextAreRefused() throws {
        let s = try setup()
        for bad in ["Pay \u{202E}gnirts", "Pay\u{200B}the bill", "Pay the bill\u{E0041}"] {
            #expect(try propose(s.server, ops: [addItem(1, title: bad)])["isError"] == .bool(true))
        }
        #expect(try propose(s.server, title: "Two\nlines", ops: [addItem(1)])["isError"] == .bool(true))
        #expect(ProposalStore.list(in: s.folder).isEmpty)
        #expect(try propose(s.server, title: "Réparer le toit", ops: [addItem(1, title: "Réparer le toit")])["isError"] == .bool(false))
    }

    // MARK: - qfZ3G: a read-only client cannot finish a reading

    @Test func aReadOnlyClientCannotFinishAReading() throws {
        let s = try setup(level: "read")
        let store = IntakeReadings(support: s.commands.support)
        var e = IntakeReadings.Entry(id: "reading-1", binder: s.folder.standardizedFileURL.path, name: "letter.pdf", sha256: String(repeating: "0", count: 64),
                                     card: "card-1", reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented letter.", channel: "other"), now: now)
        e.escalation = "waiting"
        try store.save(e)
        let r = try tool(s.server, "finish_reading", .obj([("binder", .str("estate-example")), ("reading_id", .str("reading-1"))]))
        #expect(r["isError"] == .bool(true))
        #expect(store.load("reading-1")?.escalation == "waiting")
    }

    // MARK: - qgAPD: the batch limit the schema advertises is enforced

    @Test func atMostFiftyOpsPerProposal() throws {
        let s = try setup()
        #expect(try propose(s.server, ops: (1...51).map { addItem($0) })["isError"] == .bool(true))
        #expect(ProposalStore.list(in: s.folder).isEmpty)
        #expect(try propose(s.server, ops: (1...50).map { addItem($0) })["isError"] == .bool(false))
    }

    // MARK: - an op with too many fields is refused before the applier scans them

    func updateItem(_ set: [(String, JSONValue)]) -> JSONValue {
        .obj([("op", .str("update_item")), ("args", .obj([("id", .str("estate-example-2026-007")), ("set", .obj(set))]))])
    }

    @Test func anOpWithTooManyFieldsIsRefusedPromptly() throws {
        let s = try setup()
        let wide = updateItem((0..<200_000).map { ("x_field_\($0)", .bool(true)) })
        let args = JSONObject([(key: "binder", value: .str("estate-example")), (key: "title", value: .str("Invented card")),
                               (key: "ops", value: .array([wide]))])
        // Timed past the transport's parse, which is linear: what the bound saves is the applier's work after it.
        let start = Date()
        let r = s.server.call("propose_ops", args)
        #expect(Date().timeIntervalSince(start) < 0.2)
        #expect(r["isError"] == .bool(true))
        #expect(r["structuredContent"]?["error"]?.stringValue?.contains("more than 64 entries") == true)
        let tags = updateItem([("tags", .array((0..<65).map { .string("tag-\($0)") }))])
        #expect(try propose(s.server, ops: [tags])["isError"] == .bool(true))
        #expect(ProposalStore.list(in: s.folder).isEmpty)
        #expect(try propose(s.server, ops: [updateItem([("title", .str("Call the notary again"))])])["isError"] == .bool(false))
        #expect(ProposalStore.list(in: s.folder).count == 1)
    }
}

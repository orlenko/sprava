import BinderFormat
import BinderStore
import Brains
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct MCPTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    let meta = #""_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}"#

    func setup(level: String = "propose") throws -> (MCPServer, URL, Commands) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-mcp-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "t")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        // The fixture's disclosure is "title"; MCP shows it.
        let client = MCPClientRecord(id: "claude-code-1", name: "Claude Code", tokenSHA256: "", binders: [folder.standardizedFileURL.path: level],
                                     createdAt: "", revoked: false)
        let server = MCPServer(client: client, commands: commands,
                               shelf: { Shelf.rows(registry: nil, picked: [folder]) }, now: { self.now })
        return (server, folder, commands)
    }

    func call(_ s: MCPServer, _ line: String) throws -> JSONValue { try JSONParser.parse(try #require(s.handle(line: line))).value }

    @Test func proposeThenApproveMintsTheID() throws {
        let (s, folder, commands) = try setup()
        let line = #"""
        {"jsonrpc":"2.0","id":5,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"Book the appraiser","request_id":"r1","ops":[{"op":"add_item","args":{"item":{"id":"$new:1","title":"Book the appraiser","status":"open","priority":"normal","due":"2026-10-20"}}},{"op":"set_status","args":{"id":"$new:1","status":"waiting","waiting_on":"the appraiser","follow_up_at":"2026-10-14"}}]}}}
        """#
        let r = try call(s, line)
        #expect(r["result"]?["isError"] == .bool(false), "\(r)")
        let pid = try #require(r["result"]?["structuredContent"]?["proposal_id"]?.stringValue)
        // Idempotent by request id.
        #expect(try call(s, line)["result"]?["structuredContent"]?["proposal_id"]?.stringValue == pid)
        // Nothing changed yet.
        #expect(!Teka.read(folder).items.contains { $0.title == "Book the appraiser" })
        // The person approves in the app.
        let listed = try JSONParser.parse(commands.handle(JSONWriter.compact(.obj([("command", .str("proposals")), ("binder", .string(folder.path))])))).value
        let card = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(pid) })
        #expect(card["verified"] == .bool(true))
        let approved = try JSONParser.parse(commands.handle(JSONWriter.compact(.obj([("command", .str("approve")), ("binder", .string(folder.path)),
                                                                                     ("proposal", .string(pid)), ("digest", card["digest"]!)])), now: now)).value
        #expect(approved["ok"] == .bool(true), "\(approved)")
        let item = Teka.read(folder).items.first { $0.title == "Book the appraiser" }
        #expect(item?.idText == "estate-example-2026-013")
        #expect(item?.status == .waiting)
        let ops = try TekaStore(folder: folder).readOpLog().ops
        #expect(ops.last?["actor"]?["kind"] == .str("brain") && ops.last?["approved_by"] == .str("user"))
        let state = try call(s, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{\#(meta),"name":"get_proposal","arguments":{"binder":"estate-example","proposal_id":"\#(pid)"}}}"#)
        #expect(state["result"]?["structuredContent"]?["state"] == .str("applied"))
    }
}

@Suite struct ClientRegistrationTests {
    @Test func registerListRevokeThroughCommands() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-reg-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "t")
        func call(_ f: [(String, JSONValue)]) throws -> JSONValue { try JSONParser.parse(c.handle(JSONWriter.compact(.obj(f)))).value }
        let r = try call([("command", .str("register_client")), ("client_id", .str("claude-code-1")),
                          ("binders", .obj([("/tmp/x/estate-example", .str("propose"))]))])
        let token = try #require(r["token"]?.stringValue)
        #expect(!(try String(contentsOf: MCPClients.url(support), encoding: .utf8)).contains(token))   // only the hash is kept
        #expect(try call([("command", .str("list_clients"))])["clients"]?.arrayValue?.count == 1)
        #expect(try call([("command", .str("register_client")), ("client_id", .str("claude-code-1")), ("binders", .obj([]))])["ok"] == .bool(false))
        #expect(try call([("command", .str("register_client")), ("client_id", .str("x")), ("binders", .obj([("relative", .str("propose"))]))])["ok"] == .bool(false))
        _ = try call([("command", .str("revoke_client")), ("client_id", .str("claude-code-1"))])
        #expect(try call([("command", .str("list_clients"))])["clients"]?.arrayValue?.isEmpty == true)
        #expect(try MCPClients.load(support).authenticate(clientID: "claude-code-1", token: token) == nil)
    }
}

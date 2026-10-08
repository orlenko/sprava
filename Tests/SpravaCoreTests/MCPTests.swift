import Foundation
import Testing
@testable import SpravaCore

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

    @Test func modernEraDiscoverAndList() throws {
        let (s, _, _) = try setup()
        let d = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"server/discover","params":{\#(meta)}}"#)
        #expect(d["result"]?["supportedVersions"]?.arrayValue?.first == .str("2026-07-28"))
        let tools = try call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{\#(meta)}}"#)
        #expect(tools["result"]?["tools"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["list_binders", "propose_ops", "get_proposal", "list_readings", "read_document", "finish_reading"])
        #expect(tools["result"]?["resultType"] == .str("complete"))
        let bare = try call(s, #"{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}"#)
        #expect(bare["error"]?["code"] == .int(-32602))
    }

    @Test func legacyEraInitialize() throws {
        let (s, _, _) = try setup()
        let i = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"x","version":"1"}}}"#)
        #expect(i["result"]?["protocolVersion"] == .str("2025-06-18"))
        #expect(s.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        let t = try call(s, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        #expect(t["result"]?["tools"]?.arrayValue?.count == 6)
        #expect(t["result"]?["resultType"] == nil)
    }

    @Test func descriptionsAreASCII() {
        for tool in MCPServer.tools {
            #expect(tool["description"]!.stringValue!.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 })
            #expect(tool["description"]!.stringValue!.count < 2048)
        }
    }

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

    @Test func refusesRealIDsBadBatchesAndOutOfScope() throws {
        let (s, _, _) = try setup()
        let realID = try call(s, #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"x","ops":[{"op":"add_item","args":{"item":{"id":"estate-example-2026-099","title":"x","status":"open","priority":"normal","no_deadline":true}}}]}}}"#)
        #expect(realID["result"]?["isError"] == .bool(true))
        let dateless = try call(s, #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"x","ops":[{"op":"add_item","args":{"item":{"id":"$new:1","title":"x","status":"open","priority":"normal"}}}]}}}"#)
        #expect(dateless["result"]?["isError"] == .bool(true))
        let approve = try call(s, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"x","ops":[{"op":"set_disclosure","args":{"disclosure":"full"}}]}}}"#)
        #expect(approve["result"]?["isError"] == .bool(true))
        let unknown = try call(s, #"{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{\#(meta),"name":"list_binders","arguments":{}}}"#)
        #expect(unknown["result"]?["structuredContent"]?["binders"]?.arrayValue?.count == 1)
        let other = try call(s, #"{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"secret-binder","title":"x","ops":[{"op":"drop","args":{"id":"a"}}]}}}"#)
        #expect(other["result"]?["structuredContent"]?["error"] == .str("not found"))
    }

    @Test func aReadOnlyClientCannotPropose() throws {
        let (s, _, _) = try setup(level: "read")
        let r = try call(s, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"x","ops":[{"op":"drop","args":{"id":"estate-example-2026-007"}}]}}}"#)
        #expect(r["result"]?["isError"] == .bool(true))
    }

    @Test func tokensAuthenticateAndRevoke() throws {
        var clients = MCPClients()
        let token = try clients.register(id: "claude-code-1", name: "Claude Code", binders: [:])
        #expect(token.hasPrefix("sprava_ct_") && token.count == 74)
        #expect(clients.authenticate(clientID: "claude-code-1", token: token) != nil)
        #expect(clients.authenticate(clientID: "claude-code-1", token: token + "x") == nil)
        #expect(clients.authenticate(clientID: "other", token: token) == nil)
        clients.revoke(id: "claude-code-1")
        #expect(clients.authenticate(clientID: "claude-code-1", token: token) == nil)
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
        #expect(MCPClients.load(support).authenticate(clientID: "claude-code-1", token: token) == nil)
    }
}

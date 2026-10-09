import BinderStore
@testable import Brains
import Foundation
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

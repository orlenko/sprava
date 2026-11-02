import Foundation
import SpravaKit

/// Tools Sprava itself answers, over the pipe it already holds to the agent (the CLI's in-process MCP server, type `sdk`,
/// checked on Claude 2.1.316 with `--safe-mode --restricted`). Nothing new runs inside the sandbox: no program, socket or
/// token, and a command the agent runs cannot reach them, because only the agent process holds that pipe.
package struct ClaudeAppTools: Sendable {
    package struct Tool: Sendable {
        package let name: String
        package let description: String
        package let schema: JSONValue
        package init(name: String, description: String, schema: JSONValue) { self.name = name; self.description = description; self.schema = schema }
    }
    package struct Answer: Sendable {
        package let content: JSONValue
        package let refused: Bool
        package init(content: JSONValue, refused: Bool = false) { self.content = content; self.refused = refused }
    }
    static let server = "sprava"
    package let tools: [Tool]
    package let call: @Sendable (String, JSONObject) -> Answer
    package init(tools: [Tool], call: @escaping @Sendable (String, JSONObject) -> Answer) { self.tools = tools; self.call = call }

    /// The names the agent sees these tools by.
    var names: [String] { tools.map { "mcp__\(Self.server)__\($0.name)" } }

    /// One JSON-RPC message from the agent. `open` is whether a person's turn is under way and not stopped: a tool runs only then.
    func answer(_ message: JSONObject, open: Bool) -> JSONValue {
        let id = message["id"]
        func reply(_ result: JSONValue) -> JSONValue { .obj([("jsonrpc", .str("2.0")), ("id", id ?? .null), ("result", result)]) }
        switch message["method"]?.stringValue {
        case "initialize":
            return reply(.obj([("protocolVersion", message["params"]?["protocolVersion"] ?? .str(MCPServer.legacy[0])),
                               ("capabilities", .obj([("tools", .obj([]))])), ("serverInfo", MCPServer.serverInfo)]))
        case "tools/list":
            return reply(.obj([("tools", .array(tools.map {
                .obj([("name", .str($0.name)), ("description", .str($0.description)), ("inputSchema", $0.schema)])
            }))]))
        case "tools/call":
            guard open else { return reply(MCPServer.toolError("this turn has stopped")) }
            guard let name = message["params"]?["name"]?.stringValue, tools.contains(where: { $0.name == name }) else {
                return reply(MCPServer.toolError("no such tool"))
            }
            let outcome = call(name, message["params"]?["arguments"]?.objectValue ?? JSONObject())
            return reply(MCPServer.toolResult(outcome.content, isError: outcome.refused))
        default:
            // A notification wants no reply, but the pipe's request still needs its response.
            guard id != nil else { return .obj([("jsonrpc", .str("2.0")), ("result", .obj([]))]) }
            return .obj([("jsonrpc", .str("2.0")), ("id", id ?? .null), ("error", .obj([("code", .int(-32601)), ("message", .str("method not found"))]))])
        }
    }
}

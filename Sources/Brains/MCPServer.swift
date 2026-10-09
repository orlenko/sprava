import BinderFormat
import BinderStore
import Capture
import CryptoKit
import Darwin
import Foundation
import Shelf
import SpravaKit

/// The MCP server (architecture 7; mvp.md feature 10): JSON-RPC 2.0 over newline-delimited lines, six tools,
/// both protocol eras. The modern revision (2026-07-28) is stateless: every request carries `_meta` with the
/// protocol version and the client's capabilities, and `server/discover` replaces `initialize`. The legacy era
/// (2025-11-25 and earlier) starts with `initialize`. A brain can only read its scope and propose; approval
/// happens only in the app.
public final class MCPServer: @unchecked Sendable {
    public static let modern = "2026-07-28"
    public static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26"]
    public static let serverInfo = JSONValue.obj([("name", .str("sprava")), ("version", .str("0.1.0"))])

    let client: MCPClientRecord
    let commands: Commands
    let shelf: () -> [ShelfRow]
    let now: () -> Date
    private var era: String?
    /// The intake digests `prepare(line:)` took for the line about to be handled, by binder and path.
    var prehashed: [String: (stamp: IntakeStamp, digest: String)] = [:]

    public init(client: MCPClientRecord, commands: Commands, shelf: @escaping () -> [ShelfRow], now: @escaping () -> Date = Date.init) {
        self.client = client
        self.commands = commands
        self.shelf = shelf
        self.now = now
    }

    // MARK: - JSON-RPC

    /// Handles one line; returns the reply line, or nil for a notification.
    public func handle(line: String) -> String? {
        guard let parsed = try? JSONParser.parse(line).value, case .object(let msg) = parsed else {
            return Self.error(id: .null, code: -32700, message: "parse error")
        }
        let id = msg["id"]
        guard case .string(let method)? = msg["method"] else {
            return id == nil ? nil : Self.error(id: id!, code: -32600, message: "invalid request")
        }
        let params = msg["params"]?.objectValue ?? JSONObject()
        guard let id else { return nil }   // notifications (notifications/initialized, cancelled) need no reply

        // Era: a request with _meta protocolVersion is modern; initialize is legacy.
        let metaVersion = params["_meta"]?["io.modelcontextprotocol/protocolVersion"]?.stringValue
        switch method {
        case "initialize":
            era = "legacy"
            let asked = params["protocolVersion"]?.stringValue ?? Self.legacy[0]
            let version = Self.legacy.contains(asked) ? asked : Self.legacy[0]
            return Self.result(id: id, .obj([("protocolVersion", .string(version)),
                                             ("capabilities", .obj([("tools", .obj([("listChanged", .bool(false))]))])),
                                             ("serverInfo", Self.serverInfo),
                                             ("instructions", .str(Self.instructions))]), modern: false)
        case "server/discover":
            return Self.result(id: id, .obj([("supportedVersions", .array([.str(Self.modern)] + Self.legacy.map(JSONValue.string))),
                                             ("capabilities", .obj([("tools", .obj([("listChanged", .bool(false))]))])),
                                             ("instructions", .str(Self.instructions)),
                                             ("ttlMs", .int(3_600_000)), ("cacheScope", .str("server")),
                                             ("_meta", .obj([("io.modelcontextprotocol/serverInfo", Self.serverInfo)]))]), modern: true)
        case "ping":
            return Self.result(id: id, .obj([]), modern: metaVersion != nil)
        default:
            break
        }
        // The modern era is stateless: every request carries _meta, and nothing relies on an earlier request.
        // Only the legacy `initialize` handshake gives a connection state.
        let modern = metaVersion != nil
        if era != "legacy", metaVersion == nil {
            return Self.error(id: id, code: -32602, message: "missing _meta io.modelcontextprotocol/protocolVersion (or send initialize)")
        }
        if let v = metaVersion, v != Self.modern, !Self.legacy.contains(v) {
            return Self.error(id: id, code: -32022, message: "unsupported protocol version \(v)")
        }
        switch method {
        case "tools/list":
            var r: [(String, JSONValue)] = [("tools", .array(Self.tools))]
            if modern { r += [("ttlMs", .int(3_600_000)), ("cacheScope", .str("server"))] }
            return Self.result(id: id, .obj(r), modern: modern)
        case "tools/call":
            guard case .string(let name)? = params["name"] else { return Self.error(id: id, code: -32602, message: "tool name") }
            let args = params["arguments"]?.objectValue ?? JSONObject()
            let outcome = call(name, args)
            return Self.result(id: id, outcome, modern: modern)
        default:
            return Self.error(id: id, code: -32601, message: "method not found: \(method)")
        }
    }

    /// The methods this server answers or accepts; a log line names only these (architecture 3.7, 7.5).
    static let knownMethods: Set<String> = ["initialize", "server/discover", "ping", "tools/list", "tools/call",
                                            "notifications/initialized", "notifications/cancelled"]

    /// The method of a request line as a log may show it: a known name, else `unknown_method`, never the client's text.
    public static func loggedMethod(_ line: String) -> String {
        guard let method = (try? JSONParser.parse(line).value)?["method"]?.stringValue, knownMethods.contains(method) else {
            return "unknown_method"
        }
        return method
    }

    static let instructions = "Sprava keeps one binder per life episode. Read with list_binders; change things only with propose_ops, which puts a card in the person's review queue. Never say a change was made until get_proposal reports it applied. list_readings shows documents that arrived and deserve a careful reading."

    static func result(id: JSONValue, _ value: JSONValue, modern: Bool) -> String {
        var v = value
        if modern, case .object(var o) = v {
            o.set("resultType", .str("complete"))
            o.set("_meta", .obj([("io.modelcontextprotocol/serverInfo", serverInfo)]))
            v = .object(o)
        }
        return JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", id), ("result", v)]))
    }

    static func error(id: JSONValue, code: Int, message: String) -> String {
        JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", id),
                                 ("error", .obj([("code", .int(code)), ("message", .string(message))]))]))
    }

    /// A tool result: structured content plus the same JSON as text; errors as `isError` so the model can fix them.
    static func toolResult(_ content: JSONValue, isError: Bool = false) -> JSONValue {
        .obj([("content", .array([.obj([("type", .str("text")), ("text", .string(JSONWriter.compact(content)))])])),
              ("structuredContent", content), ("isError", .bool(isError))])
    }

    static func toolError(_ message: String) -> JSONValue { toolResult(.obj([("error", .string(message))]), isError: true) }

    // MARK: - Calls

    func call(_ name: String, _ args: JSONObject) -> JSONValue {
        switch name {
        case "list_readings": return listReadings(args)
        case "read_document": return readDocument(args)
        case "finish_reading": return finishReading(args)
        case "list_binders": return listBinders()
        case "get_proposal": return getProposal(args)
        case "propose_ops": return proposeOps(args)
        default: return Self.toolError("unknown tool \(name)")
        }
    }
}

import Foundation

/// The MCP server (architecture 7; mvp.md feature 10): JSON-RPC 2.0 over newline-delimited lines, three tools,
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

    public init(client: MCPClientRecord, commands: Commands, shelf: @escaping () -> [ShelfRow], now: @escaping () -> Date = Date.init) {
        self.client = client
        self.commands = commands
        self.shelf = shelf
        self.now = now
    }

    // MARK: - Tools

    static func schema(_ properties: [(String, JSONValue)], required: [String]) -> JSONValue {
        .obj([("type", .str("object")), ("properties", .obj(properties)),
              ("required", .array(required.map(JSONValue.string))), ("additionalProperties", .bool(false))])
    }

    static let opSchema = JSONValue.obj([
        ("type", .str("object")),
        ("properties", .obj([
            ("op", .obj([("type", .str("string")), ("enum", .array(proposable.sorted().map(JSONValue.string)))])),
            ("args", .obj([("type", .str("object"))])),
            ("note", .obj([("type", .str("string"))])),
        ])),
        ("required", .array([.str("op"), .str("args")])),
    ])

    /// Ops a brain may propose (mvp.md feature 10): item ops, document filing and free log entries.
    static let proposable: Set<String> = ["add_item", "update_item", "set_status", "complete", "drop", "add_log_entry"]

    static func annotations(readOnly: Bool, idempotent: Bool) -> JSONValue {
        .obj([("readOnlyHint", .bool(readOnly)), ("destructiveHint", .bool(false)),
              ("idempotentHint", .bool(idempotent)), ("openWorldHint", .bool(false))])
    }

    /// The tool list: static, ASCII descriptions, the same for every connection (architecture 7.3, 7.7).
    public static let tools: [JSONValue] = [
        .obj([("name", .str("list_binders")), ("title", .str("List binders")),
              ("description", .str("Lists the Sprava binders this client may see, with each binder's level (read or propose) and counts of open, overdue and waiting items. Use the binder name with the other tools.")),
              ("inputSchema", schema([], required: [])),
              ("annotations", annotations(readOnly: true, idempotent: true))]),
        .obj([("name", .str("propose_ops")), ("title", .str("Propose changes")),
              ("description", .str("Submits a batch of changes to one binder for the person to review in the Sprava app. Nothing changes until the person approves it there; this tool returns at once with a proposal id. New items use placeholder ids \"$new:1\", \"$new:2\" (real ids are minted on approval) and need title, status, priority, and due (YYYY-MM-DD) or no_deadline: true; waiting or blocked items also need waiting_on and follow_up_at. Allowed ops: add_item {item}, update_item {id, set, unset}, set_status {id, status, waiting_on, follow_up_at}, complete {id}, drop {id, reason}, add_log_entry {entry}. Use request_id to make a retry safe.")),
              ("inputSchema", schema([
                ("binder", .obj([("type", .str("string"))])),
                ("title", .obj([("type", .str("string")), ("description", .str("One line the person sees on the card."))])),
                ("rationale", .obj([("type", .str("string"))])),
                ("request_id", .obj([("type", .str("string"))])),
                ("ops", .obj([("type", .str("array")), ("items", opSchema), ("minItems", .int(1)), ("maxItems", .int(50))])),
              ], required: ["binder", "title", "ops"])),
              ("annotations", annotations(readOnly: false, idempotent: true))]),
        .obj([("name", .str("get_proposal")), ("title", .str("Get a proposal")),
              ("description", .str("Returns the state of one of this client's proposals: proposed, applied or rejected.")),
              ("inputSchema", schema([("binder", .obj([("type", .str("string"))])),
                                      ("proposal_id", .obj([("type", .str("string"))]))], required: ["binder", "proposal_id"])),
              ("annotations", annotations(readOnly: true, idempotent: true))]),
    ]

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

    static let instructions = "Sprava keeps one binder per life episode. Read with list_binders; change things only with propose_ops, which puts a card in the person's review queue. Never say a change was made until get_proposal reports it applied."

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

    /// The binders this client may see: in its scope, and not at disclosure `none` (architecture 7.6).
    func visible() -> [(ShelfRow, String)] {
        shelf().compactMap { row in
            guard row.teka.isAdopted, let level = client.level(for: row.folder),
                  row.teka.catalog?["meta"]?["disclosure"]?.stringValue != "none" else { return nil }
            return (row, level)
        }
    }

    func binder(_ args: JSONObject) -> (ShelfRow, String)? {
        guard case .string(let name)? = args["binder"] else { return nil }
        return visible().first { $0.0.teka.name == name }
    }

    func call(_ name: String, _ args: JSONObject) -> JSONValue {
        switch name {
        case "list_binders":
            let today = CalendarDate.today(now: now())
            return Self.toolResult(.obj([("binders", .array(visible().map { row, level in
                let page = row.teka.nowPage(today: today)
                return .obj([("binder", .string(row.teka.name)), ("level", .string(level)),
                             ("open", .int(row.teka.items.count)), ("overdue", .int(page.count(.overdue))),
                             ("waiting", .int(page.count(.waiting) + page.count(.nudge)))])
            }))]))

        case "get_proposal":
            // A handle is a name, never a capability: it must belong to this client (architecture 7.3).
            guard let (row, _) = binder(args), case .string(let pid)? = args["proposal_id"],
                  let (p, _) = ProposalStore.list(in: row.folder).first(where: { $0.0.id == pid }),
                  p.actor["kind"] == .str("brain"), p.actor["model"]?.stringValue == client.id else { return Self.toolError("not found") }
            return Self.toolResult(.obj([("proposal_id", .string(p.id)), ("state", .string(p.state)),
                                         ("applied_ops", p.raw["applied_ops"] ?? .array([]))]))

        case "propose_ops":
            guard let (row, level) = binder(args) else { return Self.toolError("not found") }
            guard level == "propose" else { return Self.toolError("this client may only read this binder") }
            guard case .string(let title)? = args["title"], !title.isEmpty, case .array(let ops)? = args["ops"], !ops.isEmpty else {
                return Self.toolError("title and ops are required")
            }
            let requestID = args["request_id"]?.stringValue
            if let requestID, let (p, _) = ProposalStore.list(in: row.folder).first(where: {
                $0.0.actor["kind"] == .str("brain") && $0.0.actor["model"]?.stringValue == client.id && $0.0.raw["request_id"]?.stringValue == requestID }) {
                return Self.toolResult(.obj([("proposal_id", .string(p.id)), ("state", .string(p.state))]))
            }
            var bodies: [JSONObject] = []
            guard ops.allSatisfy({ $0.objectValue != nil }) else { return Self.toolError("each op is an object with op and args") }
            for case .object(let op) in ops {
                guard case .string(let type)? = op["op"], Self.proposable.contains(type) else {
                    return Self.toolError("op must be one of \(Self.proposable.sorted().joined(separator: ", "))")
                }
                if type == "add_item", op["args"]?["item"]?["id"]?.stringValue?.hasPrefix("$new:") != true {
                    return Self.toolError("new items use placeholder ids such as $new:1; ids are minted on approval")
                }
                var body = JSONObject([(key: "op", value: .string(type)), (key: "args", value: op["args"] ?? .obj([]))])
                if let note = op["note"] { body.set("note", note) }
                bodies.append(body)
            }
            let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .string(commands.client)),
                                    (key: "model", value: .string(client.id))])
            // Validated at once against the catalog, so the model can correct itself.
            do {
                try TekaStore.dryRun(bodies, actor: actor, folder: row.folder, now: now())
            } catch {
                return Self.toolError("the batch would not be accepted: \(error)")
            }
            var provenance = JSONObject([(key: "client", value: .string(client.id))])
            if let r = args["rationale"] { provenance.set("rationale", r) }
            var proposal = Proposal.make(title: title, actor: actor, ops: bodies, provenance: provenance, now: now())
            if let requestID { proposal.raw.set("request_id", .string(requestID)) }
            do {
                try ProposalStore.save(proposal, in: row.folder)
                commands.trustProposals([proposal.id], in: row.folder)
            } catch {
                return Self.toolError("could not store the proposal")
            }
            return Self.toolResult(.obj([("proposal_id", .string(proposal.id)), ("state", .str("proposed")),
                                         ("note", .str("Waiting for the person in the Sprava app. Nothing has changed yet."))]))

        default:
            return Self.toolError("unknown tool \(name)")
        }
    }
}

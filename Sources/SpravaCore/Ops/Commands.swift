import Foundation

/// The commands that change binders. The runtime runs them for the app over XPC; a development CLI can run them
/// too, refusing any folder lifeproj's registry lists. Requests and replies are JSON text, so the XPC interface
/// stays a few strings and the same code is tested in-process.
public struct Commands: Sendable {
    public let support: URL
    public let deviceID: String
    public let client: String

    public init(support: URL, deviceID: String, client: String = "sprava/0.1") {
        self.support = support
        self.deviceID = deviceID
        self.client = client
    }

    public var inbox: CaptureInbox { CaptureInbox(root: CaptureInbox.defaultRoot(support: support), support: support) }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Proposal digests recorded when the runtime wrote or listed them, so an approval applies exactly what the
    /// person saw (architecture 4.6). Kept in Sprava's own state.
    var digestsURL: URL { support.appendingPathComponent("runtime/proposal-digests.json") }

    func loadDigests() -> [String: String] {
        (try? Data(contentsOf: digestsURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    func saveDigests(_ d: [String: String]) {
        try? AtomicFile.makePrivateFolder(digestsURL.deletingLastPathComponent())
        if let data = try? JSONEncoder().encode(d) { try? AtomicFile.write(data, to: digestsURL) }
    }

    /// Handles one request: `{"command": ..., ...}`. Returns `{"ok": true, ...}` or `{"ok": false, "error": ...}`.
    /// Records the digests of proposals Sprava itself just wrote (the clerk, the MCP listener, adoption).
    public func trustProposals(in folder: URL) { recordDigests(in: folder) }

    public func handle(_ request: String, now: Date = Date(), today: CalendarDate? = nil) -> String {
        do {
            guard case .object(let r) = try JSONParser.parse(request).value, case .string(let command)? = r["command"] else {
                throw Failure(message: "malformed request")
            }
            let result = try run(command, r, now: now, today: today ?? CalendarDate.today(now: now))
            var reply = JSONObject([(key: "ok", value: .bool(true))])
            for e in result.entries { reply.set(e.key, e.value) }
            return JSONWriter.compact(.object(reply))
        } catch {
            return JSONWriter.compact(.obj([("ok", .bool(false)), ("error", .string("\(error)"))]))
        }
    }

    func folder(_ r: JSONObject) throws -> URL {
        guard case .string(let path)? = r["binder"], path.hasPrefix("/") else { throw Failure(message: "binder must be an absolute path") }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    func run(_ command: String, _ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        if ["approve", "reject", "apply", "undo"].contains(command) {
            let f = try folder(r)
            if let owner = Owner.device(of: f), owner != deviceID {
                throw Failure(message: "this binder is managed by another Sprava (another Mac or a development build); it is read-only here")
            }
        }
        switch command {
        case "ping":
            return JSONObject([(key: "protocol", value: .int(1))])

        case "adopt":
            let f = try folder(r)
            let inRegistry = r["in_registry"] == .bool(true)
            let result = try Adoption.adopt(f, inRegistry: inRegistry, deviceID: deviceID, today: today, now: now, client: client)
            recordDigests(in: f)
            return JSONObject([(key: "mechanical", value: .int(result.mechanical.count)),
                               (key: "proposals", value: .array(result.proposals.map { .string($0.id) }))])

        case "proposals":
            let f = try folder(r)
            // A proposal file the runtime did not write has no recorded digest: it is shown as "not verified" and
            // cannot be approved (teka-v0 §6.5; architecture 4.6).
            let listed = ProposalStore.list(in: f)
            let digests = loadDigests()
            let catalog = Teka.read(f).catalog
            return JSONObject([(key: "proposals", value: .array(listed.map { p, digest in
                var o = JSONObject()
                o.set("id", .string(p.id))
                o.set("state", .string(p.state))
                o.set("title", .string(p.title))
                o.set("actor", .object(p.actor))
                o.set("digest", .string(digest))
                o.set("verified", .bool(digests[key(f, p.id)] == digest))
                o.set("lines", .array(p.ops.map { .string(Proposal.describe($0, catalog: catalog)) }))
                return .object(o)
            }))])

        case "approve", "reject":
            let f = try folder(r)
            guard case .string(let id)? = r["proposal"], case .string(let seen)? = r["digest"] else {
                throw Failure(message: "\(command) needs proposal and digest")
            }
            guard let recorded = loadDigests()[key(f, id)] else {
                throw Failure(message: "this proposal was not written by Sprava, so it cannot be approved")
            }
            guard recorded == seen else { throw Failure(message: "this card changed since it was shown; reload it") }
            let proposal = try ProposalStore.load(id, in: f, expectedDigest: recorded)
            let store = TekaStore(folder: f, client: client)
            if command == "approve" {
                let applied = try store.approve(proposal, now: now)
                recordDigests(in: f)
                return JSONObject([(key: "applied", value: .int(applied.count))])
            }
            try store.reject(proposal, reason: r["reason"]?.stringValue, now: now)
            recordDigests(in: f)
            return JSONObject()

        case "apply":
            // A direct action by the person in the app (actor user): complete, drop, set status, edit, add.
            let f = try folder(r)
            guard case .string(let op)? = r["op"], case .object(let args)? = r["args"] else {
                throw Failure(message: "apply needs op and args")
            }
            let allowed: Set<String> = ["add_item", "update_item", "set_status", "complete", "drop", "reopen", "set_meta", "set_disclosure"]
            guard allowed.contains(op) else { throw Failure(message: "\(op) is not a direct action") }
            let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
            var extra: [(String, JSONValue)] = []
            if let c = r["compensates"] { extra.append(("compensates", c)) }
            let applied = try TekaStore(folder: f, client: client).apply([.init(op: op, args: args, actor: actor, extra: extra)], now: now)
            return JSONObject([(key: "op", value: applied.first?["id"] ?? .null)])

        case "undo":
            let f = try folder(r)
            guard case .string(let opID)? = r["op_id"] else { throw Failure(message: "undo needs op_id") }
            let applied = try TekaStore(folder: f, client: client).undo(opID: opID, now: now)
            return JSONObject([(key: "op", value: applied.first?["id"] ?? .null)])

        case "capture_notice":
            // The app tells the runtime it wrote this event (architecture 8).
            guard case .string(let event)? = r["event"], case .string(let digest)? = r["sha256"] else {
                throw Failure(message: "capture_notice needs event and sha256")
            }
            try inbox.recordNotice(event: event, digest: digest, now: now)
            return JSONObject()

        case "unfiled":
            return JSONObject([(key: "cards", value: .array(inbox.unfiled().map { p in
                var o = JSONObject()
                o.set("id", .string(p.id))
                o.set("title", .string(p.title))
                o.set("created_at", p.raw["created_at"] ?? .null)
                o.set("lines", .array(p.ops.map { .string(Proposal.describe($0, catalog: nil)) }))
                for flag in ["source_retracted", "source_corrected"] where p.raw[flag] == .bool(true) { o.set(flag, .bool(true)) }
                if let prov = p.raw["provenance"]?.objectValue {
                    o.set("unverified_source", .bool(prov["unverified_source"] == .bool(true)))
                    o.set("private", .bool(prov["private"] == .bool(true)))
                    o.set("producer", prov["producer"] ?? .null)
                }
                return .object(o)
            }))])

        case "file_card":
            guard case .string(let id)? = r["card"] else { throw Failure(message: "file_card needs card") }
            try inbox.file(id, into: try folder(r), commands: self)
            return JSONObject()

        case "discard_card":
            guard case .string(let id)? = r["card"] else { throw Failure(message: "discard_card needs card") }
            try inbox.discard(id)
            return JSONObject()

        case "register_client":
            // A brain client (architecture 7.5). The token is returned once and never stored, only its hash.
            guard case .string(let id)? = r["client_id"], case .object(let scope)? = r["binders"] else {
                throw Failure(message: "register_client needs client_id and binders")
            }
            var binders: [String: String] = [:]
            for e in scope.entries {
                guard e.key.hasPrefix("/"), ["read", "propose"].contains(e.value.stringValue ?? "") else {
                    throw Failure(message: "binders map absolute paths to read or propose")
                }
                binders[URL(fileURLWithPath: e.key).standardizedFileURL.path] = e.value.stringValue!
            }
            var clients = MCPClients.load(support)
            let token = try clients.register(id: id, name: r["name"]?.stringValue ?? id, binders: binders, now: now)
            try clients.save(support)
            return JSONObject([(key: "token", value: .string(token))])

        case "list_clients":
            let clients = MCPClients.load(support).clients.filter { !$0.revoked }
            return JSONObject([(key: "clients", value: .array(clients.map { c in
                .obj([("id", .string(c.id)), ("name", .string(c.name)), ("created_at", .string(c.createdAt)),
                      ("binders", .obj(c.binders.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) }))])
            }))])

        case "revoke_client":
            guard case .string(let id)? = r["client_id"] else { throw Failure(message: "revoke_client needs client_id") }
            var clients = MCPClients.load(support)
            clients.revoke(id: id)
            try clients.save(support)
            return JSONObject()

        case "history":
            // Recent changes a person might undo: the last 20 ops that changed something, newest first.
            let f = try folder(r)
            let log = try TekaStore(folder: f, client: client).readOpLog().ops
            let undone = Set(log.compactMap { $0["compensates"]?.stringValue })
            let catalog = Teka.read(f).catalog
            let recent = log.filter { !["import_snapshot", "abort", "expunge", "migrate"].contains($0["op"]?.stringValue ?? "") }
                .suffix(20).reversed()
            return JSONObject([(key: "ops", value: .array(recent.map { op in
                var o = JSONObject()
                o.set("id", op["id"] ?? .null)
                o.set("at", op["at"] ?? .null)
                o.set("actor", op["actor"]?["kind"] ?? .null)
                o.set("origin", op["actor"]?["origin"] ?? .null)
                o.set("line", .string(Proposal.describe(op, catalog: catalog)))
                o.set("undone", .bool(undone.contains(op["id"]?.stringValue ?? "")))
                o.set("undoable", .bool(!["external_edit", "add_log_entry", "reopen", "rename_teka"].contains(op["op"]?.stringValue ?? "")
                                        && op["compensates"] == nil))
                return .object(o)
            }))])

        default:
            throw Failure(message: "unknown command \(command)")
        }
    }

    func key(_ folder: URL, _ id: String) -> String { folder.path + "#" + id }

    func recordDigests(in folder: URL) {
        var digests = loadDigests()
        for (p, d) in ProposalStore.list(in: folder) { digests[key(folder, p.id)] = d }
        saveDigests(digests)
    }
}

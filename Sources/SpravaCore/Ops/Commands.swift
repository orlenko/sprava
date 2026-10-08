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
    /// Only the ids Sprava just saved are trusted; a file another program dropped into the folder never is.
    public func trustProposals(_ ids: [String], in folder: URL) { recordDigests(ids, in: folder) }

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
        if ["approve", "reject", "apply", "undo", "switch_dashboard", "file_card", "binder_settings"].contains(command) {
            let f = try folder(r)
            // Fail closed: an adopted binder accepts writes only when its owner record names this Mac.
            let adopted = FileManager.default.fileExists(atPath: f.appendingPathComponent(".sprava/ops.ndjson").path)
            if adopted, Owner.device(of: f) != deviceID {
                throw Failure(message: Owner.device(of: f) == nil
                    ? "this binder's owner record is missing or damaged; it is read-only until it is repaired"
                    : "this binder is managed by another Sprava (another Mac or a development build); it is read-only here")
            }
        }
        switch command {
        case "ping":
            return JSONObject([(key: "protocol", value: .int(1))])

        case "adopt":
            let f = try folder(r)
            let inRegistry = r["in_registry"] == .bool(true)
            let result = try Adoption.adopt(f, inRegistry: inRegistry, deviceID: deviceID, today: today, now: now, client: client)
            recordDigests(result.proposals.map(\.id), in: f)
            return JSONObject([(key: "mechanical", value: .int(result.mechanical.count)),
                               (key: "proposals", value: .array(result.proposals.map { .string($0.id) }))])

        case "proposals":
            let f = try folder(r)
            // A proposal file the runtime did not write has no recorded digest: it is shown as "not verified" and
            // cannot be approved (binder-v0 §6.5; architecture 4.6).
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
                var notes = p.cardNotes
                if p.state == "proposed", case let changed = p.changedSince(catalog: catalog), !changed.isEmpty {
                    notes.insert("needs a look: changed since this card was made: " + changed.joined(separator: ", "), at: 0)
                }
                o.set("notes", .array(notes.map(JSONValue.string)))
                // What the person may edit on the card (CardEdits).
                o.set("editable", .array(p.ops.enumerated().compactMap { i, op -> JSONValue? in
                    guard op["op"] == .str("add_item"), let item = op["args"]?["item"] else { return nil }
                    return .obj([("index", .int(i)), ("title", item["title"] ?? .str("")), ("due", item["due"] ?? .str("")),
                                 ("priority", item["priority"] ?? .str("normal"))])
                }))
                if let c = p.raw["confidence"] { o.set("confidence", c) }
                if let intake = p.raw["provenance"]?["intake"] { o.set("intake", intake) }
                if let folder = p.ops.first(where: { $0["op"] == .str("file_document") })?["args"]?["document"]?["path"]?.stringValue {
                    o.set("document_folder", .string((folder as NSString).deletingLastPathComponent))
                }
                return .object(o)
            }))])

        case "approve", "reject":
            let f = try folder(r)
            guard case .string(let id)? = r["proposal"], case .string(let seen)? = r["digest"] else {
                throw Failure(message: "\(command) needs proposal and digest")
            }
            // A card Sprava did not write is never approved, but the person may reject it, as shown.
            let current = ProposalStore.list(in: f).first { $0.0.id == id }?.1
            guard let recorded = loadDigests()[key(f, id)] ?? (command == "reject" ? current : nil) else {
                throw Failure(message: "this proposal was not written by Sprava, so it cannot be approved")
            }
            guard recorded == seen else { throw Failure(message: "this card changed since it was shown; reload it") }
            let proposal = try ProposalStore.load(id, in: f, expectedDigest: recorded)
            let store = TekaStore(folder: f, client: client)
            if command == "approve" {
                // The person may pick another folder for a filing card; only the folder changes, never the file.
                var edited: [JSONObject]?
                if case .array(let edits)? = r["edits"], !edits.isEmpty {
                    edited = try CardEdits.apply(edits, to: proposal.ops)
                }
                if case .string(let target)? = r["document_folder"] {
                    let folderPath = target.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                    edited = try (edited ?? proposal.ops).map { op in
                        guard op["op"] == .str("file_document"), var args = op["args"]?.objectValue,
                              var doc = args["document"]?.objectValue, let path = doc["path"]?.stringValue else { return op }
                        let newPath = folderPath + "/" + (path as NSString).lastPathComponent
                        guard DocumentPaths.isSafe(newPath) else { throw Failure(message: "that folder cannot hold documents") }
                        doc.set("path", .string(newPath))
                        args.set("document", .object(doc))
                        var changed = op
                        changed.set("args", .object(args))
                        return changed
                    }
                }
                let applied = try store.approve(proposal, edited: edited, now: now)
                recordDigests([id] + store.createdProposals, in: f)
                return JSONObject([(key: "applied", value: .int(applied.count))])
            }
            try store.reject(proposal, reason: r["reason"]?.stringValue, now: now)
            recordDigests([id], in: f)
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
            let store = TekaStore(folder: f, client: client)
            let applied = try store.apply([.init(op: op, args: args, actor: actor, extra: extra)], now: now)
            recordDigests(store.createdProposals, in: f)
            return JSONObject([(key: "op", value: applied.first?["id"] ?? .null)])

        case "undo":
            let f = try folder(r)
            guard case .string(let opID)? = r["op_id"] else { throw Failure(message: "undo needs op_id") }
            let store = TekaStore(folder: f, client: client)
            let applied = try store.undo(opID: opID, now: now)
            recordDigests(store.createdProposals, in: f)
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
                o.set("notes", .array(p.cardNotes.map(JSONValue.string)))
                o.set("not_filed", .array(inbox.notFiled(p).map(JSONValue.string)))
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

        case "binder_settings":
            // The clerk's filing list: read, or set when description or filing is given (mvp.md feature 1).
            let f = try folder(r)
            let list = FilingList(support: support)
            var entry = list.load()[f.path] ?? FilingList.Entry(description: FilingList.readmeLine(f) ?? "", filing: false)
            if r["description"] != nil || r["filing"] != nil {
                if case .string(let d)? = r["description"] { entry.description = d }
                if case .bool(let on)? = r["filing"] { entry.filing = on }
                if entry.filing, entry.description.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw Failure(message: "a binder on the filing list needs a one-line description")
                }
                try list.set(f, entry)
            }
            return JSONObject([(key: "description", value: .string(entry.description)), (key: "filing", value: .bool(entry.filing))])

        case "create_binder":
            // A new binder from a template (mvp.md feature 6): ready, stamped v0, at disclosure none, on the shelf.
            guard case .string(let parentPath)? = r["parent"], parentPath.hasPrefix("/"), case .string(let name)? = r["name"] else {
                throw Failure(message: "create_binder needs parent and name")
            }
            let template = BinderTemplate.all.first { $0.key == (r["template"]?.stringValue ?? "tax-year") } ?? .taxYear
            let url = LifeprojRegistry.defaultPath()
            let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
            let store = ShelfStore(supportDirectory: support)
            let names = Shelf.rows(registry: registry, picked: store.pickedFolders(), includeArchived: true).map(\.name)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let year = r["year"]?.numberValue?.safeInteger.map(Int.init) ?? calendar.component(.year, from: now)
            let created = try BinderCreator.create(parent: URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL, name: name,
                                                   template: template, deviceID: deviceID, knownNames: names, year: year, today: today,
                                                   client: client, now: now)
            if let card = created.checklistCard { recordDigests([card], in: created.folder) }
            try store.add(created.folder)
            try FilingList(support: support).set(created.folder, .init(description: template.description(year), filing: false))
            return JSONObject([(key: "binder", value: .string(created.folder.path)),
                               (key: "proposal", value: created.checklistCard.map(JSONValue.string) ?? .null)])

        case "backup_status":
            let backup = Backup(support: support)
            let st = backup.status()
            let url = LifeprojRegistry.defaultPath()
            let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
            let rows = Shelf.rows(registry: registry, picked: ShelfStore(supportDirectory: support).pickedFolders())
            let names = Dictionary(rows.compactMap { row -> (String, String)? in
                guard let id = try? String(contentsOf: row.folder.appendingPathComponent(".sprava/backup-id"), encoding: .utf8) else { return nil }
                return (id.trimmingCharacters(in: .whitespacesAndNewlines), row.name)
            }, uniquingKeysWith: { a, _ in a })
            var upload: JSONValue = .null
            switch st.upload {
            case .uploaded?: upload = .str("uploaded")
            case .waiting(let n)?: upload = .string("waiting for iCloud: \(n) file(s)")
            case .notInICloud?: upload = .str("not in iCloud")
            case nil: break
            }
            let s = backup.settings()
            return JSONObject([
                (key: "configured", value: .bool(st.configured)), (key: "second", value: .bool(st.secondConfigured)),
                (key: "primary", value: s.primary.map(JSONValue.string) ?? .null), (key: "second_path", value: s.second.map(JSONValue.string) ?? .null),
                (key: "pending_key", value: .bool(BackupKey.loadPending() != nil)),
                (key: "upload", value: upload), (key: "last_check", value: st.lastCheck.map(JSONValue.string) ?? .null),
                (key: "last_drill", value: st.lastDrill.map(JSONValue.string) ?? .null),
                (key: "binders", value: .array(st.binders.map { b in .obj([("name", .string(names[b.id] ?? "a binder not on the Shelf")),
                                                                            ("at", b.at.map(JSONValue.string) ?? .null),
                                                                            ("error", b.error.map(JSONValue.string) ?? .null)]) })),
                (key: "offloaded", value: .array(backup.offloaded().map { o in .obj([
                    ("id", .string(o.backupID)), ("name", .string(o.name)), ("bytes", .int(Int(o.bytes))), ("at", .string(o.at)),
                    ("documents", .array(o.documents.map { .obj([("title", .string($0.title)), ("path", .string($0.path))]) }))]) })),
                (key: "requests", value: .array(BackupRequests(support: support).all().map { r in .obj([
                    ("id", .string(r.id)), ("kind", .string(r.kind)), ("state", .string(r.state)),
                    ("binder", r.binder.map(JSONValue.string) ?? .null), ("message", r.message.map(JSONValue.string) ?? .null)]) })),
            ])

        case "backup_new_key":
            // Step 1 of setup: a key the person saves, then types back (docs/backup.md §4).
            let key = BackupKey.generate()
            try BackupKey.storePending(key)
            return JSONObject([(key: "key", value: .string(key))])

        case "backup_setup":
            // Step 2: the typed key (a new one confirmed, or an existing one brought from another Mac).
            guard case .string(let typed)? = r["key"], case .string(let primaryPath)? = r["primary"], primaryPath.hasPrefix("/") else {
                throw Failure(message: "backup_setup needs key and primary")
            }
            let key: String
            if let pending = BackupKey.loadPending() {
                guard BackupKey.normalize(typed) == BackupKey.normalize(pending) else { throw Failure(message: "that is not the key shown; check it and type it again") }
                key = pending
            } else {
                key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let icloud = r["icloud_keychain"] == .bool(true)
            try Backup(support: support, key: key).setUp(primary: URL(fileURLWithPath: primaryPath, isDirectory: true), iCloudKeychain: icloud)
            try BackupKey.store(key, inICloudKeychain: icloud)
            BackupKey.clearPending()
            return JSONObject()

        case "backup_second":
            guard case .string(let path)? = r["folder"], path.hasPrefix("/") else { throw Failure(message: "backup_second needs folder") }
            try Backup(support: support).setSecond(URL(fileURLWithPath: path, isDirectory: true))
            return JSONObject()

        case "backup_request":
            // Offload, restore, drill or back up now: queued for the runtime's backup job.
            guard case .string(let kind)? = r["kind"], ["offload", "restore", "drill", "backup_now"].contains(kind) else {
                throw Failure(message: "backup_request needs kind")
            }
            var binderPath: String?
            if kind != "restore" {
                let f = try folder(r)
                if Owner.device(of: f) != deviceID { throw Failure(message: "this binder is not managed by this Mac") }
                binderPath = f.path
            }
            let req = BackupRequests.Request(id: UUIDv7.make(now: now), kind: kind, binder: binderPath, backupID: r["backup_id"]?.stringValue,
                                             target: r["target"]?.stringValue, confirmOpenItems: r["confirm_open_items"] == .bool(true),
                                             at: ISOTime.string(now))
            let queued = try BackupRequests(support: support).enqueue(req)
            return JSONObject([(key: "request", value: .string(queued.id))])

        case "peek":
            guard case .string(let id)? = r["backup_id"], case .string(let path)? = r["path"] else { throw Failure(message: "peek needs backup_id and path") }
            let file = try Backup(support: support).peek(id, path: path)
            return JSONObject([(key: "file", value: .string(file.path))])

        case "switch_dashboard":
            // The one-time switch card of binder-v0 §7.1, approved by the person.
            let f = try folder(r)
            try DashboardKeeper(folder: f, impl: client).switchOn(today: today, now: now)
            return JSONObject()

        case "doctor":
            let url = LifeprojRegistry.defaultPath()
            let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
            let rows = Shelf.rows(registry: registry, picked: ShelfStore(supportDirectory: support).pickedFolders())
            let findings = Doctor.run(rows: rows, deviceID: deviceID, registry: registry, support: support)
            return JSONObject([(key: "findings", value: .array(findings.map {
                .obj([("level", .string($0.level.rawValue)), ("binder", $0.binder.map(JSONValue.string) ?? .null), ("text", .string($0.text))])
            }))])

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
            let scope = clients.clients.first { $0.id == id }?.binders.keys.map { URL(fileURLWithPath: $0, isDirectory: true) } ?? []
            clients.revoke(id: id)
            try clients.save(support)
            // Its cards still waiting are withdrawn (architecture 7.5).
            var withdrawn = 0
            for folder in scope {
                for (p, _) in ProposalStore.list(in: folder) where p.state == "proposed" && p.actor["kind"] == .str("brain")
                    && p.actor["model"]?.stringValue == id {
                    try? TekaStore(folder: folder, client: client).reject(p, reason: "the brain was disconnected", now: now)
                    withdrawn += 1
                }
            }
            return JSONObject([(key: "withdrawn", value: .int(withdrawn))])

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
                o.set("undoable", .bool(!["external_edit", "add_log_entry", "reopen", "rename_teka", "set_meta", "set_disclosure"].contains(op["op"]?.stringValue ?? "")
                                        && op["compensates"] == nil))
                return .object(o)
            }))])

        default:
            throw Failure(message: "unknown command \(command)")
        }
    }

    func key(_ folder: URL, _ id: String) -> String { folder.path + "#" + id }

    func recordDigests(_ ids: [String], in folder: URL) {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        var digests = loadDigests()
        for (p, d) in ProposalStore.list(in: folder) where wanted.contains(p.id) { digests[key(folder, p.id)] = d }
        saveDigests(digests)
    }
}

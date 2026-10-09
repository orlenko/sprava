import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The binder commands: adoption, review cards, direct actions, undo, the dashboard switch, new binders and history.
extension Commands {
    static let binderCommands: [String: Handler] = [
        "adopt": { c, _, r, now, today in try c.adopt(r, now: now, today: today) },
        "proposals": { c, _, r, now, today in try c.proposals(r, now: now, today: today) },
        "approve": { c, command, r, now, today in try c.review(command, r, now: now, today: today) },
        "reject": { c, command, r, now, today in try c.review(command, r, now: now, today: today) },
        "apply": { c, _, r, now, today in try c.apply(r, now: now, today: today) },
        "undo": { c, _, r, now, today in try c.undo(r, now: now, today: today) },
        "switch_dashboard": { c, _, r, now, today in try c.switchDashboard(r, now: now, today: today) },
        "create_binder": { c, _, r, now, today in try c.createBinder(r, now: now, today: today) },
        "history": { c, _, r, now, today in try c.history(r, now: now, today: today) },
    ]

    func adopt(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        let inRegistry = r["in_registry"] == .bool(true)
        let result = try Adoption.adopt(f, inRegistry: inRegistry, deviceID: deviceID, today: today, now: now, client: client)
        try trustWritten(result.proposals.map(\.id), in: f)
        return JSONObject([(key: "mechanical", value: .int(result.mechanical.count)),
                           (key: "proposals", value: .array(result.proposals.map { .string($0.id) }))])
    }

    func proposals(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        // A widening made outside Sprava waits for the person's privacy card (architecture 4.5).
        if Owner.device(of: f) == deviceID, let card = try PrivacyRatchet.ensureCard(folder: f, client: client, now: now) {
            try trustWritten([card], in: f)
        }
        // A proposal file the runtime did not write has no recorded digest: it is shown as "not verified" and
        // cannot be approved (binder-v0 §6.5; architecture 4.6).
        let listed = ProposalStore.list(in: f)
        let digests = try loadDigests()
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
            if p.state == "proposed", (try? brainDisconnected(p)) == true {
                notes.insert("the brain that made this card was disconnected; it can only be rejected", at: 0)
            }
            o.set("notes", .array(notes.map(JSONValue.string)))
            // What the person may edit on the card (CardEdits).
            o.set("editable", .array(p.ops.enumerated().compactMap { i, op -> JSONValue? in
                if op["op"] == .str("add_item"), let item = op["args"]?["item"] {
                    return .obj([("index", .int(i)), ("title", item["title"] ?? .str("")), ("due", item["due"] ?? .str("")),
                                 ("priority", item["priority"] ?? .str("normal"))])
                }
                // An adoption repair card: the item's current values, for the person to complete (binder-v0 §9.4).
                guard op["op"] == .str("update_item"), p.raw["provenance"]?["repair"] != nil, let id = op["args"]?["id"],
                      let item = catalog?["open_items"]?.arrayValue?.first(where: { $0["id"] == id }) else { return nil }
                func text(_ key: String, _ fallback: String) -> JSONValue { .string(item[key]?.stringValue ?? fallback) }
                return .obj([("index", .int(i)), ("title", text("title", "")), ("due", text("due", "")),
                             ("priority", text("priority", "normal")), ("waiting_on", text("waiting_on", ""))])
            }))
            if let c = p.raw["confidence"] { o.set("confidence", c) }
            if let intake = p.raw["provenance"]?["intake"] { o.set("intake", intake) }
            if let folder = p.ops.first(where: { $0["op"] == .str("file_document") })?["args"]?["document"]?["path"]?.stringValue {
                o.set("document_folder", .string((folder as NSString).deletingLastPathComponent))
            }
            return .object(o)
        }))])
    }

    func review(_ command: String, _ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        guard case .string(let id)? = r["proposal"], case .string(let seen)? = r["digest"] else {
            throw Failure(message: "\(command) needs proposal and digest")
        }
        // A card Sprava did not write, or one changed since, is never approved; but the person may reject it as
        // shown, so a rejection checks the card's current bytes, which the listing showed.
        let current = ProposalStore.list(in: f).first { $0.0.id == id }?.1
        let expected: String
        if command == "reject" {
            guard let current else { throw Failure(message: "this card changed since it was shown; reload it") }
            expected = current
        } else {
            guard let recorded = try loadDigests()[key(f, id)] else {
                throw Failure(message: "this proposal was not written by Sprava, so it cannot be approved")
            }
            expected = recorded
        }
        guard expected == seen else { throw Failure(message: "this card changed since it was shown; reload it") }
        let proposal = try ProposalStore.load(id, in: f, expectedDigest: expected)
        let store = TekaStore(folder: f, client: client)
        if command == "approve" {
            // A brain's card stays withdrawn once the brain is disconnected, even when its rejection was not saved.
            if try brainDisconnected(proposal) {
                throw Failure(message: "the brain that made this card was disconnected; the card can only be rejected")
            }
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
            // How a filed document reached the person, when the source could not tell (adaptation-layer §3.3).
            if case .object(let answer)? = r["obtained"] {
                let channel = answer["channel"]?.stringValue ?? ""
                guard Self.channels.contains(channel) else { throw Failure(message: "channel must be one of \(Self.channels.sorted().joined(separator: ", "))") }
                let said = answer["said"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                edited = (edited ?? proposal.ops).map { op in
                    guard op["op"] == .str("file_document"), var args = op["args"]?.objectValue,
                          var doc = args["document"]?.objectValue else { return op }
                    var prov = doc["provenance"]?.objectValue ?? JSONObject()
                    var obtained = prov["obtained"]?.objectValue ?? JSONObject()
                    obtained.set("channel", .string(channel))
                    if let said, !said.isEmpty { obtained.set("said", .string(String(said.prefix(500)))) }
                    prov.set("obtained", .object(obtained))
                    doc.set("provenance", .object(prov))
                    args.set("document", .object(doc))
                    var changed = op
                    changed.set("args", .object(args))
                    return changed
                }
            }
            let applied = try store.approve(proposal, edited: edited, now: now)
            // An adopted binder whose repairs are done is offered its stamp (binder-v0 §9.4 step 6).
            let stamp = (try? Adoption.offerStamp(f, client: client, now: now)) ?? nil
            try trustWritten([id] + store.createdProposals + (stamp.map { [$0] } ?? []), in: f)
            return JSONObject([(key: "applied", value: .int(applied.count))])
        }
        try store.reject(proposal, reason: r["reason"]?.stringValue, now: now)
        try trustWritten([id], in: f)
        return JSONObject()
    }

    /// Trusts cards a command just wrote through the shared `TrustBacklog`: when Sprava's record of the cards cannot
    /// be written now, they are kept and recorded on a later pass, never left unapprovable for good (architecture
    /// 4.6). Throws as `recordDigests` did, so the command still reports the failure.
    func trustWritten(_ ids: [String], in folder: URL) throws {
        guard !ids.isEmpty else { return }
        try TrustBacklog.shared(support: support).trust(ids, in: folder, commands: self)
    }

    func apply(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
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
        try trustWritten(store.createdProposals, in: f)
        return JSONObject([(key: "op", value: applied.first?["id"] ?? .null)])
    }

    func undo(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        guard case .string(let opID)? = r["op_id"] else { throw Failure(message: "undo needs op_id") }
        let store = TekaStore(folder: f, client: client)
        let applied = try store.undo(opID: opID, now: now)
        try trustWritten(store.createdProposals, in: f)
        return JSONObject([(key: "op", value: applied.first?["id"] ?? .null)])
    }

    func switchDashboard(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The one-time switch card of binder-v0 §7.1, approved by the person.
        let f = try folder(r)
        try DashboardKeeper(folder: f, impl: client).switchOn(today: today, now: now)
        return JSONObject()
    }

    func createBinder(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // A new binder from a template (mvp.md feature 6): ready, stamped v0, at disclosure none, on the shelf.
        guard case .string(let parentPath)? = r["parent"], parentPath.hasPrefix("/"), case .string(let name)? = r["name"] else {
            throw Failure(message: "create_binder needs parent and name")
        }
        let template = BinderTemplate.all.first { $0.key == (r["template"]?.stringValue ?? "tax-year") } ?? .taxYear
        let url = LifeprojRegistry.defaultPath()
        let registry = FileManager.default.fileExists(atPath: url.path) ? try? LifeprojRegistry.load(from: url) : nil
        let store = ShelfStore(supportDirectory: support)
        // shelf.json is read first: one that cannot be read fails before any folder is made.
        let names = Shelf.rows(registry: registry, picked: try store.readFolders(), includeArchived: true).map(\.name)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let year = r["year"]?.numberValue?.safeInteger.map(Int.init) ?? calendar.component(.year, from: now)
        let created = try BinderCreator.create(parent: URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL, name: name,
                                               template: template, deviceID: deviceID, knownNames: names, year: year, today: today,
                                               client: client, now: now)
        if let card = created.checklistCard { try trustWritten([card], in: created.folder) }
        try store.add(created.folder)
        try FilingList(support: support).set(created.folder, .init(description: template.description(year), filing: false))
        return JSONObject([(key: "binder", value: .string(created.folder.path)),
                           (key: "proposal", value: created.checklistCard.map(JSONValue.string) ?? .null)])
    }

    func history(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
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
            // The same list Undo.compensate handles, so a filing is never offered as undoable (binder-v0 §6.10).
            o.set("undoable", .bool(Undo.supported(op) && op["compensates"] == nil))
            return .object(o)
        }))])
    }
}

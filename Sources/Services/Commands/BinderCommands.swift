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

    /// The longest answer the person may give about how a document reached them (`obtained.said`).
    static let maxSaid = 500
    /// A legacy dashboard is copied at adoption; a larger one is refused before any binder write.
    static let adoptionDashboardLimit = 16 << 20

    func adopt(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        // One owner per binder: an owner record left by another Sprava's interrupted adoption is never taken over,
        // and one that cannot be read is not overwritten (only its recorded owner resumes the adoption).
        if FileManager.default.fileExists(atPath: f.appendingPathComponent(".sprava/owner.json").path),
           ownerDevice(f) != deviceID {
            throw Failure(message: "this binder has an owner record that is not this Mac's; it is left as it is")
        }
        switch SafeFile.read(f.appendingPathComponent("DASHBOARD.md"), limit: Self.adoptionDashboardLimit) {
        case .ok, .missing: break
        case .refused, .unreadable:
            throw Failure(message: "DASHBOARD.md cannot be safely copied within the 16 MiB adoption limit; the binder was left as it is")
        }
        _ = try reviewableCards(in: f, catalog: Teka.read(f).catalog)
        let inRegistry = r["in_registry"] == .bool(true)
        let result = try Adoption.adopt(f, inRegistry: inRegistry, deviceID: deviceID, today: today, now: now, client: client)
        try recordDigests(result.proposals.map(\.id), in: f)
        return JSONObject([(key: "mechanical", value: .int(result.mechanical.count)),
                           (key: "proposals", value: .array(result.proposals.map { .string($0.id) }))])
    }

    func proposals(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        // Check before helpers scan existing cards or offer another one, then read the resulting collection.
        let teka = Teka.read(f)
        _ = try reviewableCards(in: f, catalog: teka.catalog)
        // A widening made outside Sprava waits for the person's privacy card (architecture 4.5); a binder whose writes
        // are blocked gets no card until it is repaired (binder-v0 §9.6).
        if !teka.writesBlocked, ownerDevice(f) == deviceID {
            if let card = try PrivacyRatchet.ensureCard(folder: f, client: client, now: now) { try recordDigests([card], in: f) }
            // The stamp offer an approval could not make is made again here (binder-v0 §9.4 step 6).
            _ = try reviewableCards(in: f, catalog: teka.catalog)
            if let stamp = try Adoption.offerStamp(f, client: client, now: now) { try recordDigests([stamp], in: f) }
        }
        // A proposal file the runtime did not write has no recorded digest: it is shown as "not verified" and
        // cannot be approved (binder-v0 §6.5; architecture 4.6).
        let listed = try reviewableCards(in: f, catalog: teka.catalog)
        let digests = try loadDigests()
        let catalog = teka.catalog
        let items = Dictionary((catalog?["open_items"]?.arrayValue ?? []).compactMap { item in
            item["id"].map { ($0, item) }
        }, uniquingKeysWith: { first, _ in first })
        func description(_ op: JSONObject) -> String {
            let item = op["args"]?["id"].flatMap { items[$0] }
            let small = JSONObject([(key: "meta", value: catalog?["meta"] ?? .obj([])),
                                    (key: "open_items", value: .array(item.map { [$0] } ?? []))])
            return Proposal.describe(op, catalog: small)
        }
        return JSONObject([(key: "proposals", value: .array(listed.map { p, digest in
            var o = JSONObject()
            o.set("id", .string(p.id))
            o.set("state", .string(p.state))
            o.set("title", .string(p.title))
            o.set("actor", .object(p.actor))
            o.set("digest", .string(digest))
            o.set("verified", .bool(digests[key(f, p.id)] == digest))
            o.set("lines", .array(p.ops.map { .string(description($0)) }))
            var notes = p.cardNotes
            if p.state == "proposed", case let changed = p.changedSince(catalog: catalog), !changed.isEmpty {
                notes.insert("needs a look: changed since this card was made: " + changed.joined(separator: ", "), at: 0)
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

    /// Bound loading and every catalog scan before display or helpers inspect unverified cards (architecture 4.6).
    func reviewableCards(in folder: URL, catalog: JSONObject?) throws -> [(Proposal, String)] {
        let listed = try ProposalStore.boundedList(in: folder)
        var work = 0
        for (p, _) in listed {
            let units = p.ops.count + (p.raw["expect"]?.objectValue?.entries.count ?? 0)
            guard units <= 500 - work else { throw Failure(message: "these cards are too large to review safely; split them into smaller cards before approval") }
            work += units
        }
        let rows = (catalog?["open_items"]?.arrayValue?.count ?? 0) + (catalog?["documents"]?.arrayValue?.count ?? 0)
        guard listed.count <= 100, rows <= 500_000 / max(1, work) else {
            throw Failure(message: "these cards are too large to review safely; split them into smaller cards before approval")
        }
        return listed
    }

    func review(_ command: String, _ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        guard case .string(let id)? = r["proposal"], case .string(let seen)? = r["digest"] else {
            throw Failure(message: "\(command) needs proposal and digest")
        }
        // A card Sprava did not write is never approved, but the person may reject it, as shown.
        let current = try reviewableCards(in: f, catalog: Teka.read(f).catalog).first { $0.0.id == id }?.1
        guard let recorded = try loadDigests()[key(f, id)] ?? (command == "reject" ? current : nil) else {
            throw Failure(message: "this proposal was not written by Sprava, so it cannot be approved")
        }
        guard recorded == seen else { throw Failure(message: "this card changed since it was shown; reload it") }
        let proposal = try ProposalStore.load(id, in: f, expectedDigest: recorded)
        let store = TekaStore(folder: f, client: client)
        if command == "approve" {
            guard proposal.ops.count + (proposal.raw["expect"]?.objectValue?.entries.count ?? 0) <= 500 else {
                throw Failure(message: "this card is too large to review safely; split it into smaller cards before approval")
            }
            // A change the person made on the card that cannot be read refuses the approval: approving the card
            // unchanged would apply exactly what they tried to alter.
            if let v = r["edits"], v.arrayValue == nil { throw Failure(message: "edits must be a list; nothing was approved") }
            if let v = r["document_folder"], v.stringValue == nil { throw Failure(message: "document_folder must be text; nothing was approved") }
            if let v = r["obtained"], v.objectValue == nil { throw Failure(message: "obtained must be an object; nothing was approved") }
            var edited: [JSONObject]?
            if case .array(let edits)? = r["edits"], !edits.isEmpty {
                guard edits.allSatisfy({ $0["skip"] == nil || $0["skip"]?.boolValue != nil }) else {
                    throw Failure(message: "skip must be true or false; nothing was approved")
                }
                edited = try CardEdits.apply(edits, to: proposal.ops)
            }
            // The person may pick another folder for a filing card; only the folder changes, never the file.
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
                // The person's words are kept verbatim, so an answer too long to keep whole is refused, never cut.
                if let value = answer["said"], value.stringValue == nil { throw Failure(message: "obtained.said must be text; nothing was approved") }
                let said = answer["said"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let said, said.count > Self.maxSaid {
                    throw Failure(message: "what you said about how it reached you is longer than \(Self.maxSaid) characters; shorten it. Nothing was approved")
                }
                edited = (edited ?? proposal.ops).map { op in
                    guard op["op"] == .str("file_document"), var args = op["args"]?.objectValue,
                          var doc = args["document"]?.objectValue else { return op }
                    var prov = doc["provenance"]?.objectValue ?? JSONObject()
                    var obtained = prov["obtained"]?.objectValue ?? JSONObject()
                    obtained.set("channel", .string(channel))
                    if let said, !said.isEmpty { obtained.set("said", .string(said)) }
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
            try recordDigests([id] + store.createdProposals, in: f)
            var result = JSONObject([(key: "applied", value: .int(applied.count))])
            // The approval stands either way; a stamp that could not be offered is reported, and offered again the
            // next time the binder's cards are listed.
            do {
                _ = try reviewableCards(in: f, catalog: Teka.read(f).catalog)
                if let stamp = try Adoption.offerStamp(f, client: client, now: now) { try recordDigests([stamp], in: f) }
            } catch {
                result.set("stamp_error", .string("the binder's stamp could not be offered yet (\(error)); it is offered again when its cards are next opened"))
            }
            return result
        }
        try store.reject(proposal, reason: r["reason"]?.stringValue, now: now)
        try recordDigests([id], in: f)
        return JSONObject()
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
        let body = TekaStore.OpBody(op: op, args: args, actor: actor, extra: extra)
        // An item the person adds names itself `$new:1`; its id is minted under the binder's lock (binder-v0 §5.6).
        let applied = op == "add_item" ? try store.applyMinting([body], now: now) : try store.apply([body], now: now)
        try recordDigests(store.createdProposals, in: f)
        return JSONObject([(key: "op", value: applied.first?["id"] ?? .null)])
    }

    func undo(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let f = try folder(r)
        guard case .string(let opID)? = r["op_id"] else { throw Failure(message: "undo needs op_id") }
        let store = TekaStore(folder: f, client: client)
        let outcome = try store.undoChange(opID: opID, now: now)
        try recordDigests(store.createdProposals, in: f)
        // Fields changed again since the undone change keep their newer values; the app names them (binder-v0 §6.10).
        return JSONObject([(key: "op", value: outcome.ops.first?["id"] ?? .null),
                           (key: "kept", value: .array(outcome.kept.map(JSONValue.string)))])
    }

    func switchDashboard(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // The one-time switch card of binder-v0 §7.1, approved by the person.
        let f = try folder(r)
        try DashboardKeeper(folder: f, impl: client).switchOn(today: today, now: now)
        return JSONObject()
    }

    func createBinder(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // A new binder from a template (mvp.md feature 6): ready, stamped v0, at disclosure none, on the shelf. With
        // `folder`, an empty folder the person picked becomes the binder, in its own parent.
        var existing: URL?
        if case .string(let path)? = r["folder"] {
            guard path.hasPrefix("/") else { throw Failure(message: "create_binder needs an absolute folder") }
            existing = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        }
        guard case .string(let parentPath)? = existing.map({ .string($0.deletingLastPathComponent().path) }) ?? r["parent"],
              parentPath.hasPrefix("/"), case .string(let typed)? = r["name"] else {
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
        let parent = URL(fileURLWithPath: parentPath, isDirectory: true).standardizedFileURL
        // Whatever the person typed becomes a valid name that is free, rather than a refusal after the dialogs; the
        // response's `binder` path carries the name it took.
        let free = BinderCreator.freeName(BinderCreator.name(for: typed, template: template, year: year, existing: existing),
                                          parent: parent, knownNames: names, existing: existing)
        let created = try BinderCreator.create(parent: parent, name: free,
                                               template: template, deviceID: deviceID, knownNames: names, year: year, today: today,
                                               client: client, now: now, existing: existing)
        if let card = created.checklistCard { try recordDigests([card], in: created.folder) }
        try store.add(created.folder)
        try FilingList(support: support).set(created.folder, .init(description: template.description(year), filing: false))
        return JSONObject([(key: "binder", value: .string(created.folder.path)),
                           (key: "proposal", value: created.checklistCard.map(JSONValue.string) ?? .null)])
    }

    func history(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // Recent changes a person might undo: the last 20 ops that changed something, newest first.
        let f = try folder(r)
        // The op log is read only once the reader found it a regular file in a real `.sprava` folder: a link is never
        // followed out of the binder and a FIFO never blocks the command queue (binder-v0 §3.6).
        let teka = Teka.read(f)
        if teka.writesBlocked { throw Failure(message: "this binder needs a repair first: " + teka.reasons.joined(separator: "; ")) }
        let log = try TekaStore(folder: f, client: client).readOpLog().ops
        let undone = Set(log.compactMap { $0["compensates"]?.stringValue })
        let catalog = teka.catalog
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

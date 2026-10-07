import Foundation

/// Minting new ids at apply time (binder-v0 §5.6): `<prefix>-<YYYY>-<NNN>`, one more than the largest number
/// already used that year in `open_items[]`, closure ids and `item` values in the processing log, and the op log.
public enum IDMint {
    /// The mint prefix: `meta.name` when it has the recommended shape, otherwise a cleaned-up form of it.
    public static func prefix(for name: String) -> String {
        if name.wholeMatch(of: /^[a-z0-9][a-z0-9-]*$/) != nil { return name }
        let folded = name.applyingTransform(.stripDiacritics, reverse: false)?.lowercased() ?? name.lowercased()
        var out = ""
        var lastDash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastDash = false
            } else if !lastDash {
                out.append("-")
                lastDash = true
            }
        }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return out.isEmpty ? "item" : out
    }

    public static func next(catalog: JSONObject, opLog: [JSONObject], year: Int, document: Bool = false) -> String {
        let name = catalog["meta"]?["name"]?.stringValue ?? "item"
        let p = prefix(for: name)
        let infix = document ? "-doc" : ""
        let pattern = try! Regex("^\(NSRegularExpression.escapedPattern(for: p))\(infix)-(\\d{4})-(\\d{3,})$")
        var used: [JSONValue] = []
        let arrays = document ? ["documents"] : ["open_items"]
        for key in arrays { used += (catalog[key]?.arrayValue ?? []).compactMap { $0["id"] } }
        for entry in catalog["processing_log"]?.arrayValue ?? [] {
            used += [entry["id"], entry["item"], entry["document"]].compactMap { $0 }
        }
        for op in opLog {
            if let id = op["args"]?["item"]?["id"] { used.append(id) }
            if let id = op["args"]?["document"]?["id"] { used.append(id) }
        }
        var maxN = 0
        for case .string(let s) in used {
            guard let m = s.wholeMatch(of: pattern), Int(m.output[1].substring ?? "") == year,
                  let n = Int(m.output[2].substring ?? "") else { continue }
            maxN = max(maxN, n)
        }
        // Skip a number whose slice id an open item already projects to, such as `tax-2026-001` beside a bare
        // `2026-001` (binder-v0 §5.6).
        let teka = catalog["meta"]?["name"]?.stringValue ?? name
        let taken = Set((catalog["open_items"]?.arrayValue ?? []).compactMap { $0["id"] }.map { HubLane.plainSliceID($0, teka: teka) })
        let usedText = Set(used.compactMap(\.stringValue))
        var n = maxN + 1
        while true {
            let candidate = "\(p)\(infix)-\(year)-" + String(format: "%03d", n)
            if document || (!taken.contains(HubLane.plainSliceID(.string(candidate), teka: teka)) && !usedText.contains(candidate)) {
                return candidate
            }
            n += 1
        }
    }
}

/// Undo appends a compensating op that names the op it reverses (binder-v0 §6.10). Nothing is deleted.
public enum Undo {
    public struct Unsupported: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// The compensating op body for `target`, given the catalog now and the op log. `stateBefore` is the catalog as
    /// it was just before `target` (from replay), used to restore earlier values.
    public static func compensate(_ target: JSONObject, catalog: JSONObject, opLog: [JSONObject], stateBefore: JSONObject,
                                  year: Int, now: Date) throws -> (op: String, args: JSONObject) {
        let args = target["args"]?.objectValue ?? JSONObject()
        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        func itemBefore(_ id: JSONValue) -> JSONObject? {
            stateBefore["open_items"]?.arrayValue?.first { $0["id"] == id }?.objectValue
        }
        switch target["op"]?.stringValue {
        case "add_item":
            guard let id = args["item"]?["id"] else { throw Unsupported(message: "no item id") }
            var a = JSONObject()
            a.set("id", id)
            a.set("closed_at", .string(at))
            a.set("source", .str("user"))
            a.set("reason", .str("undo"))
            return ("drop", a)

        case "update_item":
            guard let id = args["id"], let before = itemBefore(id) else { throw Unsupported(message: "the item's earlier state is unknown") }
            let set = args["set"]?.objectValue ?? JSONObject()
            let unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var restore = JSONObject()
            var remove: [String] = []
            for key in set.keys + unset {
                if let old = before[key] { restore.set(key, old) } else { remove.append(key) }
            }
            if let derived = before["derived"] { restore.set("derived", derived) } else if !restore.contains("derived") { remove.append("derived") }
            var a = JSONObject()
            a.set("id", id)
            if !restore.entries.isEmpty { a.set("set", .object(restore)) }
            let current = catalog["open_items"]?.arrayValue?.first { $0["id"] == id }
            let reallyRemove = remove.filter { current?[$0] != nil && !restore.contains($0) }
            if !reallyRemove.isEmpty { a.set("unset", .array(reallyRemove.map(JSONValue.string))) }
            return ("update_item", a)

        case "set_status":
            guard let id = args["id"], let before = itemBefore(id) else { throw Unsupported(message: "the item's earlier state is unknown") }
            var a = JSONObject()
            a.set("id", id)
            a.set("status", before["status"] ?? .str("open"))
            for key in ["waiting_on", "follow_up_at", "expected_by"] { if let v = before[key] { a.set(key, v) } }
            a.set("derived", before["derived"] ?? .array([]))
            return ("set_status", a)

        case "dismiss", "undismiss":
            guard let id = args["id"] else { throw Unsupported(message: "no item id") }
            return (target["op"]?.stringValue == "dismiss" ? "undismiss" : "dismiss", JSONObject([(key: "id", value: id)]))

        case "complete" where args["next_due"] != nil:
            guard let id = args["id"], let due = args["occurrence_due"] else { throw Unsupported(message: "no occurrence") }
            return ("update_item", JSONObject([(key: "id", value: id), (key: "set", value: .obj([("due", due)]))]))

        case "complete", "drop":
            // Reopen under a new id: the title and kind from the closure entry, the rest from its `final`.
            guard let closedID = args["id"],
                  let entry = catalog["processing_log"]?.arrayValue?.last(where: {
                      ($0["id"] ?? $0["item"]) == closedID && $0["op_id"] == target["id"] })?.objectValue
            else { throw Unsupported(message: "the closure entry is not in the processing log") }
            var item = JSONObject()
            item.set("id", .string(IDMint.next(catalog: catalog, opLog: opLog, year: year)))
            item.set("title", entry["title"] ?? .str(""))
            if let kind = entry["kind"] { item.set("kind", kind) }
            // Nulls are dropped and compact or week dates written out, so the reopened item meets the v0 rules.
            for e in entry["final"]?.objectValue?.entries ?? []
            where !["provenance", "created_at", "updated_at", "derived", "dismissed", "recurrence"].contains(e.key) && e.value != .null {
                if ["due", "follow_up_at", "expected_by"].contains(e.key), case .string(let text) = e.value {
                    guard let date = CalendarDate.strict(text) ?? CalendarDate.lenient(text) else { continue }
                    item.set(e.key, .string(date.description))
                } else {
                    item.set(e.key, e.value)
                }
            }
            if item["due"] == nil { item.set("no_deadline", .bool(true)) } else { item.remove("no_deadline") }
            if item["status"] == nil || item["status"] == .str("done") { item.set("status", .str("open")) }
            if item["priority"] == nil { item.set("priority", .str("normal")) }
            item.set("created_at", .string(at))
            item.set("updated_at", .string(at))
            item.set("provenance", .obj([("reopened_from", closedID), ("approved_by", .str("user"))]))
            return ("reopen", JSONObject([(key: "id", value: closedID), (key: "item", value: .object(item))]))

        case let other:
            throw Unsupported(message: "\(other ?? "this op") records a fact and cannot be undone")
        }
    }
}

extension TekaStore {
    /// Undoes one applied op by appending its compensating op (actor user), with `compensates` set.
    @discardableResult
    public func undo(opID: String, now: Date = Date()) throws -> [JSONObject] {
        let log = try readOpLog().ops
        guard let index = log.firstIndex(where: { $0["id"]?.stringValue == opID }) else { throw Refused(reason: "no such op") }
        if log.contains(where: { $0["compensates"]?.stringValue == opID }) { throw Refused(reason: "already undone") }
        guard index > 0 else { throw Refused(reason: "the import snapshot cannot be undone") }
        let before = try Replay.run(Array(log[..<index]))
        let catalog = try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue ?? JSONObject()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let (op, args) = try Undo.compensate(log[index], catalog: catalog, opLog: log, stateBefore: before,
                                             year: calendar.component(.year, from: now), now: now)
        let actor = JSONObject([(key: "kind", value: .str("user"))])
        var bodies: [OpBody] = [.init(op: op, args: args, actor: actor, extra: [("compensates", .string(opID)), ("note", .str("undo"))])]
        // set_status keeps waiting fields it is not given unless the status is open, so fields the undone op
        // introduced are removed by a second op in the same batch.
        if op == "set_status", let id = args["id"],
           let now_ = catalog["open_items"]?.arrayValue?.first(where: { $0["id"] == id })?.objectValue,
           let was = before["open_items"]?.arrayValue?.first(where: { $0["id"] == id })?.objectValue,
           args["status"]?.stringValue != "open" {
            let introduced = ["waiting_on", "follow_up_at", "expected_by"].filter { now_[$0] != nil && was[$0] == nil }
            if !introduced.isEmpty {
                bodies.append(.init(op: "update_item", args: JSONObject([(key: "id", value: id), (key: "unset", value: .array(introduced.map(JSONValue.string)))]),
                                    actor: actor, extra: [("compensates", .string(opID)), ("note", .str("undo"))]))
            }
        }
        return try apply(bodies, batch: bodies.count > 1 ? UUIDv7.make(now: now) : nil, now: now)
    }
}

/// Placeholder ids (`"$new:1"`) in a proposal are minted when the proposal is applied, never when it is proposed,
/// so two pending proposals never claim one number (binder-v0 §5.6). Later ops in the batch may name a placeholder.
public enum Placeholders {
    public static func resolve(_ ops: [JSONObject], catalog: JSONObject, opLog: [JSONObject], year: Int, at: String) -> [JSONObject] {
        var minted: [String: JSONValue] = [:]
        var working = catalog
        var out: [JSONObject] = []
        for var op in ops {
            guard case .object(var args)? = op["args"] else { out.append(op); continue }
            if op["op"]?.stringValue == "add_item", case .object(var item)? = args["item"] {
                if case .string(let id)? = item["id"], id.hasPrefix("$new:") {
                    let real = JSONValue.string(IDMint.next(catalog: working, opLog: opLog, year: year))
                    minted[id] = real
                    item.set("id", real)
                }
                if item["created_at"] == nil { item.set("created_at", .string(at)) }
                if item["updated_at"] == nil { item.set("updated_at", .string(at)) }
                args.set("item", .object(item))
                var items = working["open_items"]?.arrayValue ?? []
                items.append(.object(item))
                working.set("open_items", .array(items))
            } else if op["op"]?.stringValue == "file_document", case .object(var document)? = args["document"] {
                if case .string(let id)? = document["id"], id.hasPrefix("$new:") {
                    let real = JSONValue.string(IDMint.next(catalog: working, opLog: opLog, year: year, document: true))
                    minted[id] = real
                    document.set("id", real)
                }
                args.set("document", .object(document))
                var docs = working["documents"]?.arrayValue ?? []
                docs.append(.object(document))
                working.set("documents", .array(docs))
            } else if case .string(let ref)? = args["id"], let real = minted[ref] {
                args.set("id", real)
            }
            op.set("args", .object(args))
            out.append(op)
        }
        return out
    }
}

extension TekaStore {
    /// Checks a batch of op bodies against the current catalog without writing anything, as a proposal would be
    /// applied (placeholders minted, the actor's approval assumed).
    public static func dryRun(_ bodies: [JSONObject], actor: JSONObject, folder: URL, now: Date) throws {
        let store = TekaStore(folder: folder)
        let (catalog, _, _) = try store.readCatalog()
        let log = try store.readOpLog().ops
        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        let year = Calendar(identifier: .gregorian).component(.year, from: now)
        let resolved = Placeholders.resolve(bodies, catalog: catalog, opLog: log, year: year, at: at)
        let lines = resolved.map { body -> JSONObject in
            var line = JSONObject()
            line.set("id", .string(UUIDv7.make(now: now)))
            line.set("at", .string(at))
            line.set("actor", .object(actor))
            line.set("proposal", .str("dry-run"))
            line.set("approved_by", .str("user"))
            line.set("op", body["op"] ?? .null)
            line.set("args", body["args"] ?? .obj([]))
            return line
        }
        _ = try TransactionGuard.check(lines, on: catalog, knownIDs: Set(log.compactMap { $0["args"]?["item"]?["id"] }))
    }
}

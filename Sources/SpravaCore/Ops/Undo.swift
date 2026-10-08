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

    /// Every record id the op log has ever seen, so a minted id is never one of them (binder-v0 §5.6): the records
    /// of each `import_snapshot`, the new records of `add_item`, `reopen` and `file_document`, and the records an
    /// `external_edit` or `migrate` patch wrote (the `id`, `item` and `document` of every object in its values).
    public static func usedIDs(opLog: [JSONObject]) -> [JSONValue] {
        var out: [JSONValue] = []
        func scan(_ value: JSONValue) {
            switch value {
            case .object(let o):
                for key in ["id", "item", "document"] {
                    if let v = o[key], v.stringValue != nil || v.numberValue != nil { out.append(v) }
                }
                for e in o.entries { scan(e.value) }
            case .array(let a): a.forEach(scan)
            default: break
            }
        }
        for op in opLog {
            let args = op["args"]
            switch op["op"]?.stringValue {
            case "import_snapshot"?:
                let catalog = args?["catalog"]
                for key in ["open_items", "documents", "processing_log"] { (catalog?[key]?.arrayValue ?? []).forEach(scan) }
            case "external_edit"?, "migrate"?:
                for step in args?["patch"]?.arrayValue ?? [] { if let v = step["value"] { scan(v) } }
            default:
                if let id = args?["item"]?["id"] { out.append(id) }
                if let id = args?["document"]?["id"] { out.append(id) }
            }
        }
        return out
    }

    /// The next id, or a refusal when the year's sequence is used up: an imported id such as
    /// `<prefix>-2026-9223372036854775807` leaves no larger number, and that is an error, never a crash.
    public static func next(catalog: JSONObject, opLog: [JSONObject], year: Int, document: Bool = false) throws -> String {
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
        used += usedIDs(opLog: opLog)
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
        var n = maxN
        while true {
            let (following, overflow) = n.addingReportingOverflow(1)
            guard !overflow else { throw TekaStore.Refused(reason: "the id sequence \(p)\(infix)-\(year) is used up; no new id can be minted this year") }
            n = following
            // Written out with at least three digits; a 64-bit number never goes through a 32-bit `%d`.
            let digits = String(n)
            let candidate = "\(p)\(infix)-\(year)-" + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
            if document || (!taken.contains(HubLane.plainSliceID(.string(candidate), teka: teka)) && !usedText.contains(candidate)) {
                return candidate
            }
        }
    }
}

/// Undo appends a compensating op that names the op it reverses (binder-v0 §6.10). Nothing is deleted.
public enum Undo {
    public struct Unsupported: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// The ops `compensate` can reverse; every other op records a fact or is corrected by another op (binder-v0 §6.10).
    public static func supported(_ op: JSONObject) -> Bool {
        ["add_item", "update_item", "set_status", "dismiss", "undismiss", "complete", "drop"].contains(op["op"]?.stringValue ?? "")
    }

    /// The compensating op body for `target`, given the catalog now and the op log. `stateBefore` is the catalog as
    /// it was just before `target` (from replay), used to restore earlier values. `stateAfter`, the catalog just after
    /// it, guards against undoing through a newer change: when a field the target wrote has changed since, the undo
    /// is refused rather than overwriting that change.
    public static func compensate(_ target: JSONObject, catalog: JSONObject, opLog: [JSONObject], stateBefore: JSONObject,
                                  stateAfter: JSONObject? = nil, year: Int, now: Date) throws -> (op: String, args: JSONObject) {
        let args = target["args"]?.objectValue ?? JSONObject()
        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        func itemBefore(_ id: JSONValue) -> JSONObject? {
            stateBefore["open_items"]?.arrayValue?.first { $0["id"] == id }?.objectValue
        }
        func unchangedSince(_ id: JSONValue, _ fields: [String]) throws {
            guard let stateAfter else { return }
            let then = stateAfter["open_items"]?.arrayValue?.first { $0["id"] == id }
            let current = catalog["open_items"]?.arrayValue?.first { $0["id"] == id }
            for field in fields where current?[field] != then?[field] {
                throw Unsupported(message: "\(field) changed since; edit it instead")
            }
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
            try unchangedSince(id, set.keys + unset)
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
            try unchangedSince(id, ["status", "waiting_on", "follow_up_at", "expected_by"])
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
            item.set("id", .string(try IDMint.next(catalog: catalog, opLog: opLog, year: year)))
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
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let actor = JSONObject([(key: "kind", value: .str("user"))])
        // The compensation is built from the catalog and log read under the lock, after outside edits were absorbed,
        // so an edit made meanwhile is seen and never overwritten with older values.
        return try apply(building: { catalog, log in
            guard let index = log.firstIndex(where: { $0["id"]?.stringValue == opID }) else { throw Refused(reason: "no such op") }
            if log.contains(where: { $0["compensates"]?.stringValue == opID }) { throw Refused(reason: "already undone") }
            guard index > 0 else { throw Refused(reason: "the import snapshot cannot be undone") }
            let before = try Replay.run(Array(log[..<index]))
            let after = try Replay.run(Array(log[...index]))
            let (op, args) = try Undo.compensate(log[index], catalog: catalog, opLog: log, stateBefore: before, stateAfter: after,
                                                 year: calendar.component(.year, from: now), now: now)
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
            return bodies
        }, batch: UUIDv7.make(now: now), now: now)
    }
}

/// Placeholder ids (`"$new:1"`) in a proposal are minted when the proposal is applied, never when it is proposed,
/// so two pending proposals never claim one number (binder-v0 §5.6). Later ops in the batch may name a placeholder.
public enum Placeholders {
    public static func resolve(_ ops: [JSONObject], catalog: JSONObject, opLog: [JSONObject], year: Int, at: String) throws -> [JSONObject] {
        var minted: [String: JSONValue] = [:]
        var working = catalog
        var out: [JSONObject] = []
        for var op in ops {
            guard case .object(var args)? = op["args"] else { out.append(op); continue }
            if op["op"]?.stringValue == "add_item", case .object(var item)? = args["item"] {
                if case .string(let id)? = item["id"], id.hasPrefix("$new:") {
                    let real = JSONValue.string(try IDMint.next(catalog: working, opLog: opLog, year: year))
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
                    let real = JSONValue.string(try IDMint.next(catalog: working, opLog: opLog, year: year, document: true))
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
        let resolved = try Placeholders.resolve(bodies, catalog: catalog, opLog: log, year: year, at: at)
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
        _ = try TransactionGuard.check(lines, on: catalog, knownIDs: Set(IDMint.usedIDs(opLog: log)))
    }
}

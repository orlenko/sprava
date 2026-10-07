import Foundation

/// Minting new ids at apply time (teka-v0 §5.6): `<prefix>-<YYYY>-<NNN>`, one more than the largest number
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
        return "\(p)\(infix)-\(year)-" + String(format: "%03d", maxN + 1)
    }
}

/// Undo appends a compensating op that names the op it reverses (teka-v0 §6.10). Nothing is deleted.
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
                  let entry = catalog["processing_log"]?.arrayValue?.last(where: { $0["id"] == closedID && $0["op_id"] == target["id"] })?.objectValue
            else { throw Unsupported(message: "the closure entry is not in the processing log") }
            var item = JSONObject()
            item.set("id", .string(IDMint.next(catalog: catalog, opLog: opLog, year: year)))
            item.set("title", entry["title"] ?? .str(""))
            if let kind = entry["kind"] { item.set("kind", kind) }
            for e in entry["final"]?.objectValue?.entries ?? [] where !["provenance", "created_at", "updated_at", "derived"].contains(e.key) {
                item.set(e.key, e.value)
            }
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
        return try apply([.init(op: op, args: args, actor: actor, extra: [("compensates", .string(opID)), ("note", .str("undo"))])], now: now)
    }
}

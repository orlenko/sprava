import Foundation

/// Applies one op to a catalog: a pure function of the catalog and the op line (teka-v0 §6.3). An applied op
/// carries every value its effect needs, so replaying a log gives the same catalogs and the same hashes on any
/// implementation. It changes the catalog only; it never touches a file.
public enum OpApplier {
    public struct Failure: Error, CustomStringConvertible, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    public static let opTypes: Set<String> = [
        "add_item", "update_item", "set_status", "complete", "drop", "reopen", "dismiss", "undismiss",
        "file_document", "update_document", "add_log_entry", "set_meta", "set_disclosure", "rename_teka",
        "external_edit", "import_snapshot", "migrate", "abort", "expunge",
    ]

    /// Applies `op` (a whole op line: `id`, `at`, `actor`, `op`, `args`, ...) to `catalog`.
    public static func apply(_ op: JSONObject, to catalog: JSONObject) throws -> JSONObject {
        guard case .string(let type)? = op["op"], opTypes.contains(type) else { throw Failure("unknown op") }
        guard case .object(let args)? = op["args"] else { throw Failure("\(type): args must be an object") }
        guard case .string(let at)? = op["at"] else { throw Failure("\(type): at is required") }
        let opID = op["id"] ?? .null
        let actor = op["actor"]?.objectValue ?? JSONObject()
        let via = actor["client"] ?? .null
        let actorKind = actor["kind"] ?? .null
        var c = catalog

        switch type {
        case "import_snapshot", "abort", "expunge":
            return c

        case "external_edit", "migrate":
            guard case .array(let patch)? = args["patch"] else { throw Failure("\(type): patch is required") }
            if type == "migrate" {
                // A stamp sets fields of meta and adds missing top-level arrays; it never removes or replaces data.
                for step in patch {
                    let parts = try JSONPatch.tokens(step["path"]?.stringValue ?? "")
                    switch step["op"]?.stringValue {
                    case "add" where parts.count == 1 && c[parts[0]] == nil: continue
                    case "add", "replace":
                        guard parts.count == 2, parts[0] == "meta" else { throw Failure("migrate changes only fields of meta") }
                    default: throw Failure("migrate only adds or replaces fields of meta")
                    }
                }
            }
            guard case .object(let result) = try JSONPatch.apply(patch, to: .object(c)) else {
                throw Failure("\(type): the result is not an object")
            }
            return result

        case "add_item":
            guard case .object(let item)? = args["item"], item["id"] != nil else { throw Failure("add_item: item with an id") }
            try appendTo("open_items", .object(item), in: &c)

        case "update_item":
            let id = try required(args, "id", type)
            try updateItem(id: id, in: &c) { item in
                let set = args["set"]?.objectValue ?? JSONObject()
                let unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
                let forbidden: Set<String> = ["id", "status", "dismissed", "created_at", "updated_at"]
                for key in set.keys + unset where forbidden.contains(key) { throw Failure("update_item may not change \(key)") }
                for key in unset where key == "title" || key == "priority" { throw Failure("update_item may not remove \(key)") }
                if set.keys.contains(where: { unset.contains($0) }) { throw Failure("update_item: a field in both set and unset") }
                for key in unset { item.remove(key) }
                for entry in set.entries { item.set(entry.key, entry.value) }
                updateDerived(&item, touched: Set(set.keys).union(unset).subtracting(["derived"]),
                              supplied: set["derived"])
                item.set("updated_at", .string(at))
            }

        case "set_status":
            let id = try required(args, "id", type)
            guard case .string(let status)? = args["status"], ["open", "waiting", "blocked"].contains(status) else {
                throw Failure("set_status: status must be open, waiting or blocked")
            }
            try updateItem(id: id, in: &c) { item in
                var touched: Set<String> = ["status"]
                item.set("status", .string(status))
                let waitingFields = ["waiting_on", "follow_up_at", "expected_by"]
                if status == "open" {
                    for key in waitingFields where args[key] == nil {
                        if item.remove(key) != nil { touched.insert(key) }
                    }
                }
                for key in waitingFields {
                    if let value = args[key] {
                        item.set(key, value)
                        touched.insert(key)
                    }
                }
                updateDerived(&item, touched: touched, supplied: args["derived"])
                item.set("updated_at", .string(at))
            }

        case "complete", "drop":
            let id = try required(args, "id", type)
            let source = args["source"] ?? actorKind
            let closedAt = args["closed_at"] ?? .string(at)
            if type == "complete", let nextDue = args["next_due"] {
                // Advance a recurring item; it stays open (teka-v0 §5.4).
                var occurrenceDue: JSONValue = .null
                try updateItem(id: id, in: &c) { item in
                    guard item["recurrence"] != nil else { throw Failure("complete: next_due on an item without recurrence") }
                    occurrenceDue = args["occurrence_due"] ?? item["due"] ?? .null
                    item.set("due", nextDue)
                    item.set("updated_at", .string(at))
                }
                var entry: [(String, JSONValue)] = [("item", id), ("action", .string("occurrence")), ("at", .string(at)),
                                                    ("due", occurrenceDue), ("next_due", nextDue), ("source", source),
                                                    ("via", via), ("op_id", opID)]
                if let note = args["note"] { entry.append(("note", note)) }
                try appendTo("processing_log", .obj(entry), in: &c)
                return c
            }
            let (index, item) = try findItem(id: id, in: c)
            if type == "complete", item["recurrence"] != nil {
                throw Failure("complete: a recurring item needs next_due; drop ends a series")
            }
            var items = c["open_items"]?.arrayValue ?? []
            items.remove(at: index)
            c.set("open_items", .array(items))
            let alreadyClosed = (c["processing_log"]?.arrayValue ?? []).contains { $0["id"] == id }
            var title: JSONValue = .string("")
            if case .string(let t)? = item["title"], !t.isEmpty { title = .string(t) }
            var final = JSONObject()
            for e in item.entries where !["id", "title", "kind"].contains(e.key) { final.entries.append(e) }
            var entry: [(String, JSONValue)] = alreadyClosed ? [("item", id)] : [("id", id)]
            entry += [("title", title),
                      ("action", .string(alreadyClosed ? "closed-duplicate" : (type == "complete" ? "done" : "dropped"))),
                      ("at", .string(at)), ("closed_at", closedAt), ("source", source), ("via", via), ("op_id", opID)]
            if let kind = item["kind"] { entry.append(("kind", kind)) }
            if let note = args["note"] ?? args["reason"] { entry.append(("note", note)) }
            entry.append(("final", .object(final)))
            try appendTo("processing_log", .obj(entry), in: &c)

        case "reopen":
            let closedID = try required(args, "id", type)
            guard case .object(let item)? = args["item"], let newID = item["id"] else { throw Failure("reopen: item with an id") }
            guard (c["processing_log"]?.arrayValue ?? []).contains(where: { $0["id"] == closedID }) else {
                throw Failure("reopen: \(closedID) is not closed")
            }
            try appendTo("open_items", .object(item), in: &c)
            try appendTo("processing_log", .obj([("item", newID), ("reopened_from", closedID),
                                                 ("action", .string("reopened")), ("at", .string(at)),
                                                 ("source", actorKind), ("via", via), ("op_id", opID)]), in: &c)

        case "dismiss", "undismiss":
            let id = try required(args, "id", type)
            try updateItem(id: id, in: &c) { item in
                if type == "dismiss" { item.set("dismissed", .bool(true)) } else { item.remove("dismissed") }
                item.set("updated_at", .string(at))
            }

        case "add_log_entry":
            guard case .object(var entry)? = args["entry"] else { throw Failure("add_log_entry: entry is required") }
            guard entry["id"] == nil else { throw Failure("add_log_entry: closures go through complete and drop") }
            entry.set("at", .string(at))
            entry.set("via", via)
            entry.set("op_id", opID)
            try appendTo("processing_log", .object(entry), in: &c)

        case "file_document":
            guard case .object(let document)? = args["document"], let docID = document["id"] else {
                throw Failure("file_document: document with an id")
            }
            try appendTo("documents", .object(document), in: &c)
            try appendTo("processing_log", .obj([("document", docID), ("action", .string("filed")),
                                                 ("at", .string(at)), ("source", document["source"] ?? actorKind),
                                                 ("via", via), ("op_id", opID)]), in: &c)

        case "update_document":
            let id = try required(args, "id", type)
            var docs = c["documents"]?.arrayValue ?? []
            guard let i = docs.firstIndex(where: { $0["id"] == id }), case .object(var doc) = docs[i] else {
                throw Failure("update_document: no document \(id)")
            }
            let set = args["set"]?.objectValue ?? JSONObject()
            let unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if set.contains("id") || unset.contains("id") || unset.contains("title") || unset.contains("path") {
                throw Failure("update_document may not change id or remove title or path")
            }
            for key in unset { doc.remove(key) }
            for entry in set.entries { doc.set(entry.key, entry.value) }
            docs[i] = .object(doc)
            c.set("documents", .array(docs))

        case "set_meta":
            var meta = c["meta"]?.objectValue ?? JSONObject()
            let set = args["set"]?.objectValue ?? JSONObject()
            let unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let locked: Set<String> = ["name", "schema_version", "format", "format_version", "disclosure", "former_names"]
            for key in set.keys + unset where locked.contains(key) { throw Failure("set_meta may not change \(key)") }
            for key in unset { meta.remove(key) }
            for entry in set.entries { meta.set(entry.key, entry.value) }
            c.set("meta", .object(meta))

        case "set_disclosure":
            guard case .string(let level)? = args["disclosure"], ["full", "title", "kind", "none"].contains(level) else {
                throw Failure("set_disclosure: full, title, kind or none")
            }
            var meta = c["meta"]?.objectValue ?? JSONObject()
            meta.set("disclosure", .string(level))
            c.set("meta", .object(meta))

        case "rename_teka":
            guard let name = args["name"], let former = args["former"], let until = args["until"] else {
                throw Failure("rename_teka: name, former and until are required")
            }
            var meta = c["meta"]?.objectValue ?? JSONObject()
            meta.set("name", name)
            var formers = meta["former_names"]?.arrayValue ?? []
            formers.append(.obj([("name", former), ("until", until)]))
            meta.set("former_names", .array(formers))
            c.set("meta", .object(meta))

        default:
            throw Failure("unknown op \(type)")
        }
        return c
    }

    // MARK: - Helpers

    static func required(_ args: JSONObject, _ key: String, _ type: String) throws -> JSONValue {
        guard let value = args[key] else { throw Failure("\(type): \(key) is required") }
        return value
    }

    /// Ids match by JSON type and value (teka-v0 §5.6).
    static func findItem(id: JSONValue, in c: JSONObject) throws -> (Int, JSONObject) {
        let items = c["open_items"]?.arrayValue ?? []
        guard let i = items.firstIndex(where: { $0["id"] == id }), case .object(let item) = items[i] else {
            throw Failure("no open item \(canonicalText(id))")
        }
        return (i, item)
    }

    static func updateItem(id: JSONValue, in c: inout JSONObject, _ change: (inout JSONObject) throws -> Void) throws {
        let (i, item) = try findItem(id: id, in: c)
        var updated = item
        try change(&updated)
        var items = c["open_items"]?.arrayValue ?? []
        items[i] = .object(updated)
        c.set("open_items", .array(items))
    }

    static func appendTo(_ key: String, _ value: JSONValue, in c: inout JSONObject) throws {
        var array: [JSONValue]
        switch c[key] {
        case nil: array = []
        case .array(let a)?: array = a
        default: throw Failure("\(key) is not an array")
        }
        array.append(value)
        c.set(key, .array(array))
    }

    /// The `derived` rule of teka-v0 §5.3: a supplied array replaces it; otherwise every field the op set or
    /// removed leaves it; an empty array is removed.
    static func updateDerived(_ item: inout JSONObject, touched: Set<String>, supplied: JSONValue?) {
        if let supplied {
            if case .array(let a) = supplied, a.isEmpty { item.remove("derived") } else { item.set("derived", supplied) }
            return
        }
        guard case .array(let names)? = item["derived"] else { return }
        let kept = names.filter { !touched.contains($0.stringValue ?? "") }
        if kept.count == names.count { return }
        if kept.isEmpty { item.remove("derived") } else { item.set("derived", .array(kept)) }
    }
}

/// Replays an op log (teka-v0 §6.6): state 0 is the latest `import_snapshot`'s catalog; each later op, skipping
/// aborted ones, must reproduce its `after_hash`.
public enum Replay {
    public struct Mismatch: Error, CustomStringConvertible {
        public let index: Int
        public let opID: String
        public let reason: String
        public var description: String { "op \(index) (\(opID)): \(reason)" }
    }

    public static func run(_ lines: [JSONObject]) throws -> JSONObject {
        guard let start = lines.lastIndex(where: { $0["op"]?.stringValue == "import_snapshot" }),
              case .object(var state)? = lines[start]["args"]?["catalog"] else {
            throw Mismatch(index: 0, opID: "", reason: "no import_snapshot")
        }
        let aborted = Set(lines.filter { $0["op"]?.stringValue == "abort" }
            .flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        var expected = try Canonical.hash(.object(state))
        for (i, op) in lines.enumerated().dropFirst(start) {
            let id = op["id"]?.stringValue ?? ""
            if aborted.contains(id) { continue }
            guard op["before_hash"]?.stringValue == expected else {
                throw Mismatch(index: i, opID: id, reason: "before_hash breaks the chain")
            }
            state = try OpApplier.apply(op, to: state)
            let hash = try Canonical.hash(.object(state))
            guard op["after_hash"]?.stringValue == hash else {
                throw Mismatch(index: i, opID: id, reason: "after_hash differs: computed \(hash)")
            }
            expected = hash
        }
        return state
    }
}

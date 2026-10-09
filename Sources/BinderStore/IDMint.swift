import BinderFormat
import Foundation
import SpravaKit

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
    /// `external_edit` or `migrate` patch wrote (the `id`, `item` and `document` of every object in its values, and
    /// a value a step writes straight to such a field, as an outside rename of an item writes `/open_items/0/id`).
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
                for step in args?["patch"]?.arrayValue ?? [] {
                    guard let v = step["value"] else { continue }
                    let field = step["path"]?.stringValue?.split(separator: "/").last.map(String.init) ?? ""
                    if ["id", "item", "document"].contains(field), v.stringValue != nil || v.numberValue != nil { out.append(v) }
                    scan(v)
                }
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

/// Placeholder ids (`"$new:1"`) in a proposal are minted when the proposal is applied, never when it is proposed,
/// so two pending proposals never claim one number (binder-v0 §5.6). Later ops in the batch may name a placeholder.
public enum Placeholders {
    public static func resolve(_ ops: [JSONObject], catalog: JSONObject, opLog: [JSONObject], year: Int, at: String) throws -> [JSONObject] {
        var minted: [String: JSONValue] = [:]
        var working = catalog
        var out: [JSONObject] = []
        for var op in ops {
            guard case .object(var args)? = op["args"] else { out.append(op); continue }
            // An op that names a record by `id` may name one an earlier op of the batch created.
            if case .string(let ref)? = args["id"], let real = minted[ref] { args.set("id", real) }
            // So may a log entry, by its `item` or `document`.
            if op["op"]?.stringValue == "add_log_entry", case .object(var entry)? = args["entry"] {
                for key in ["item", "document"] {
                    if case .string(let ref)? = entry[key], let real = minted[ref] { entry.set(key, real) }
                }
                args.set("entry", .object(entry))
            }
            // `add_item` and `reopen` both create an item, which gets a new id and the op's time (binder-v0 §6.3).
            if ["add_item", "reopen"].contains(op["op"]?.stringValue), case .object(var item)? = args["item"] {
                if case .string(let id)? = item["id"], id.hasPrefix("$new:") {
                    let real = JSONValue.string(try IDMint.next(catalog: working, opLog: opLog, year: year))
                    minted[id] = real
                    item.set("id", real)
                }
                // This op's time, even on an item copied from an earlier op, as an "apply again" card holds one.
                item.set("created_at", .string(at))
                item.set("updated_at", .string(at))
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

import BinderFormat
import Foundation
import SpravaKit

/// A rule violation, identified by the array, the record's key and the rule, never by position, so removing one
/// item never makes another item's old violation look new (binder-v0 §6.3).
public struct Violation: Hashable, Sendable, CustomStringConvertible {
    public let array: String
    public let recordKey: String
    public let rule: String
    public var description: String { "\(array)[\(recordKey)]: \(rule)" }
}

/// The transaction guard (decisions.md A2; binder-v0 §6.3): applies ops to a copy of the catalog and accepts them
/// only when they add no new violation and every record they create or change is valid afterwards.
public enum TransactionGuard {
    public struct Rejection: Error, CustomStringConvertible, Equatable {
        public let reasons: [String]
        public var description: String { reasons.joined(separator: "; ") }
    }

    /// Every violation in a catalog, at its level's rules.
    public static func violations(_ catalog: JSONObject) -> Set<Violation> {
        let level = CatalogLevel.classify(catalog)
        let stamped = level == .tekaV0 || level == .tekaV0BadSchemaVersion
        var result = Set<Violation>()

        func recordKey(_ value: JSONValue, in array: [JSONValue]) -> String {
            if let id = value["id"], array.filter({ $0["id"] == id }).count == 1 { return canonicalText(id) }
            return (try? Canonical.hash(value)) ?? "?"
        }

        for key in ["documents", "open_items", "processing_log"] {
            guard let value = catalog[key] else {
                if stamped { result.insert(Violation(array: key, recordKey: "-", rule: "missing")) }
                continue
            }
            guard case .array(let entries) = value else {
                result.insert(Violation(array: key, recordKey: "-", rule: "not-an-array"))
                continue
            }
            var counts: [JSONValue: Int] = [:]
            for entry in entries {
                guard entry.objectValue != nil else {
                    result.insert(Violation(array: key, recordKey: (try? Canonical.hash(entry)) ?? "?", rule: "not-an-object"))
                    continue
                }
                if let id = entry["id"] { counts[id, default: 0] += 1 }
            }
            for (id, n) in counts where n > 1 {
                result.insert(Violation(array: key, recordKey: canonicalText(id), rule: "duplicate-id"))
            }
        }

        // Two open items whose slice ids would be the same break publishing (binder-v0 §5.6).
        if case .string(let teka)? = catalog["meta"]?["name"], !teka.isEmpty {
            var projected: [String: Int] = [:]
            for item in catalog["open_items"]?.arrayValue ?? [] {
                guard let id = item["id"] else { continue }
                projected[HubLane.plainSliceID(id, teka: teka), default: 0] += 1
            }
            for (sid, n) in projected where n > 1 {
                result.insert(Violation(array: "open_items", recordKey: sid, rule: "slice-id-collision"))
            }
        }

        if level.strictItems {
            let items = catalog["open_items"]?.arrayValue ?? []
            let findings = ItemRules.check(items: items, log: catalog["processing_log"]?.arrayValue ?? [], v0: stamped)
            for finding in findings where finding.code != .duplicateID {
                let index = Int(finding.location.dropFirst("open_items[".count).dropLast()) ?? 0
                let key = items.indices.contains(index) ? recordKey(items[index], in: items) : "?"
                result.insert(Violation(array: "open_items", recordKey: key,
                                        rule: finding.code.rawValue + (finding.field.map { ":" + $0 } ?? "")))
            }
        }
        if stamped {
            let documents = catalog["documents"]?.arrayValue ?? []
            for doc in documents {
                guard case .object(let d) = doc else { continue }
                for field in ["id", "title", "path"] where !ItemRules.isTruthy(d[field]) {
                    result.insert(Violation(array: "documents", recordKey: recordKey(doc, in: documents),
                                            rule: "missing-field:\(field)"))
                }
            }
        }
        return result
    }

    /// Records an op creates or changes, as (array, key) pairs, to check that each is valid afterwards.
    static func touchedRecords(_ op: JSONObject) -> [(String, JSONValue)] {
        let args = op["args"]?.objectValue ?? JSONObject()
        switch op["op"]?.stringValue {
        case "add_item", "reopen": return args["item"]?["id"].map { [("open_items", $0)] } ?? []
        case "update_item", "set_status", "dismiss", "undismiss", "complete":
            return args["id"].map { [("open_items", $0)] } ?? []
        case "file_document": return args["document"]?["id"].map { [("documents", $0)] } ?? []
        case "update_document": return args["id"].map { [("documents", $0)] } ?? []
        default: return []
        }
    }

    /// Op-level rules that do not depend on the catalog's content (binder-v0 §6.2, §6.3, §6.5).
    static func envelopeProblems(_ op: JSONObject) -> [String] {
        var problems: [String] = []
        let type = op["op"]?.stringValue ?? "?"
        let actor = op["actor"]?.objectValue
        let kind = actor?["kind"]?.stringValue
        if !["user", "clerk", "brain", "import", "external"].contains(kind ?? "") { problems.append("\(type): bad actor kind") }
        if kind == "clerk" || kind == "brain" {
            if (op["approved_by"]?.stringValue ?? "").isEmpty { problems.append("\(type): a \(kind!)'s op needs approved_by") }
            if op["proposal"] == nil { problems.append("\(type): a \(kind!)'s op needs its proposal") }
        }
        if ["set_disclosure", "rename_teka", "expunge"].contains(type), kind != "user" {
            problems.append("\(type) is applied only by the user")
        }
        if ["complete", "drop", "reopen", "file_document", "add_log_entry"].contains(type),
           (actor?["client"]?.stringValue ?? "").isEmpty {
            problems.append("\(type): actor.client is required, it becomes the log entry's via")
        }
        let args = op["args"]?.objectValue
        // A filed document follows the path rules and carries its digest (binder-v0 §4.3, §6.3).
        if type == "file_document" {
            let doc = args?["document"]?.objectValue
            if let id = doc?["id"]?.stringValue, id.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._-]*/) == nil {
                problems.append("file_document: a minted id is ASCII")
            }
            if (doc?["title"]?.stringValue ?? "").isEmpty { problems.append("file_document: title is required") }
            if !DocumentPaths.isSafe(doc?["path"]?.stringValue ?? "") { problems.append("file_document: path breaks the path rules") }
            if (doc?["sha256"]?.stringValue ?? "").wholeMatch(of: /[0-9a-f]{64}/) == nil { problems.append("file_document: sha256 is required") }
            if let from = args?["from"], !DocumentPaths.isIntake(from.stringValue ?? "") {
                problems.append("file_document: from must be a file under intake/")
            }
        }
        // Recurrence and dismissal are left to lifeproj and the hub in this version (mvp.md feature 2): neither is set
        // nor removed, so a series never quietly becomes a one-off.
        let written = [args?["item"]?.objectValue, args?["set"]?.objectValue].compactMap { $0 }
        let removed = args?["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if ["add_item", "update_item", "reopen"].contains(type), kind != "import",
           written.contains(where: { $0["recurrence"] != nil || $0["dismissed"] != nil })
            || (type == "update_item" && kind != "import" && (removed.contains("recurrence") || removed.contains("dismissed"))) {
            problems.append("\(type): recurrence and dismissed are not set or removed in this version")
        }
        // A free log entry says what happened; `at`, `via` and `op_id` are stamped (binder-v0 §6.8, §10.4).
        if type == "add_log_entry" {
            let entry = args?["entry"]?.objectValue
            if (entry?["action"]?.stringValue ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
                problems.append("add_log_entry: the entry needs an action, a non-empty string")
            }
        }
        // What a closure writes into its log entry has the log entry's types (binder-v0 §10.4).
        if type == "complete" || type == "drop" {
            if let closedAt = args?["closed_at"], closedAt != .null, closedAt.stringValue == nil {
                problems.append("\(type): closed_at is a time or null")
            }
            if let source = args?["source"], (source.stringValue ?? "").isEmpty { problems.append("\(type): source is a non-empty string") }
            for key in ["note", "reason"] where args?[key] != nil && args?[key]?.stringValue == nil {
                problems.append("\(type): \(key) is text")
            }
        }
        if type == "external_edit", kind != "external" { problems.append("external_edit: actor kind must be external") }
        if ["import_snapshot", "migrate", "abort"].contains(type), kind != "import" { problems.append("\(type): actor kind must be import") }
        return problems
    }

    /// Applies `ops` in order to `catalog`. Returns the new catalog and each op's after-hash, or throws a
    /// rejection; a rejected batch changes nothing.
    public static func check(_ ops: [JSONObject], on catalog: JSONObject,
                             knownIDs: Set<JSONValue> = []) throws -> (catalog: JSONObject, hashes: [String]) {
        var state = catalog
        var hashes: [String] = []
        var reasons: [String] = []
        var seenIDs = knownIDs
        for value in (catalog["open_items"]?.arrayValue ?? []) + (catalog["processing_log"]?.arrayValue ?? []) {
            if let id = value["id"] { seenIDs.insert(id) }
            if let id = value["item"] { seenIDs.insert(id) }
        }
        for op in ops {
            reasons += envelopeProblems(op)
            let type = op["op"]?.stringValue
            if type == "add_item" || type == "reopen", let id = op["args"]?["item"]?["id"] {
                if seenIDs.contains(id) { reasons.append("\(type!): id \(canonicalText(id)) was used before and is never reused") }
                seenIDs.insert(id)
            }
            let before = violations(state)
            let next: JSONObject
            do {
                next = try OpApplier.apply(op, to: state)
            } catch {
                reasons.append("\(error)")
                break
            }
            let after = violations(next)
            for v in after.subtracting(before) { reasons.append("new violation \(v)") }
            // Records the op creates or changes must be valid afterwards, even if they were invalid before.
            for (array, id) in touchedRecords(op) {
                for v in after where v.array == array && v.recordKey == canonicalText(id) && before.contains(v) {
                    reasons.append("the op leaves \(v) in place")
                }
            }
            // Records a v0 implementation creates follow the v0 record rules, whatever the catalog's level.
            if type == "add_item" || type == "reopen", let item = op["args"]?["item"] {
                for finding in ItemRules.check(items: [item], log: [], v0: true) {
                    reasons.append("new item: \(finding.code.rawValue)" + (finding.field.map { " (\($0))" } ?? ""))
                }
            }
            state = next
            do { hashes.append(try Canonical.hash(.object(state))) } catch { reasons.append("\(error)") }
        }
        if !reasons.isEmpty { throw Rejection(reasons: reasons) }
        return (state, hashes)
    }
}

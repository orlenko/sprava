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

    /// Whether `value`, as Sprava would write it, is something a reader refuses or reads one way only (binder-v0
    /// §4.8): an integer outside the I-JSON range, a number too large for a double, a member name twice in one
    /// object, or a lone surrogate, at any depth. Checked on the written text, the bytes the reader will see.
    public static func isUnsafeJSON(_ value: JSONValue) -> Bool {
        guard let parsed = try? JSONParser.parse(Data(JSONWriter.compact(value).utf8)) else { return true }
        return !parsed.safety.isSafe
    }

    /// Every violation in a catalog, at its level's rules.
    public static func violations(_ catalog: JSONObject) -> Set<Violation> {
        let level = CatalogLevel.classify(catalog)
        let stamped = level == .tekaV0 || level == .tekaV0BadSchemaVersion
        var result = Set<Violation>()

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
            result.formUnion(itemViolations(findings.map { ($0.code, $0.location, $0.field) }, items: items))
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

    /// A record's key: its id when that id is unique in the array, else the hash of the whole record.
    static func recordKey(_ value: JSONValue, in array: [JSONValue]) -> String {
        if let id = value["id"], array.filter({ $0["id"] == id }).count == 1 { return canonicalText(id) }
        return (try? Canonical.hash(value)) ?? "?"
    }

    /// Item-rule findings as violations. Only a finding located `open_items[<digits>]` is attached to that item;
    /// one about any other place (such as `documents[0]`) is kept under its own location, never taken for an item's.
    static func itemViolations(_ findings: [(code: RuleFinding.Code, location: String, field: String?)],
                               items: [JSONValue]) -> Set<Violation> {
        var result = Set<Violation>()
        for finding in findings where finding.code != .duplicateID {
            let rule = finding.code.rawValue + (finding.field.map { ":" + $0 } ?? "")
            if let index = itemIndex(finding.location) {
                let key = items.indices.contains(index) ? recordKey(items[index], in: items) : "?"
                result.insert(Violation(array: "open_items", recordKey: key, rule: rule))
            } else {
                let array = String(finding.location.prefix { $0 != "[" })
                result.insert(Violation(array: array, recordKey: finding.location, rule: rule))
            }
        }
        return result
    }

    /// The index in `open_items` a finding's location names, written strictly `open_items[<digits>]`; nil for any
    /// other place or spelling.
    static func itemIndex(_ location: String) -> Int? {
        guard location.hasPrefix("open_items["), location.hasSuffix("]") else { return nil }
        let digits = location.dropFirst("open_items[".count).dropLast()
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
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
        // A placeholder is minted when its card is approved and never written as an id (binder-v0 §5.6).
        if ["add_item", "reopen"].contains(type), args?["item"]?["id"]?.stringValue?.hasPrefix("$new:") == true {
            problems.append("\(type): the placeholder id was never minted")
        }
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
            // A key or credential file is never read or moved, and no file is renamed to or from a key file's name,
            // which would take it out of, or put it under, the readers' exclusion (binder-v0 §3.3).
            if [doc?["path"], args?["from"]].contains(where: { $0?.stringValue.map(DocumentPaths.isKeyFile) == true }) {
                problems.append("file_document: a key or credential file is never filed")
            }
        }
        // A new path follows the path rules, under chapters/ and entities/ too, since nothing moves (binder-v0 §4.3).
        if type == "update_document", let path = args?["set"]?["path"],
           !DocumentPaths.isSafe(path.stringValue ?? "", forFiling: false) {
            problems.append("update_document: path breaks the path rules")
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
        // A rename writes a binder name the spool can use, keeps the former one, and drains it until a real date
        // (binder-v0 §3.1, §4.2, §6.3).
        if type == "rename_teka" {
            if !(args?["name"]?.stringValue.map(HubLane.isSafeSegment) ?? false) { problems.append("rename_teka: name is a binder name") }
            if (args?["former"]?.stringValue ?? "").isEmpty { problems.append("rename_teka: former is the binder's old name") }
            if args?["until"]?.stringValue.flatMap(CalendarDate.strict) == nil { problems.append("rename_teka: until is a YYYY-MM-DD date") }
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
        // A record an op changes but leaves invalid is let through only when a later op of the same batch removes that
        // violation, as a repair card that then closes the item does: the card is judged as one transition.
        var leftInPlace: [Violation] = []
        for value in (catalog["open_items"]?.arrayValue ?? []) + (catalog["processing_log"]?.arrayValue ?? []) {
            if let id = value["id"] { seenIDs.insert(id) }
            if let id = value["item"] { seenIDs.insert(id) }
        }
        for op in ops {
            reasons += envelopeProblems(op)
            let type = op["op"]?.stringValue
            if type == "rename_teka", case .string(let current)? = state["meta"]?["name"], op["args"]?["former"] != .string(current) {
                reasons.append("rename_teka: former is the binder's current name")
            }
            if type == "add_item" || type == "reopen", let id = op["args"]?["item"]?["id"] {
                if seenIDs.contains(id) { reasons.append("\(type!): id \(canonicalText(id)) was used before and is never reused") }
                seenIDs.insert(id)
            }
            // A closure of an item whose title is not text names where its `final` keeps that title (binder-v0 §9.5).
            if type == "complete" || type == "drop", op["args"]?["next_due"] == nil, let id = op["args"]?["id"],
               let title = state["open_items"]?.arrayValue?.first(where: { $0["id"] == id })?["title"], title != .null,
               title.stringValue == nil, op["args"]?["keep_title_as"]?.stringValue?.hasPrefix("legacy_title") != true {
                reasons.append("\(type!): the item's title is not text, and the closure does not keep it (keep_title_as)")
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
                    leftInPlace.append(v)
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
        // The catalog and the log stay readable: nothing is written that the reader would then refuse.
        let left = violations(state)
        for v in Set(leftInPlace) where left.contains(v) { reasons.append("the change leaves \(v) in place") }
        if reasons.isEmpty, ops.contains(where: { isUnsafeJSON(.object($0)) }) || isUnsafeJSON(.object(state)) {
            reasons.append("the change holds a number out of range or a repeated member name, which no reader can take back")
        }
        if !reasons.isEmpty { throw Rejection(reasons: reasons) }
        return (state, hashes)
    }
}

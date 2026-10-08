import Foundation
import SpravaKit

/// One rule failure. It names a record by index and id only, never by its text, so findings can be logged
/// and shown in counts without leaking content (binder-v0 §9.2).
public struct RuleFinding: Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable {
        case notAnObject = "not-an-object"
        case missingField = "missing-field"
        case duplicateID = "duplicate-id"
        case reusedID = "id-reused-from-processing-log"
        case badStatus = "bad-status"
        case badPriority = "bad-priority"
        case dueAndNoDeadline = "due-and-no-deadline"
        case dateless
        case badDue = "bad-due"
        case waitingWithoutParty = "waiting-without-waiting-on"
        case tagsNotList = "tags-not-a-list"
        case redactNotBool = "redact-not-boolean"
        case badSliceTitle = "bad-slice-title"
        // v0 additions (binder-v0 §4.4)
        case doneInOpenItems = "done-in-open-items"
        case waitingWithoutFollowUp = "waiting-without-follow-up-at"
        case redactedWithoutKind = "redacted-without-kind"
        case badKind = "bad-kind"
        case badDate = "bad-date"
        case nullValue = "null-value"
        case badID = "bad-id"
        case badTitle = "bad-title"
    }

    public let code: Code
    /// Where: an array and index such as `open_items[3]`, plus a field name when relevant.
    public let location: String
    public let field: String?

    public var description: String {
        field.map { "\(location).\($0): \(code.rawValue)" } ?? "\(location): \(code.rawValue)"
    }
}

public enum ItemRules {
    public static let kinds: Set<String> = [
        "legal-deadline", "payment", "reply-owed", "filing", "appointment", "document-request", "decision", "other",
    ]

    /// lifeproj's strict v2 rules (`osavul.validate_open_items` and `catalog_check.check_open_items`), plus the
    /// v0 additions when `v0` is true.
    public static func check(items: [JSONValue], log: [JSONValue], v0: Bool) -> [RuleFinding] {
        var findings: [RuleFinding] = []
        var seen = Set<ItemID>()
        let closed = Set(log.compactMap { ItemID($0["id"]) })

        for (i, value) in items.enumerated() {
            let at = "open_items[\(i)]"
            guard case .object(let o) = value else {
                findings.append(.init(code: .notAnObject, location: at, field: nil))
                continue
            }
            func add(_ code: RuleFinding.Code, _ field: String? = nil) {
                findings.append(.init(code: code, location: at, field: field))
            }
            for field in ["id", "title", "status", "priority"] where !isTruthy(o[field]) {
                add(.missingField, field)
            }
            if let raw = o["id"], isTruthy(raw) {
                if let id = ItemID(raw) {
                    if !seen.insert(id).inserted { add(.duplicateID, "id") }
                    if closed.contains(id) { add(.reusedID, "id") }
                } else if v0 {
                    add(.badID, "id")
                }
            }
            if let s = o["status"], isTruthy(s), ItemStatus(rawValue: s.stringValue ?? "") == nil { add(.badStatus, "status") }
            if let p = o["priority"], isTruthy(p), Priority(rawValue: p.stringValue ?? "") == nil { add(.badPriority, "priority") }

            let dueValue = o["due"]
            let hasDue = !(dueValue == nil || dueValue == .null || dueValue == .string(""))
            let noDeadline = o["no_deadline"] == .bool(true)
            if hasDue && noDeadline { add(.dueAndNoDeadline) }
            if !hasDue && !noDeadline { add(.dateless) }
            if hasDue {
                let text = dueValue?.stringValue
                let ok = v0 ? text.flatMap(CalendarDate.strict) != nil : text.flatMap(CalendarDate.lenient) != nil
                if !ok { add(.badDue, "due") }
            }
            let status = o["status"]?.stringValue
            let waiting = status == "waiting" || status == "blocked"
            if waiting && !isTruthy(o["waiting_on"]) { add(.waitingWithoutParty, "waiting_on") }
            if let tags = o["tags"], tags.arrayValue == nil { add(.tagsNotList, "tags") }
            if let redact = o["redact"], redact.boolValue == nil { add(.redactNotBool, "redact") }
            if let st = o["slice_title"], (st.stringValue ?? "").isEmpty { add(.badSliceTitle, "slice_title") }

            guard v0 else { continue }
            // A title is a non-empty string (item.schema.json); a truthy number, list or object is not one.
            if isTruthy(o["title"]), (o["title"]?.stringValue ?? "").isEmpty { add(.badTitle, "title") }
            if status == "done" { add(.doneInOpenItems, "status") }
            if waiting && o["follow_up_at"] == nil { add(.waitingWithoutFollowUp, "follow_up_at") }
            if o["redact"] == .bool(true) && o["kind"] == nil { add(.redactedWithoutKind, "kind") }
            if let kind = o["kind"], !kinds.contains(kind.stringValue ?? "") { add(.badKind, "kind") }
            for field in ["follow_up_at", "expected_by"] {
                if let d = o[field], d.stringValue.flatMap(CalendarDate.strict) == nil { add(.badDate, field) }
            }
            for entry in o.entries where entry.value == .null { add(.nullValue, entry.key) }
        }
        return findings
    }

    /// Python truthiness of a JSON value, as lifeproj's `not it.get(field)` tests it.
    package static func isTruthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .bool(let b)?: b
        case .number(let n)?: (n.doubleValue ?? 1) != 0
        case .string(let s)?: !s.isEmpty
        case .array(let a)?: !a.isEmpty
        case .object(let o)?: !o.entries.isEmpty
        }
    }
}

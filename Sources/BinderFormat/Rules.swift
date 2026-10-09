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
        case badWaitingOn = "bad-waiting-on"
        case badRecurrence = "bad-recurrence"
        case recurrenceWithoutDue = "recurrence-without-due"
        case badPath = "bad-path"
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
            } else if v0 && dueValue == .string("") {
                add(.badDue, "due")      // an empty `due` counts as absent only in a lifeproj catalog
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
            // `waiting_on` is a non-empty string whatever the status (item.schema.json); a falsy one on a waiting
            // item is already `waiting-without-waiting-on`, and a null one is `null-value`.
            if let party = o["waiting_on"], party != .null, (party.stringValue ?? "").isEmpty, !(waiting && !isTruthy(party)) {
                add(.badWaitingOn, "waiting_on")
            }
            // `recurrence` (binder-v0 §5.4): monthly with a day, or yearly with a month and a day, and a `due` that
            // holds the next occurrence.
            if let recurrence = o["recurrence"], recurrence != .null {
                if !isRecurrence(recurrence) { add(.badRecurrence, "recurrence") }
                if !hasDue { add(.recurrenceWithoutDue, "due") }
            }
            for entry in o.entries where entry.value == .null { add(.nullValue, entry.key) }
        }
        return findings
    }

    /// The v0 document record (binder-v0 §4.3): an id as items have them, a one-line title, a path and, when
    /// present, a `YYYY-MM-DD` date. The path rules apply to paths v0 writes, so a found path is only typed here.
    public static func check(documents: [JSONValue]) -> [RuleFinding] {
        var findings: [RuleFinding] = []
        for (i, value) in documents.enumerated() {
            let at = "documents[\(i)]"
            func add(_ code: RuleFinding.Code, _ field: String? = nil) {
                findings.append(.init(code: code, location: at, field: field))
            }
            guard case .object(let o) = value else { add(.notAnObject); continue }
            for field in ["id", "title", "path"] where !isTruthy(o[field]) { add(.missingField, field) }
            if isTruthy(o["id"]), ItemID(o["id"]) == nil { add(.badID, "id") }
            if isTruthy(o["title"]), (o["title"]?.stringValue ?? "\n").contains(where: \.isNewline) { add(.badTitle, "title") }
            if isTruthy(o["path"]), o["path"]?.stringValue == nil { add(.badPath, "path") }
            if let d = o["date"], d.stringValue.flatMap(CalendarDate.strict) == nil { add(.badDate, "date") }
        }
        return findings
    }

    /// The shape of `recurrence` in item.schema.json: `freq` monthly or yearly, an integer `day` in 1...31, and an
    /// integer `month` in 1...12, required when yearly and checked when present. Other keys are allowed.
    static func isRecurrence(_ value: JSONValue) -> Bool {
        guard case .object(let r) = value else { return false }
        func integer(_ key: String, in range: ClosedRange<Int64>) -> Bool? {
            guard let v = r[key] else { return nil }
            guard let n = v.numberValue, let i = n.safeInteger ?? n.doubleValue.flatMap(exactInteger) else { return false }
            return range.contains(i)
        }
        let freq = r["freq"]?.stringValue
        guard freq == "monthly" || freq == "yearly", integer("day", in: 1...31) == true else { return false }
        switch integer("month", in: 1...12) {
        case false?: return false
        case nil: return freq == "monthly"
        case true?: return true
        }
    }

    /// A number such as `14.0` is an integer to JSON Schema.
    static func exactInteger(_ d: Double) -> Int64? {
        d.rounded() == d && abs(d) <= 1e15 ? Int64(d) : nil
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

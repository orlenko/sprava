import Foundation

/// An item id: a non-empty string or a non-zero integer. Two ids are equal only when type and value match,
/// so `7` and `"7"` differ (teka-v0 §5.6).
public enum ItemID: Sendable, Hashable, CustomStringConvertible {
    case string(String)
    case integer(Int64)

    public init?(_ value: JSONValue?) {
        switch value {
        case .string(let s)? where !s.isEmpty: self = .string(s)
        case .number(let n)?:
            guard let i = n.safeInteger, i != 0 else { return nil }
            self = .integer(i)
        default: return nil
        }
    }

    /// The text lifeproj's `str()` gives; also the canonical JSON text used for sorting.
    public var description: String {
        switch self {
        case .string(let s): s
        case .integer(let i): String(i)
        }
    }
}

public enum ItemStatus: String, Sendable {
    case open, waiting, blocked, done
}

public enum Priority: String, Sendable, CaseIterable {
    case high, normal, low

    var rank: Int {
        switch self {
        case .high: 0
        case .normal: 1
        case .low: 2
        }
    }
}

/// A read-only view of one entry in `open_items[]`. Nothing here rewrites the entry; unknown fields stay in
/// `raw` (teka-v0 §4.7).
public struct Item: Sendable {
    public let raw: JSONValue
    public let index: Int

    public init(raw: JSONValue, index: Int) {
        self.raw = raw
        self.index = index
    }

    public var object: JSONObject? { raw.objectValue }

    public var id: ItemID? { ItemID(object?["id"]) }
    public var idText: String {
        if let id { return id.description }
        if let value = object?["id"] { return (try? Canonical.serialize(value)) ?? canonicalText(value) }
        return "(no id)"
    }

    public var title: String {
        if case .string(let s)? = object?["title"], !s.isEmpty { return s }
        return "(untitled)"
    }

    /// The title as the sort orders compare it (teka-v0 §5.2): the string itself, the canonical JSON text of a
    /// value that is not a string, and "" when missing.
    public var titleSortKey: String {
        guard let value = object?["title"] else { return "" }
        if case .string(let s) = value { return s }
        return (try? Canonical.serialize(value)) ?? canonicalText(value)
    }

    /// The status as written, when it is one of the four lifeproj values.
    public var declaredStatus: ItemStatus? { object?["status"]?.stringValue.flatMap(ItemStatus.init(rawValue:)) }
    /// A missing or unknown status counts as `open` for display (teka-v0 §5.2).
    public var status: ItemStatus { declaredStatus ?? .open }

    public var priority: Priority? { object?["priority"]?.stringValue.flatMap(Priority.init(rawValue:)) }

    /// `due` read with lifeproj's lenient forms, used for bucketing (teka-v0 §5.2).
    public var due: CalendarDate? { object?["due"]?.stringValue.flatMap(CalendarDate.lenient) }
    public var hasNoDeadline: Bool { object?["no_deadline"] == .bool(true) }
    public var followUpAt: CalendarDate? { object?["follow_up_at"]?.stringValue.flatMap(CalendarDate.strict) }
    public var expectedBy: CalendarDate? { object?["expected_by"]?.stringValue.flatMap(CalendarDate.strict) }
    public var waitingOn: String? { object?["waiting_on"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    public var isDismissed: Bool { object?["dismissed"] == .bool(true) }
    public var isRedacted: Bool { object?["redact"] == .bool(true) }
    public var kind: String? { object?["kind"]?.stringValue }
    public var hasRecurrence: Bool { object?["recurrence"].map { !$0.isNull } ?? false }
    public var tags: [String] { object?["tags"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public var contexts: [String] { object?["contexts"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
    public var link: String? { object?["link"]?.stringValue }
    public var derived: [String] { object?["derived"]?.arrayValue?.compactMap(\.stringValue) ?? [] }
}

/// A read-only view of one `processing_log[]` entry.
public struct LogEntry: Sendable {
    public let raw: JSONValue

    public var object: JSONObject? { raw.objectValue }

    /// The id a closure entry closes; any entry with an `id` closes that item (teka-v0 §4.5).
    public var closedID: ItemID? { ItemID(object?["id"]) }
    /// True for every entry that carries `id`, whatever its value.
    public var isClosure: Bool { object?["id"] != nil }
    public var closedIDText: String {
        guard let value = object?["id"] else { return "" }
        if case .string(let s) = value { return s }
        return (try? Canonical.serialize(value)) ?? canonicalText(value)
    }
    public var title: String { object?["title"]?.stringValue ?? "" }
    public var action: String? { object?["action"]?.stringValue }

    /// The closing date, by the order of teka-v0 §5.2: `closed_at` as an RFC 3339 time, then as a date,
    /// then `at`. A date in the future counts as today.
    public func closingDate(timeZone: TimeZone, today: CalendarDate) -> CalendarDate? {
        var date: CalendarDate?
        if case .string(let s)? = object?["closed_at"] {
            if let instant = Timestamp.parse(s) {
                date = CalendarDate(instant, in: timeZone)
            } else if let d = CalendarDate.strict(s) {
                date = d
            }
        }
        if date == nil, case .string(let s)? = object?["at"], let instant = Timestamp.parse(s) {
            date = CalendarDate(instant, in: timeZone)
        }
        guard let date else { return nil }
        return min(date, today)
    }
}

/// Canonical-enough JSON text for sorting and display of non-string values.
func canonicalText(_ value: JSONValue) -> String {
    switch value {
    case .null: "null"
    case .bool(let b): b ? "true" : "false"
    case .number(let n): n.text
    case .string(let s): s
    case .array(let a): "[" + a.map(canonicalText).joined(separator: ",") + "]"
    case .object(let o): "{" + o.entries.map { "\($0.key):\(canonicalText($0.value))" }.joined(separator: ",") + "}"
    }
}

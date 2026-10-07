import Foundation

/// A JSON number kept as written, so `2` and `2.0` stay distinguishable (teka-v0 §4.8, §9.6).
public struct JSONNumber: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The number exactly as it appeared in the file.
    public let text: String

    public init(text: String) { self.text = text }

    /// True when the text has no fraction and no exponent.
    public var isIntegerLiteral: Bool { !text.contains(where: { $0 == "." || $0 == "e" || $0 == "E" }) }

    /// The integer value when the literal is an integer that fits I-JSON's safe range.
    public var safeInteger: Int64? {
        guard isIntegerLiteral, let value = Int64(text), abs(value) <= JSONNumber.maxSafeInteger else { return nil }
        return value
    }

    public var doubleValue: Double? { Double(text) }

    /// 2^53 - 1, the largest integer I-JSON allows (RFC 7493 §2.2).
    public static let maxSafeInteger: Int64 = 9_007_199_254_740_991

    public var description: String { text }
}

/// An ordered JSON object. Keys keep their file order; a duplicate key is kept too, so nothing is lost on read.
public struct JSONObject: Sendable, Equatable, Hashable {
    public var entries: [(key: String, value: JSONValue)]

    public init(_ entries: [(key: String, value: JSONValue)] = []) { self.entries = entries }

    /// The first value under `key`.
    public subscript(key: String) -> JSONValue? {
        entries.first(where: { $0.key == key })?.value
    }

    public var keys: [String] { entries.map(\.key) }

    public func contains(_ key: String) -> Bool { entries.contains(where: { $0.key == key }) }

    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }

    public func hash(into hasher: inout Hasher) {
        for entry in entries {
            hasher.combine(entry.key)
            hasher.combine(entry.value)
        }
    }
}

public indirect enum JSONValue: Sendable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(JSONNumber)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)

    public var objectValue: JSONObject? { if case .object(let o) = self { o } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }
    public var numberValue: JSONNumber? { if case .number(let n) = self { n } else { nil } }
    public var isNull: Bool { if case .null = self { true } else { false } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// The JSON type name, used in reports.
    public var typeName: String {
        switch self {
        case .null: "null"
        case .bool: "boolean"
        case .number: "number"
        case .string: "string"
        case .array: "array"
        case .object: "object"
        }
    }
}

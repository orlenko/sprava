import Foundation

/// Problems that make a catalog unsafe to read one way only (teka-v0 §4.8). Reading still succeeds; the
/// teka then needs attention and nothing is written until the user approves a repair.
public struct JSONSafetyReport: Sendable, Equatable {
    /// JSON paths of objects that hold the same member name twice, with that name.
    public var duplicateKeys: [String] = []
    /// JSON paths of strings that held a lone surrogate escape such as `\ud800`.
    public var loneSurrogates: [String] = []
    /// JSON paths of integers outside -(2^53)+1 ... 2^53-1, or numbers too large for a double.
    public var unsafeNumbers: [String] = []

    public var isSafe: Bool { duplicateKeys.isEmpty && loneSurrogates.isEmpty && unsafeNumbers.isEmpty }
}

public struct JSONParseError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public let offset: Int
    public var description: String { "\(message) at byte \(offset)" }
}

/// A strict, order-preserving JSON parser (RFC 8259). It keeps key order, duplicate keys and numbers as
/// written, which Foundation's `JSONSerialization` does not (teka-v0 §4.7).
public struct JSONParser {
    private let bytes: [UInt8]
    private var index = 0
    private var report = JSONSafetyReport()
    private var depth = 0
    // Real catalogs nest about ten levels. The limit stays far below what a 512 KB secondary-thread stack (the
    // runtime's jobs) can recurse through, so a hostile file is refused instead of crashing the process.
    private static let maxDepth = 128
    /// The path to the current value, as segments; the string is built only when something is reported.
    private var segments: [String] = []
    private var currentPath: String { "$" + segments.joined() }

    /// Parses UTF-8 data. Throws on invalid UTF-8 or invalid JSON; a byte-order mark is refused.
    public static func parse(_ data: Data) throws -> (value: JSONValue, safety: JSONSafetyReport) {
        guard String(data: data, encoding: .utf8) != nil else {
            throw JSONParseError(message: "not UTF-8", offset: 0)
        }
        var parser = JSONParser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw JSONParseError(message: "trailing content", offset: parser.index)
        }
        return (value, parser.report)
    }

    public static func parse(_ text: String) throws -> (value: JSONValue, safety: JSONSafetyReport) {
        try parse(Data(text.utf8))
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func error(_ message: String) -> JSONParseError { JSONParseError(message: message, offset: index) }

    private mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 }
    }

    private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func parseValue() throws -> JSONValue {
        guard let byte = peek() else { throw error("unexpected end") }
        switch byte {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
        case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
        case UInt8(ascii: "n"): try expectLiteral("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return .number(try parseNumber())
        default: throw error("unexpected character")
        }
    }

    private mutating func expectLiteral(_ literal: String) throws {
        for expected in literal.utf8 {
            guard peek() == expected else { throw error("invalid literal") }
            index += 1
        }
    }

    private mutating func enter() throws {
        depth += 1
        if depth > Self.maxDepth { throw error("nesting too deep") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter(); defer { depth -= 1 }
        index += 1
        var entries: [(key: String, value: JSONValue)] = []
        var seen = Set<[UInt8]>()
        skipWhitespace()
        if peek() == UInt8(ascii: "}") { index += 1; return .object(JSONObject(entries)) }
        while true {
            skipWhitespace()
            guard peek() == UInt8(ascii: "\"") else { throw error("expected a member name") }
            let key = try parseString()
            if !seen.insert(Array(key.utf8)).inserted { report.duplicateKeys.append("\(currentPath).\(key)") }
            skipWhitespace()
            guard peek() == UInt8(ascii: ":") else { throw error("expected ':'") }
            index += 1
            skipWhitespace()
            segments.append("." + key)
            let value = try parseValue()
            segments.removeLast()
            entries.append((key, value))
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(JSONObject(entries))
            default: throw error("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter(); defer { depth -= 1 }
        index += 1
        var values: [JSONValue] = []
        skipWhitespace()
        if peek() == UInt8(ascii: "]") { index += 1; return .array(values) }
        while true {
            skipWhitespace()
            segments.append("[\(values.count)]")
            values.append(try parseValue())
            segments.removeLast()
            skipWhitespace()
            switch peek() {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(values)
            default: throw error("expected ',' or ']'")
            }
        }
    }

    private mutating func parseHex4() throws -> UInt16 {
        guard index + 4 <= bytes.count else { throw error("short \\u escape") }
        var value: UInt16 = 0
        for _ in 0..<4 {
            let b = bytes[index]
            let digit: UInt16
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt16(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt16(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt16(b - UInt8(ascii: "A") + 10)
            default: throw error("bad \\u escape")
            }
            value = value << 4 | digit
            index += 1
        }
        return value
    }

    private mutating func parseString() throws -> String {
        index += 1
        var out: [UInt8] = []
        var hadLoneSurrogate = false
        while true {
            guard let byte = peek() else { throw error("unterminated string") }
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                if hadLoneSurrogate { report.loneSurrogates.append(currentPath) }
                return String(decoding: out, as: UTF8.self)
            case UInt8(ascii: "\\"):
                index += 1
                guard let escape = peek() else { throw error("unterminated escape") }
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    let unit = try parseHex4()
                    var scalar: Unicode.Scalar?
                    if (0xD800...0xDBFF).contains(unit) {
                        if index + 6 <= bytes.count, bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                            let save = index
                            index += 2
                            let low = try parseHex4()
                            if (0xDC00...0xDFFF).contains(low) {
                                let code = 0x10000 + (UInt32(unit - 0xD800) << 10) + UInt32(low - 0xDC00)
                                scalar = Unicode.Scalar(code)
                            } else {
                                index = save
                            }
                        }
                    } else if !(0xDC00...0xDFFF).contains(unit) {
                        scalar = Unicode.Scalar(unit)
                    }
                    if scalar == nil { hadLoneSurrogate = true }
                    out.append(contentsOf: Array(String(scalar ?? "\u{FFFD}").utf8))
                default:
                    throw error("bad escape")
                }
            case 0x00..<0x20:
                throw error("control character in string")
            default:
                out.append(byte)
                index += 1
            }
        }
    }

    private mutating func parseNumber() throws -> JSONNumber {
        let start = index
        if peek() == UInt8(ascii: "-") { index += 1 }
        guard let first = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else { throw error("bad number") }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { index += 1 }
        }
        if peek() == UInt8(ascii: ".") {
            index += 1
            var digits = 0
            while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { index += 1; digits += 1 }
            if digits == 0 { throw error("bad fraction") }
        }
        if let e = peek(), e == UInt8(ascii: "e") || e == UInt8(ascii: "E") {
            index += 1
            if let s = peek(), s == UInt8(ascii: "+") || s == UInt8(ascii: "-") { index += 1 }
            var digits = 0
            while let b = peek(), (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(b) { index += 1; digits += 1 }
            if digits == 0 { throw error("bad exponent") }
        }
        let number = JSONNumber(text: String(decoding: bytes[start..<index], as: UTF8.self))
        if number.isIntegerLiteral {
            if number.safeInteger == nil { report.unsafeNumbers.append(currentPath) }
        } else if let d = number.doubleValue, !d.isFinite {
            report.unsafeNumbers.append(currentPath)
        }
        return number
    }
}

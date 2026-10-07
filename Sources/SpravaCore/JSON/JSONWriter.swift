import CryptoKit
import Foundation

/// Writes JSON the way the format asks (teka-v0 §4.8): UTF-8 unescaped, two-space indent, one key per line,
/// key order as held, numbers exactly as parsed, a trailing newline. `compact` writes one line (the op log).
public enum JSONWriter {
    public static func pretty(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out, indent: 0, pretty: true)
        return out + "\n"
    }

    public static func compact(_ value: JSONValue) -> String {
        var out = ""
        write(value, into: &out, indent: 0, pretty: false)
        return out
    }

    static func write(_ value: JSONValue, into out: inout String, indent: Int, pretty: Bool) {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n.text
        case .string(let s): writeString(s, into: &out, asciiOnly: false)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "["
            for (i, element) in a.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                write(element, into: &out, indent: indent + 1, pretty: pretty)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "]"
        case .object(let o):
            if o.entries.isEmpty { out += "{}"; return }
            out += "{"
            for (i, entry) in o.entries.enumerated() {
                if i > 0 { out += "," }
                if pretty { out += "\n" + String(repeating: "  ", count: indent + 1) }
                writeString(entry.key, into: &out, asciiOnly: false)
                out += pretty ? ": " : ":"
                write(entry.value, into: &out, indent: indent + 1, pretty: pretty)
            }
            if pretty { out += "\n" + String(repeating: "  ", count: indent) }
            out += "}"
        }
    }

    /// JSON string escaping as RFC 8785 requires: `"` `\` and controls below U+0020 escaped (short forms where
    /// they exist, else `\u00xx` lowercase), everything else as is.
    static func writeString(_ s: String, into out: inout String, asciiOnly: Bool) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\u{08}": out += "\\b"
            case "\u{09}": out += "\\t"
            case "\u{0A}": out += "\\n"
            case "\u{0C}": out += "\\f"
            case "\u{0D}": out += "\\r"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

/// RFC 8785 (JSON Canonicalization Scheme) and the content hash `sha256:<hex>` (teka-v0 §4.8).
public enum Canonical {
    public enum Failure: Error { case nonFiniteNumber(String) }

    public static func serialize(_ value: JSONValue) throws -> String {
        var out = ""
        try write(value, into: &out)
        return out
    }

    public static func hash(_ value: JSONValue) throws -> String {
        let digest = SHA256.hash(data: Data(try serialize(value).utf8))
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    static func write(_ value: JSONValue, into out: inout String) throws {
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += try number(n)
        case .string(let s): JSONWriter.writeString(s, into: &out, asciiOnly: false)
        case .array(let a):
            out += "["
            for (i, element) in a.enumerated() {
                if i > 0 { out += "," }
                try write(element, into: &out)
            }
            out += "]"
        case .object(let o):
            // Keys sorted by their UTF-16 code units. A duplicate key keeps its last value, as ECMAScript does;
            // a catalog with duplicates is never written (it needs attention first).
            var latest: [String: JSONValue] = [:]
            for entry in o.entries { latest[entry.key] = entry.value }
            let keys = latest.keys.sorted { Array($0.utf16).lexicographicallyPrecedes(Array($1.utf16)) }
            out += "{"
            for (i, key) in keys.enumerated() {
                if i > 0 { out += "," }
                JSONWriter.writeString(key, into: &out, asciiOnly: false)
                out += ":"
                try write(latest[key]!, into: &out)
            }
            out += "}"
        }
    }

    /// ECMAScript `Number.prototype.toString` of the nearest double (RFC 8785 §3.2.2.3).
    public static func number(_ n: JSONNumber) throws -> String {
        guard let d = n.doubleValue, d.isFinite else { throw Failure.nonFiniteNumber(n.text) }
        return ecmaString(d)
    }

    public static func ecmaString(_ value: Double) -> String {
        if value == 0 { return "0" }   // also -0
        if value < 0 { return "-" + ecmaString(-value) }
        // Swift's description is the shortest round-trip form; extract its digits and exponent.
        let (digits, pointPos) = shortestDigits(value)
        let k = digits.count
        let n = pointPos
        if k <= n && n <= 21 {
            return digits + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let i = digits.index(digits.startIndex, offsetBy: n)
            return String(digits[..<i]) + "." + String(digits[i...])
        }
        if -6 < n && n <= 0 {
            return "0." + String(repeating: "0", count: -n) + digits
        }
        let e = n - 1
        let mantissa = k == 1 ? digits : String(digits.first!) + "." + String(digits.dropFirst())
        return mantissa + "e" + (e >= 0 ? "+" : "-") + String(abs(e))
    }

    /// The decimal digits of the shortest round-trip representation, with no leading or trailing zeros, and
    /// `n` such that value = 0.digits × 10^n.
    static func shortestDigits(_ value: Double) -> (String, Int) {
        let text = "\(value)"   // e.g. "1e+16", "123.45", "1.5e-07", "0.001"
        var mantissa = text
        var exponent = 0
        if let e = text.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            mantissa = String(text[..<e])
            exponent = Int(text[text.index(after: e)...])!
        }
        var intPart = mantissa
        var fracPart = ""
        if let dot = mantissa.firstIndex(of: ".") {
            intPart = String(mantissa[..<dot])
            fracPart = String(mantissa[mantissa.index(after: dot)...])
        }
        var digits = intPart + fracPart
        var n = intPart.count + exponent
        while digits.first == "0" {
            digits.removeFirst()
            n -= 1
        }
        while digits.last == "0" { digits.removeLast() }
        if digits.isEmpty { return ("0", 1) }
        return (digits, n)
    }
}

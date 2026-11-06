import Foundation

/// Bare email addresses from a header such as `"Doe, Jane" <Jane@Example.com>, b@example.com`: so the clerk can tell
/// mail the person wrote from mail they received (issue #594). Never more than a header's first 16 KiB is read.
public enum MailAddress {
    /// The longest address kept (RFC 5321's path limit, less its angle brackets).
    public static let maxLength = 254

    /// The addresses in `header`, lower case, in order, each once. Display names, quoted strings and comments are
    /// skipped; a part that holds no well-formed address gives none.
    public static func bare(in header: String) -> [String] {
        // A header longer than is read names no one: cut short, it could end inside an address, and the start of a
        // stranger's address can be the person's whole address.
        guard header.unicodeScalars.dropFirst(16_384).first == nil else { return [] }
        var parts: [String] = [], current = ""
        var quoted = false, escaped = false, angle = false, depth = 0
        for c in header {
            if escaped { escaped = false; continue }
            if quoted {
                if c == "\\" { escaped = true } else if c == "\"" { quoted = false }
                continue
            }
            if depth > 0 {
                if c == "\\" { escaped = true } else if c == "(" { depth += 1 } else if c == ")" { depth -= 1 }
                continue
            }
            switch c {
            case "\"": quoted = true; current.append(" ")
            case "(": depth = 1; current.append(" ")
            case "<": angle = true; current.append(c)
            case ">": angle = false; current.append(c)
            case ",", ";":
                if angle { current.append(c) } else { parts.append(current); current = "" }
            default: current.append(c)
            }
        }
        parts.append(current)
        var seen = Set<String>()
        return parts.compactMap { part -> String? in
            let candidate: Substring
            if let open = part.lastIndex(of: "<") {
                let rest = part[part.index(after: open)...]
                // An address whose angle bracket never closes is not one.
                guard let close = rest.firstIndex(of: ">") else { return nil }
                candidate = rest[..<close]
            } else {
                // Without angle brackets the address is the one word holding "@" ("Group: a@x" keeps "a@x").
                let words = part.split(whereSeparator: { $0.isWhitespace })
                guard let word = words.first(where: { $0.contains("@") }) else { return nil }
                candidate = word
            }
            guard let address = valid(candidate.trimmingCharacters(in: .whitespacesAndNewlines)), seen.insert(address).inserted else { return nil }
            return address
        }
    }

    /// The addresses in a header as the message wrote it (`IntakeReading.fromHeader`): each RFC 2047 encoded word is
    /// display text whatever it holds, a comma or an "@" included (RFC 2047 section 5), so it is read as a control
    /// character. Beside a display name that changes nothing, and inside or against an address it makes that address
    /// not one, never a different one: "<=?utf-8?q?x?=me@example.invalid>" names no one.
    public static func bare(inRaw header: String) -> [String] {
        bare(in: header.replacingOccurrences(of: #"=\?[^?\s]+\?[BbQq]\?[^?\s]*\?="#, with: "\u{1}", options: .regularExpression))
    }

    /// `text` as one address, lower case, when it is exactly one well-formed address and nothing else: no display
    /// name, no second word, so "a@x b@x" is refused rather than kept as its first address.
    public static func single(_ text: String) -> String? {
        valid(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static let forbidden = CharacterSet(charactersIn: "<>()[],;:\"\\ ").union(.whitespacesAndNewlines).union(.controlCharacters)

    /// Checked lower case, as it is kept: some capitals grow when lowered ("İ" is two bytes, "i̇" three), and an
    /// address that passed only before lowering would fail every later check of what was stored.
    private static func valid(_ raw: String) -> String? {
        let s = raw.lowercased()
        guard !s.isEmpty, s.utf8.count <= maxLength, s.unicodeScalars.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        let halves = s.split(separator: "@", omittingEmptySubsequences: false)
        guard halves.count == 2, !halves[0].isEmpty, halves[0].utf8.count <= 64, !halves[1].isEmpty,
              !halves[1].hasPrefix("."), !halves[1].hasSuffix("."), !halves[1].contains("..") else { return nil }
        return s
    }
}

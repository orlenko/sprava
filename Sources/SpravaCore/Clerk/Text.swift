import Foundation

/// A stretch of a capture's text with half-open offsets in Unicode scalars (capture-event-v0 §3, spans).
public struct TextSpan: Equatable, Sendable {
    public var text: String
    public var start: Int
    public var end: Int
}

/// Sentences, windows and quote anchoring for the clerk (capture-event-v0 §6.4, "Windows" and check 1).
public enum CaptureText {
    static let enders: Set<Unicode.Scalar> = [".", "!", "?", "…", "\n", "\r", "\u{2029}", "\u{2028}"]
    /// Words whose period never ends a sentence ("Call Mr. Smith by Friday.").
    static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "mt", "jr", "sr", "prof", "mme", "mlle", "me", "m",
                                             "no", "vs", "etc", "e.g", "i.e", "approx", "dept", "ave", "blvd", "rd", "ste", "inc", "ltd", "co"]

    /// Sentences: split after `.`, `!`, `?` or `…` followed by white space, and at line breaks. Trimmed; empty
    /// ones dropped. A period inside a number or an initial ("A. Example") does not end a sentence when the next
    /// word starts in lower case or the period follows a single capital letter.
    public static func sentences(_ text: String) -> [TextSpan] {
        let scalars = Array(text.unicodeScalars)
        var out: [TextSpan] = []
        var start = 0
        func flush(_ end: Int) {
            var lo = start, hi = end
            while lo < hi, scalars[lo].properties.isWhitespace { lo += 1 }
            while hi > lo, scalars[hi - 1].properties.isWhitespace { hi -= 1 }
            if lo < hi {
                var v = String.UnicodeScalarView()
                v.append(contentsOf: scalars[lo..<hi])
                out.append(TextSpan(text: String(v), start: lo, end: hi))
            }
        }
        var i = 0
        while i < scalars.count {
            let s = scalars[i]
            if s == "\n" || s == "\r" || s == "\u{2029}" || s == "\u{2028}" {
                flush(i)
                start = i + 1
            } else if [".", "!", "?", "…"].contains(s), i + 1 >= scalars.count || scalars[i + 1].properties.isWhitespace {
                let initial = s == "." && i >= 1 && scalars[i - 1].properties.isUppercase && (i < 2 || !scalars[i - 2].properties.isAlphabetic)
                var w = i
                while w > 0, scalars[w - 1].properties.isAlphabetic || scalars[w - 1] == "." { w -= 1 }
                var word = String.UnicodeScalarView()
                word.append(contentsOf: scalars[w..<i])
                let abbreviation = s == "." && abbreviations.contains(String(word).lowercased())
                var j = i + 1
                while j < scalars.count, scalars[j] == " " { j += 1 }
                let nextLower = j < scalars.count && scalars[j].properties.isLowercase
                if !(initial || abbreviation || (s == "." && nextLower)) {
                    flush(i + 1)
                    start = i + 1
                }
            }
            i += 1
        }
        flush(scalars.count)
        return out
    }

    static func wordCount(_ s: String) -> Int { s.split(whereSeparator: { $0.isWhitespace }).count }

    /// Windows of about `words` words at paragraph boundaries; a long paragraph is cut at sentence boundaries.
    public static func windows(_ text: String, words: Int = 120) -> [TextSpan] {
        let scalars = Array(text.unicodeScalars)
        func span(_ a: Int, _ b: Int) -> TextSpan {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars[a..<b])
            return TextSpan(text: String(v), start: a, end: b)
        }
        // Paragraphs: separated by a blank line.
        var paragraphs: [TextSpan] = []
        var start = 0
        var i = 0
        while i < scalars.count {
            if scalars[i] == "\n" {
                var j = i + 1
                while j < scalars.count, scalars[j] == " " || scalars[j] == "\t" || scalars[j] == "\r" { j += 1 }
                if j < scalars.count, scalars[j] == "\n" {
                    paragraphs.append(span(start, i))
                    start = j + 1
                    i = j
                }
            }
            i += 1
        }
        paragraphs.append(span(start, scalars.count))
        paragraphs = paragraphs.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        var out: [TextSpan] = []
        var current: TextSpan?
        func push(_ s: TextSpan) {
            if let c = current, wordCount(c.text) + wordCount(s.text) <= words {
                current = span(c.start, s.end)
            } else {
                if let c = current { out.append(c) }
                current = s
            }
        }
        for p in paragraphs {
            if wordCount(p.text) <= words { push(p); continue }
            for s in sentences(p.text) { push(TextSpan(text: s.text, start: p.start + s.start, end: p.start + s.end)) }
        }
        if let c = current { out.append(c) }
        return out
    }

    /// Lower case with white space collapsed, keeping a map from each kept scalar to its original offset.
    static func normalized(_ text: String) -> (String, [Int]) {
        var out = String.UnicodeScalarView()
        var map: [Int] = []
        var lastSpace = true
        for (i, s) in text.unicodeScalars.enumerated() {
            if s.properties.isWhitespace {
                if !lastSpace { out.append(" "); map.append(i) }
                lastSpace = true
            } else {
                for l in String(s).lowercased().unicodeScalars { out.append(l); map.append(i) }
                lastSpace = false
            }
        }
        return (String(out), map)
    }

    /// Check 1: finds `quote` in `text`, case-insensitively with white space collapsed; returns the sentence that
    /// holds its start.
    public static func anchor(_ quote: String, in text: String, sentences: [TextSpan]) -> TextSpan? {
        let q = normalized(quote.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"“”«»"))).0
        guard q.count >= 3 else { return nil }
        let (hay, map) = normalized(text)
        guard let r = hay.range(of: q) else { return nil }
        let offset = hay.unicodeScalars.distance(from: hay.unicodeScalars.startIndex, to: r.lowerBound.samePosition(in: hay.unicodeScalars) ?? hay.unicodeScalars.startIndex)
        guard offset < map.count else { return nil }
        let at = map[offset]
        return sentences.first { $0.start <= at && at < $0.end }
    }

    /// Whether `needle` occurs in `hay` as whole words, case-insensitively with white space collapsed.
    public static func containsWords(_ hay: String, _ needle: String) -> Bool {
        let h = " " + normalized(hay).0.map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) } + " "
        let n = normalized(needle).0.map { $0.isLetter || $0.isNumber ? $0 : " " }.reduce(into: "") { $0.append($1) }
        let collapsed = n.split(separator: " ").joined(separator: " ")
        let hc = h.split(separator: " ").joined(separator: " ")
        guard !collapsed.isEmpty else { return false }
        return (" " + hc + " ").contains(" " + collapsed + " ")
    }
}

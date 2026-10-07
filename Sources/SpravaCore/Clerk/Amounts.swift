import Foundation

/// Check 3 of capture-event-v0 §6.4: code parses the amount the model copied, in digits or in words, English or
/// French. The model never writes the number.
public enum Amounts {
    public struct Parsed: Equatable, Sendable {
        public var value: Double
        public var currency: String?
    }

    static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
        "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "sept": 7, "huit": 8, "neuf": 9, "dix": 10,
        "onze": 11, "douze": 12, "treize": 13, "quatorze": 14, "quinze": 15, "seize": 16, "vingt": 20, "vingts": 20, "trente": 30,
        "quarante": 40, "cinquante": 50, "soixante": 60,
    ]
    static let scales: [String: Int] = ["hundred": 100, "cent": 100, "cents": 100, "thousand": 1000, "mille": 1000,
                                        "million": 1_000_000, "millions": 1_000_000]
    static let currencies: [(String, String)] = [("$", "CAD"), ("dollars", "CAD"), ("dollar", "CAD"), ("bucks", "CAD"), ("€", "EUR"),
                                                 ("euros", "EUR"), ("euro", "EUR"), ("usd", "USD"), ("cad", "CAD"), ("eur", "EUR")]

    public static func parse(_ raw: String) -> Parsed? {
        let text = raw.lowercased().replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        let currency = currencies.first { text.contains($0.0) }?.1
        // Digits: "1,200", "1 200", "625.50", "4 200,75".
        if let m = text.firstMatch(of: /\d[\d ,.]*/) {
            var digits = String(m.output).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
            digits = digits.replacingOccurrences(of: " ", with: "")
            if let comma = digits.lastIndex(of: ","), digits.distance(from: comma, to: digits.endIndex) == 3, !digits.contains(".") {
                digits.replaceSubrange(comma...comma, with: ".")   // French decimal comma
            }
            digits = digits.replacingOccurrences(of: ",", with: "")
            if let v = Double(digits), v > 0 {
                var value = v
                if text.contains("thousand") || text.contains("mille") || text.contains("k ") || text.hasSuffix("k") { value *= 1000 }
                return Parsed(value: value, currency: currency)
            }
        }
        // Words: "twelve hundred", "two thousand five hundred", "quatre mille deux cents", "quatre-vingt-dix".
        let words = text.replacingOccurrences(of: "-", with: " ").split(whereSeparator: { !$0.isLetter }).map(String.init)
        var total = 0, current = 0, seen = false
        var i = 0
        while i < words.count {
            let w = words[i]
            if w == "quatre", i + 1 < words.count, words[i + 1].hasPrefix("vingt") { current += 80; seen = true; i += 2; continue }
            if let u = units[w] { current += u; seen = true }
            else if let s = scales[w] {
                seen = true
                if s == 100 { current = max(current, 1) * 100 }
                else { total += max(current, 1) * s; current = 0 }
            } else if ["and", "et"].contains(w) { }
            else if seen { break }
            i += 1
        }
        let value = total + current
        return seen && value > 0 ? Parsed(value: Double(value), currency: currency) : nil
    }

    /// Finds an amount in a sentence by itself (digits with a currency, or number words with a currency word).
    public static func scan(_ sentence: String) -> Parsed? {
        let lower = sentence.lowercased()
        guard currencies.contains(where: { lower.contains($0.0) }) else { return nil }
        return parse(sentence)
    }
}

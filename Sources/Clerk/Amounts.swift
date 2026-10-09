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
        // Digits of other scripts read as ASCII (`CaptureText.asciiDigits`); the patterns match [0-9] only.
        let text = CaptureText.asciiDigits(raw.lowercased()).replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
        // A written code names the currency before any symbol: "USD $625" is in US dollars.
        let code = text.firstMatch(of: /\b(usd|cad|eur)\b/).map { String($0.output.1).uppercased() }
        let currency = code ?? currencies.first { text.contains($0.0) }?.1
        // Digits: "1,200", "1 200", "625.50", "4 200,75".
        if let m = text.firstMatch(of: /[0-9][0-9 ,.]*/) {
            var digits = String(m.output).trimmingCharacters(in: CharacterSet(charactersIn: " ,."))
            digits = digits.replacingOccurrences(of: " ", with: "")
            if let comma = digits.lastIndex(of: ","), digits.distance(from: comma, to: digits.endIndex) == 3, !digits.contains(".") {
                digits.replaceSubrange(comma...comma, with: ".")   // French decimal comma
            }
            digits = digits.replacingOccurrences(of: ",", with: "")
            if let v = Double(digits), v > 0 {
                var value = v
                if text.contains("million") { value *= 1_000_000 }
                else if text.contains("thousand") || text.contains("mille") || text.firstMatch(of: /[0-9]\s?k\b/) != nil { value *= 1000 }
                if text.firstMatch(of: /[0-9]\s*(cents?|¢)\b/) != nil, !text.contains("$"), !text.contains("dollar") { value /= 100 }
                // A number too large for a Double is no amount.
                return value.isFinite ? Parsed(value: value, currency: currency) : nil
            }
        }
        // Words: "twelve hundred", "two thousand five hundred", "quatre mille deux cents", "quatre-vingt-dix".
        let words = text.replacingOccurrences(of: "-", with: " ").split(whereSeparator: { !$0.isLetter }).map(String.init)
        var total = 0, current = 0, seen = false
        var i = 0
        while i < words.count {
            let w = words[i]
            if w == "quatre", i + 1 < words.count, words[i + 1].hasPrefix("vingt") {
                guard add(80, &current) else { return nil }
                seen = true; i += 2; continue
            }
            if let u = units[w] {
                guard add(u, &current) else { return nil }
                seen = true
            } else if let s = scales[w] {
                seen = true
                guard scale(s, &total, &current) else { return nil }
            } else if ["and", "et"].contains(w) { }
            else if seen { break }
            i += 1
        }
        guard add(current, &total) else { return nil }
        var value = Double(total)
        // English "cents" is money, not a hundred: "fifty cents" is half a dollar ("deux cents" stays 200).
        let english = words.contains { ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
                                        "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty",
                                        "forty", "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand"].contains($0) }
        if english, words.last == "cents" || words.last == "cent", !words.contains("dollars"), !words.contains("dollar") {
            guard let whole = wordsValue(words.dropLast()) else { return nil }
            value = Double(whole) / 100
        }
        return seen && value > 0 ? Parsed(value: value, currency: currency) : nil
    }

    /// The number named by English or French number words, as `parse` reads them; nil when it does not fit an `Int`.
    static func wordsValue<S: Sequence>(_ words: S) -> Int? where S.Element == String {
        var total = 0, current = 0
        for w in words {
            if let u = units[w] { guard add(u, &current) else { return nil } }
            else if let s = scales[w] { guard scale(s, &total, &current) else { return nil } }
        }
        return add(current, &total) ? total : nil
    }

    // Number words are untrusted text ("a hundred hundred hundred..."): every step is checked, and a number that
    // does not fit an `Int` is no amount rather than a trap.

    static func add(_ n: Int, _ into: inout Int) -> Bool {
        let (sum, overflow) = into.addingReportingOverflow(n)
        if !overflow { into = sum }
        return !overflow
    }

    /// "hundred" multiplies the current group; a larger scale closes the group into the total.
    static func scale(_ s: Int, _ total: inout Int, _ current: inout Int) -> Bool {
        let (product, overflow) = max(current, 1).multipliedReportingOverflow(by: s)
        guard !overflow else { return false }
        if s == 100 { current = product; return true }
        current = 0
        return add(product, &total)
    }

    /// Digits with a currency right before them ("$625", "CAD 1 200", "USD $625") or right after, a scale word allowed
    /// between ("625 dollars", "4 200,75 €", "2 million dollars"); a code beside a symbol stays with it ("$625 USD").
    /// A symbol after the number must not start another number: in "Invoice 2026 $625" the dollar sign belongs to 625.
    static var digitSpan: Regex<Substring> { #/(?:\b(?:usd|cad|eur)\b\s*[$€]?|[$€])\s*[0-9][0-9 ,.]*(?:\s*(?:k|millions?|thousand|mille)\b)?(?:\s*\b(?:usd|cad|eur)\b)?|[0-9][0-9 ,.]*(?:\s*(?:k|millions?|thousand|mille)\b)?\s*(?:[$€¢](?!\s*[0-9])(?:\s*\b(?:usd|cad|eur)\b)?|\b(?:dollars?|euros?|bucks|usd|cad|eur|cents?)\b)/# }

    /// Finds an amount in a sentence by itself (digits with a currency, or number words with a currency word). Only
    /// digits next to their currency count, so an invoice number or a date in the sentence is never the amount.
    public static func scan(_ sentence: String) -> Parsed? {
        let lower = sentence.lowercased()
        let words = Set(lower.split(whereSeparator: { !$0.isLetter && $0 != "$" && $0 != "€" }).map(String.init))
        guard currencies.contains(where: { $0.0.count == 1 ? lower.contains($0.0) : words.contains($0.0) }) else { return nil }
        let text = CaptureText.asciiDigits(lower).replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
        if let m = text.firstMatch(of: digitSpan) { return parse(String(m.output)) }
        // No digits by a currency: number words only ("twelve hundred dollars"); other digits are no amount.
        return parse(text.replacing(/[0-9]+/, with: " "))
    }
}

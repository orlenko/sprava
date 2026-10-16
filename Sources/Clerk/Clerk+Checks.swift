import Foundation
import SpravaKit

/// Checks 1 to 4 of capture-event-v0 §6.4: code checks every field the model copied.
extension Clerk {
    /// Checks one item the model listed. `scope` is the text the model was shown (its window, or the sentences of a
    /// second reading): the quote is anchored there only. `taken` are the items kept so far, for a quote that opens
    /// more than one sentence.
    func check(_ value: JSONValue, text: String, sentences: [TextSpan], today: CalendarDate, locale: String, estimated: Bool = false,
               scope: [TextSpan]? = nil, taken: [ClerkItem] = []) -> ClerkItem? {
        guard let quote = value["quote"]?.stringValue else { return nil }
        // What the model called the task tells items apart; the title shown is the source's words (`ownTitle`).
        let called = Self.shorten((value["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines), to: 120)
        guard !called.isEmpty else { return nil }
        let modelWhen = value["when_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        var action = value["action"]?.stringValue ?? "other"
        if !Self.actions.contains(action) { action = "other" }
        // Check 1. A quote that opens several sentences ("Your renewal for the plan ..." twice) is placed by the
        // words the item copied, its time words and amount, then on a sentence no like item holds yet, in text order.
        var found = CaptureText.anchors(quote, in: text, sentences: sentences, scope: scope)
        var ambiguous = false
        if found.count > 1 {
            for key in ["when_text", "amount_text"] {
                guard let words = value[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { continue }
                let holding = found.filter { CaptureText.containsWords($0.text, words) }
                if !holding.isEmpty { found = holding }
            }
            let free = found.filter { s in !taken.contains { $0.sentence == s && $0.action == action && Self.similar($0.identity, called) } }
            if !free.isEmpty { found = free }
            ambiguous = found.count > 1
        }
        guard let sentence = found.first else { return nil }
        var item = ClerkItem(title: "", action: action, sentence: sentence, people: [])
        item.called = called
        if ambiguous { item.flags.append("the quote opens more than one sentence") }

        // Check 4: people as whole words of the capture, never pronouns.
        for p in value["people"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            let name = Self.shorten(p.trimmingCharacters(in: .whitespacesAndNewlines), to: 120)
            let letters = name.filter(\.isLetter).count
            guard letters >= 2 || name.wholeMatch(of: /\p{Lu}\. ?\p{L}+.*/) != nil, !Self.pronouns.contains(name.lowercased()),
                  CaptureText.containsWords(text, name) else { continue }
            if !item.people.contains(name) { item.people.append(name) }
        }
        if item.action == "wait" && item.people.isEmpty { item.action = "other" }

        // Check 2: the time words occur in the item's sentence and are a known time pattern.
        if let when = modelWhen, !when.isEmpty,
           CaptureText.containsWords(sentence.text, when), let found = DateGrammar.resolve(when, anchor: today, locale: locale) {
            item.whenText = when
            item.whenResolved = found.date
        } else if let found = DateGrammar.scan(sentence.text, anchor: today, locale: locale) {
            // Added check: a time expression the model left out is taken from the sentence, and the card says so.
            item.whenText = found.text
            item.whenResolved = found.date
            item.flags.append("date taken from the sentence")
        }
        if let when = item.whenText {
            item.whenRole = DateGrammar.role(sentence: sentence.text, whenText: when, waiting: item.action == "wait")
            if let d = item.whenResolved, d < today { item.whenResolved = nil }   // never a past due date
            // An estimated capture time resolves only full dates (capture-event-v0 §6.6).
            if estimated, !DateGrammar.isFullDate(when, locale: locale) { item.whenResolved = nil }
        }
        item.title = Self.ownTitle(called, quote: quote, sentence: sentence.text, whenText: item.whenText)

        // Check 3: the amount text occurs in the sentence and parses above 0.
        if let amountText = value["amount_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !amountText.isEmpty,
           CaptureText.containsWords(sentence.text, amountText), let parsed = Amounts.parse(amountText) {
            item.amount = parsed
            item.amountText = amountText
        }
        if let inSentence = Amounts.scan(sentence.text), inSentence.value != item.amount?.value {
            item.flags.append("amount in the note not found in the item")
        }
        return item
    }

    // MARK: - The title: the person's own words

    /// An item's title is the words of its source, never a model's paraphrase (capture-event-v0 §6.4 check 1): the
    /// model's title is kept only when every word of it is in the item's sentence; otherwise code builds it from the
    /// sentence, so "Bill Acme today" is titled "Bill Acme", never "Call Bill Acme". Either way the time words are
    /// taken out only when their source context identifies one occurrence: an ambiguous title keeps its words.
    static func ownTitle(_ proposed: String, quote: String, sentence: String, whenText: String?) -> String {
        if hasOnlyWords(of: sentence, proposed) {
            let kept = cleaned(proposed, without: whenText, source: sentence)
            if hasOnlyWords(of: sentence, kept) { return kept }
        }
        var text = sentence
        let q = quote.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”«»")))
        if let r = phraseRange(q, in: text) { text = String(text[r.lowerBound...]) }
        let built = cleaned(text, without: whenText, source: sentence)
        if hasOnlyWords(of: sentence, built) { return built }
        // A sentence that is only its time words ("Tomorrow!") keeps them, rather than an empty title.
        let whole = cleaned(sentence, without: nil)
        return whole.isEmpty ? shorten(sentence.trimmingCharacters(in: .whitespacesAndNewlines), to: 120) : whole
    }

    /// Whether `title` has words, and every one of them occurs in `source` (case-insensitively).
    static func hasOnlyWords(of source: String, _ title: String) -> Bool {
        let own = words(title)
        return !own.isEmpty && own.isSubset(of: words(source))
    }

    static func words(_ s: String) -> Set<String> {
        Set(CaptureText.asciiDigits(CaptureText.normalized(s).0).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// Words that only lead into a time expression, left behind when the model's time words leave them out.
    static let timeLeads: Set<String> = ["by", "before", "on", "until", "till", "at", "d'ici", "avant", "le", "la", "jusqu'à", "pour", "dès"]

    /// `text` with its time words (and a word that only led into them) taken out, white space collapsed, list marks
    /// and end punctuation trimmed, the first letter capitalized, at most 120 characters.
    static func cleaned(_ text: String, without whenText: String?, source: String? = nil) -> String {
        var text = text
        if let when = whenText, let phrase = timePhrase(when, in: source ?? text) {
            let found = phraseRanges(phrase, in: text)
            if found.count == 1, let r = found.first {
                text = text[..<r.lowerBound] + " " + text[r.upperBound...]
            }
        }
        let ends = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,;:!?-–—•*·"))
        let title = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .replacingOccurrences(of: " ([,;:.!?])", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: ends)
        let first = title.prefix(1), upper = first.uppercased()
        return shorten((upper.count == 1 ? upper : String(first)) + title.dropFirst(), to: 120)
    }

    /// Identify a date context in the source, not in a possibly shortened model title. When "Friday" also names
    /// the task, only the unique "on Friday" / "by Friday" context is removable. Ambiguity preserves the words.
    static func timePhrase(_ when: String, in source: String) -> String? {
        let found = phraseRanges(when, in: source)
        let startsWithLead = when.split(whereSeparator: \.isWhitespace).first.map {
            timeLeads.contains($0.lowercased().replacingOccurrences(of: "’", with: "'"))
        } ?? false
        let contexts: [String] = found.compactMap { r in
            if startsWithLead { return when }
            guard let lead = source[..<r.lowerBound].split(whereSeparator: \.isWhitespace).last,
                  timeLeads.contains(lead.lowercased().replacingOccurrences(of: "’", with: "'")) else { return nil }
            return String(lead) + " " + when
        }
        if contexts.count == 1 { return contexts.first }
        return contexts.isEmpty && found.count == 1 ? when : nil
    }

    /// Where `phrase` occurs in `text` as whole words, case-insensitively, with any white space between its words.
    static func phraseRange(_ phrase: String, in text: String) -> Range<String.Index>? {
        guard let pattern = phrasePattern(phrase) else { return nil }
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive])
    }

    static func phraseRanges(_ phrase: String, in text: String) -> [Range<String.Index>] {
        guard let pattern = phrasePattern(phrase), let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text) }
    }

    static func phrasePattern(_ phrase: String) -> String? {
        let parts = phrase.split(whereSeparator: \.isWhitespace).map { NSRegularExpression.escapedPattern(for: String($0)) }
        guard !parts.isEmpty else { return nil }
        return "(?<![\\p{L}\\p{N}])" + parts.joined(separator: "\\s+") + "(?![\\p{L}\\p{N}])"
    }
}

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
        let title = Self.shorten((value["title"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines), to: 120)
        guard !title.isEmpty else { return nil }
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
            let free = found.filter { s in !taken.contains { $0.sentence == s && $0.action == action && Self.similar($0.title, title) } }
            if !free.isEmpty { found = free }
            ambiguous = found.count > 1
        }
        guard let sentence = found.first else { return nil }
        var item = ClerkItem(title: title, action: action, sentence: sentence, people: [])
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
        if let when = value["when_text"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !when.isEmpty,
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
}

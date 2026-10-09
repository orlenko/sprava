import Extract
import Foundation
import SpravaKit

/// Facts code finds in a reading (§4.1 steps 4 and 5): dates, amounts, reference numbers and the words that
/// hint at what the document is. They go on the card and in front of the model; the model never makes them.
public struct IntakeFacts: Sendable, Equatable {
    public var dates: [String] = []
    public var amounts: [String] = []
    public var references: [String] = []
    public var signals: [String] = []
    public var words = 0

    static let signalWords: [String: String] = [
        "invoice": "invoice", "facture": "invoice", "bill": "invoice", "amount due": "payment", "montant dû": "payment",
        "payment": "payment", "paiement": "payment", "due": "deadline", "deadline": "deadline", "échéance": "deadline",
        "notice": "notice", "avis": "notice", "please reply": "reply", "please respond": "reply", "let me know": "reply",
        "veuillez répondre": "reply", "minutes": "minutes", "procès-verbal": "minutes", "bylaw": "governing",
        "by-law": "governing", "règlement": "governing", "declaration": "governing", "déclaration": "governing",
        "amendment": "governing", "contract": "governing", "contrat": "governing", "agreement": "governing", "lease": "governing",
        "bail": "governing", "policy": "governing", "statement": "statement", "relevé": "statement", "receipt": "receipt",
        "reçu": "receipt", "confirmation": "confirmation", "sign": "signature", "signer": "signature", "signature": "signature",
    ]

    public static func of(_ reading: IntakeReading, anchor: CalendarDate, locale: String = "und") -> IntakeFacts {
        var f = IntakeFacts()
        let text = reading.text
        f.words = CaptureText.wordCount(text)
        let lower = text.lowercased()
        for (word, signal) in signalWords.sorted(by: { $0.key < $1.key }) where !f.signals.contains(signal) {
            if lower.range(of: "\\b" + NSRegularExpression.escapedPattern(for: word) + "\\b", options: .regularExpression) != nil { f.signals.append(signal) }
        }
        if text.contains("?"), ["reply"].allSatisfy({ !f.signals.contains($0) }),
           lower.range(of: #"\b(could you|can you|would you|pourriez-vous|pouvez-vous)\b"#, options: .regularExpression) != nil {
            f.signals.append("question")
        }
        for s in CaptureText.sentences(String(text.prefix(200_000))).prefix(2000) {
            // Only written dates count, never "Thursday": a full date, or one whose year is written in the sentence.
            if f.dates.count < 6, let found = DateGrammar.scan(s.text, anchor: anchor, locale: locale), let d = found.date,
               DateGrammar.isFullDate(found.text, locale: locale) || CaptureText.asciiDigits(s.text).contains(String(d.year)), !f.dates.contains(d.description) {
                f.dates.append(d.description)
            }
            if f.amounts.count < 6, let a = Amounts.scan(s.text), a.value > 0 {
                let shown = (a.currency.map { $0 + " " } ?? "") + String(format: a.value == a.value.rounded() ? "%.0f" : "%.2f", a.value)
                if !f.amounts.contains(shown) { f.amounts.append(shown) }
            }
            if f.dates.count >= 6 && f.amounts.count >= 6 { break }
        }
        let refPattern = #/(?i)\b(?:invoice|account|file|reference|ref|policy|facture|dossier|compte|numéro|no\.|n°)\s*(?:number|no\.?|#|n°)?\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{3,24})\b/#
        for m in text.prefix(200_000).matches(of: refPattern) where f.references.count < 4 {
            let ref = String(m.output.1)
            guard ref.contains(where: \.isNumber), !f.references.contains(ref) else { continue }
            f.references.append(ref)
        }
        return f
    }

    public var json: JSONValue {
        .obj([("dates", .array(dates.map(JSONValue.string))), ("amounts", .array(amounts.map(JSONValue.string))),
              ("references", .array(references.map(JSONValue.string))), ("signals", .array(signals.map(JSONValue.string))),
              ("words", .int(words))])
    }
}

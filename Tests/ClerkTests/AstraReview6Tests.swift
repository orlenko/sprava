@testable import Clerk
import ClerkTestSupport
import Extract
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the sixth adversarial review of increment 1 (a resumed restore's baseline, withdrawal by a binder
/// whose name collides, digits of other scripts in untrusted text). Invented data only.
@Suite(.serialized) struct AstraReview6Tests {
    let today = CalendarDate(year: 2026, month: 10, day: 6)!

    // MARK: - 3. Digits of other scripts never trap, and read as their ASCII digits

    static let foreignDigits = [
        "Payer le loyer avant le １５/１０/２０２６.",                   // full-width
        "Payer le loyer avant le ١٥/١٠/٢٠٢٦.",                          // Arabic-Indic
        "Payer le loyer avant le ۱۵.۱۰.۲۰۲۶ au plus tard.",              // Extended Arabic-Indic
        "Pay the invoice by １5/1０/２０26.",                            // mixed
        "Pay ١٢٠٠ $ by October ١٥, ٢٠٢٦.",
        "Le total est de ４ ２００,７５ € d'ici le १५ octobre २०२६.",     // full-width and Devanagari
        "Call back in ３ days, then again on the １５th.",
        "Reply by 2026-1０-15, or within ٢ weeks.",
        "Le 𝟏𝟓/𝟏𝟎/𝟐𝟎𝟐𝟔 ou le ¹⁵/¹⁰/²⁰²⁶, peu importe.",                // mathematical digits; superscripts are no digits
    ]

    @Test func foreignDigitsResolveAsTheirASCIIDigits() {
        let oct15 = CalendarDate(year: 2026, month: 10, day: 15)
        #expect(DateGrammar.resolve("１５/１０/２０２６", anchor: today, locale: "fr-FR")?.date == oct15)
        #expect(DateGrammar.resolve("١٥/١٠/٢٠٢٦", anchor: today, locale: "fr-FR")?.date == oct15)
        #expect(DateGrammar.resolve("１5/1０/２０26", anchor: today, locale: "fr-FR")?.date == oct15)
        #expect(DateGrammar.resolve("१५ octobre २०२६", anchor: today, locale: "fr")?.date == oct15)
        #expect(DateGrammar.resolve("in ３ days", anchor: today, locale: "en")?.date == CalendarDate(year: 2026, month: 10, day: 9))
        #expect(DateGrammar.resolve("¹⁵/¹⁰/²⁰²⁶", anchor: today, locale: "fr-FR")?.date == nil)
        #expect(Amounts.parse("１ ２００ $")?.value == 1200)
        #expect(Amounts.parse("٤٢٠٠,٧٥ €") == Amounts.Parsed(value: 4200.75, currency: "EUR"))
        // Offsets in other digits never trap, whatever they read as.
        _ = Clerk.captureDay("2026-10-06T09:00:00+０５:００")
        _ = IntakeReading.day(ofHeader: "Tue, 6 Oct 2026 23:30:00 +０５００")
        _ = IntakeReading.day(ofHeader: "Tue, ٦ Oct ٢٠٢٦ ٢٣:٣٠:٠٠ +٠٥٠٠")
    }

    @Test func intakeFactsAndTheClerksChecksSurviveForeignDigits() {
        let text = Self.foreignDigits.joined(separator: " ")
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        let clerk = Clerk(model: RecordingModel([]))
        let sentences = CaptureText.sentences(text)
        for locale in ["en", "en-CA", "fr", "fr-FR", "fr-CA"] {
            let facts = IntakeFacts.of(reading, anchor: today, locale: locale)
            if locale == "fr-FR" { #expect(facts.dates.contains("2026-10-15"), "\(facts.dates)") }
            #expect(facts.amounts.contains("CAD 1200"), "\(facts.amounts)")
            for s in sentences {
                let words = s.text.split(separator: " ").map(String.init)
                let phrases = [s.text] + words + zip(words, words.dropFirst()).map { "\($0) \($1)" }
                for when in phrases {
                    _ = DateGrammar.resolve(when, anchor: today, locale: locale)
                    _ = DateGrammar.isFullDate(when)
                    _ = Amounts.parse(when)
                    let fields: [(String, JSONValue)] = [("quote", .string(s.text)), ("title", .str("Pay the invented rent")),
                                                         ("action", .str("pay")), ("when_text", .string(when)), ("amount_text", .string(when))]
                    _ = clerk.check(.obj(fields), text: text, sentences: sentences, today: today, locale: locale)
                }
            }
        }
    }
}

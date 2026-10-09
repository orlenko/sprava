@testable import Clerk
import ClerkTestSupport
import Darwin
import Extract
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the fifth adversarial review of increment 1 (key files named by an inline MIME part, numbers in
/// untrusted text that overflowed, withdrawals a failing binder check held back, unreadable backup settings).
/// Invented data only.
@Suite(.serialized) struct AstraReview5Tests {
    let today = CalendarDate(year: 2026, month: 10, day: 6)!

    // MARK: - 2. Numbers in untrusted text never trap

    static let hostile = [
        "Reply in 9223372036854775807 weeks.",
        "Reply in 9223372036854775807 days.",
        "Reply within 1317624576693539402 weeks.",
        "Veuillez répondre dans 99999999999 jours.",
        "Reply in 5218 weeks.",
        "Reply in 36526 days.",
    ]

    @Test func hugeIntervalsAreNoDate() {
        for s in Self.hostile {
            let found = DateGrammar.scan(s, anchor: today, locale: "und")
            #expect(found != nil && found?.date == nil, "\(s)")
        }
        // Up to a hundred years still resolves.
        #expect(DateGrammar.resolve("in 5217 weeks", anchor: today, locale: "en")?.date == today.adding(days: 5217 * 7))
        #expect(DateGrammar.resolve("in 36525 days", anchor: today, locale: "en")?.date == today.adding(days: 36_525))
        #expect(DateGrammar.resolve("in three days", anchor: today, locale: "en")?.date == today.adding(days: 3))
    }

    @Test func datesPastTheCalendarAreNoDate() {
        let last = CalendarDate(year: 9999, month: 12, day: 30)!
        #expect(DateGrammar.resolve("tomorrow", anchor: last, locale: "en")?.date == CalendarDate(year: 9999, month: 12, day: 31))
        for phrase in ["day after tomorrow", "in 3 days", "in two weeks", "next week", "monday"] {
            let found = DateGrammar.resolve(phrase, anchor: last, locale: "en")
            #expect(found != nil && found?.date == nil, "\(phrase)")
        }
        #expect(last.checkedAdding(days: Int.max) == nil)
        #expect(last.checkedAdding(days: Int.min) == nil)
        #expect(CalendarDate(year: 1, month: 1, day: 1)!.checkedAdding(days: -1) == nil)
    }

    static let hostileAmounts = [
        "We owe a hundred hundred hundred hundred hundred hundred hundred hundred hundred hundred dollars.",
        "It costs ten hundred hundred hundred hundred hundred hundred hundred hundred hundred dollars.",
        "Pay one hundred hundred hundred hundred hundred hundred hundred hundred hundred hundred cents.",
        "Le total est cent cent cent cent cent cent cent cent cent cent euros.",
    ]

    @Test func hugeAmountsAreNoAmount() {
        for s in Self.hostileAmounts { #expect(Amounts.scan(s) == nil, "\(s)") }
        let digits = "$" + String(repeating: "9", count: 400) + " million"
        #expect(Amounts.parse(digits) == nil)
        #expect(Amounts.parse("twelve hundred dollars")?.value == 1200)
        #expect(Amounts.parse("fifty cents")?.value == 0.5)
        #expect(Amounts.parse("quatre-vingt-dix euros")?.value == 90)
    }

    @Test func intakeFactsAndTheClerksChecksSurviveHostileNumbers() {
        let text = (Self.hostile + Self.hostileAmounts).joined(separator: " ")
        let reading = IntakeReading(kind: "text", textFrom: "parsed", text: text, channel: "other")
        let facts = IntakeFacts.of(reading, anchor: today, locale: "en")
        #expect(facts.dates.isEmpty && facts.amounts.isEmpty)

        let clerk = Clerk(model: RecordingModel([]))
        let sentences = CaptureText.sentences(text)
        for s in sentences {
            for when: String? in [nil, s.text.replacingOccurrences(of: "Reply ", with: "").trimmingCharacters(in: .punctuationCharacters)] {
                var fields: [(String, JSONValue)] = [("quote", .string(s.text)), ("title", .str("Reply")), ("action", .str("send")),
                                                    ("amount_text", .string(s.text))]
                if let when { fields.append(("when_text", .string(when))) }
                let item = clerk.check(.obj(fields), text: text, sentences: sentences, today: today, locale: "en")
                #expect(item?.whenResolved == nil, "\(s.text)")
                if Self.hostileAmounts.contains(s.text) { #expect(item?.amount == nil, "\(s.text)") }
            }
        }
    }
}

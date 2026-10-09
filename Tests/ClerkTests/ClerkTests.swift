@testable import Clerk
import Foundation
import SpravaKit
import Testing

@Suite struct DateGrammarTests {
    // Tuesday 2026-10-06.
    let tue = CalendarDate(year: 2026, month: 10, day: 6)!

    func d(_ s: String, _ locale: String = "en-CA") -> String? {
        guard let f = DateGrammar.resolve(s, anchor: tue, locale: locale) else { return "not-a-time" }
        return f.date?.description
    }

    @Test func englishRules() {
        #expect(d("Thursday") == "2026-10-08")
        #expect(d("by Friday") == "2026-10-09")
        #expect(d("Tuesday") == "2026-10-13")          // said on a Tuesday: one week later
        #expect(d("this Tuesday") == "2026-10-06")
        #expect(d("next Thursday") == nil)             // left unresolved
        #expect(d("tomorrow") == "2026-10-07")
        #expect(d("in three days") == "2026-10-09")
        #expect(d("in two weeks") == "2026-10-20")
        #expect(d("next week") == "2026-10-12")
        #expect(d("end of the month") == "2026-10-31")
        #expect(d("end of the year") == "2026-12-31")
        #expect(d("the 15th") == "2026-10-15")
        #expect(d("the 6th") == "2026-11-06")           // said on that day: next month
        #expect(d("the 31st") == "2026-10-31")
        #expect(d("October 3") == nil)                 // passed days ago: most likely the past date
        #expect(d("October 30") == "2026-10-30")
        #expect(d("March 1") == "2027-03-01")
        #expect(d("2026-11-02") == "2026-11-02")
        #expect(d("11/02/2026") == nil)                // en-CA: numeric forms stay unresolved
        #expect(d("yesterday") == nil)
        #expect(d("none") == "not-a-time")
        #expect(d("two") == "not-a-time")              // a bare number is not a day of the month
        #expect(d("within two") == "not-a-time")
        #expect(d("within two weeks") == "2026-10-20")
        #expect(d("15") == "not-a-time")
        #expect(d("not to the tenant") == "not-a-time")
    }

    @Test func frenchRules() {
        #expect(d("d'ici vendredi", "fr-CA") == "2026-10-09")
        #expect(d("jeudi prochain", "fr-CA") == nil)
        #expect(d("demain", "fr-CA") == "2026-10-07")
        #expect(d("dans deux semaines", "fr-CA") == "2026-10-20")
        #expect(d("la semaine prochaine", "fr-CA") == "2026-10-12")
        #expect(d("à la fin du mois", "fr-CA") == "2026-10-31")
        #expect(d("le 15", "fr-CA") == "2026-10-15")
        #expect(d("le 30 octobre", "fr-CA") == "2026-10-30")
        #expect(d("15/10/2026", "fr-FR") == "2026-10-15")
        #expect(d("15/10/2026", "fr-CA") == nil)
    }

    @Test func roles() {
        #expect(DateGrammar.role(sentence: "Send the form by Friday.", whenText: "Friday", waiting: false) == .due)
        #expect(DateGrammar.role(sentence: "If nothing comes by Wednesday, chase the agent.", whenText: "Wednesday", waiting: true) == .follow_up)
        #expect(DateGrammar.role(sentence: "The report should arrive within two weeks.", whenText: "two weeks", waiting: true) == .expected)
        #expect(DateGrammar.role(sentence: "The agent sends it Thursday.", whenText: "Thursday", waiting: true) == .expected)
    }

    @Test func amounts() {
        #expect(Amounts.parse("625 dollars")?.value == 625)
        #expect(Amounts.parse("$1,200")?.value == 1200)
        #expect(Amounts.parse("4 200,75 $")?.value == 4200.75)
        #expect(Amounts.parse("twelve hundred dollars")?.value == 1200)
        #expect(Amounts.parse("two thousand five hundred")?.value == 2500)
        #expect(Amounts.parse("quatre mille deux cents dollars")?.value == 4200)
        #expect(Amounts.parse("quatre-vingt-dix euros")?.value == 90)
        #expect(Amounts.parse("none") == nil)
        #expect(Amounts.parse("0 dollars") == nil)
        #expect(Amounts.scan("Pay the plumber 625 dollars.")?.value == 625)
        #expect(Amounts.scan("Call A. Example at 3.") == nil)
    }

    @Test func sentencesAndAnchors() {
        let text = "Call A. Example about the deed by Friday. Pay the plumber 625 dollars!\nThen rest"
        let s = CaptureText.sentences(text)
        #expect(s.map(\.text) == ["Call A. Example about the deed by Friday.", "Pay the plumber 625 dollars!", "Then rest"])
        #expect(CaptureText.anchor("pay  the PLUMBER", in: text, sentences: s)?.text == "Pay the plumber 625 dollars!")
        #expect(CaptureText.anchor("buy a boat", in: text, sentences: s) == nil)
        #expect(CaptureText.containsWords(text, "a. example"))
        #expect(!CaptureText.containsWords(text, "exam"))
    }

    @Test func windowsKeepParagraphsAndSplitLongOnes() {
        let para = (1...30).map { "Sentence number \($0) has five words." }.joined(separator: " ")
        let text = "Short first paragraph.\n\n" + para
        let w = CaptureText.windows(text, words: 60)
        #expect(w.count >= 3)
        #expect(w.allSatisfy { CaptureText.wordCount($0.text) <= 60 })
        let scalars = Array(text.unicodeScalars)
        for span in w {
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars[span.start..<span.end])
            #expect(String(v) == span.text)
        }
    }
}

@Suite(.serialized) struct ClerkTests {
    @Test func captureDayUsesTheWrittenOffset() {
        #expect(Clerk.captureDay("2026-10-06T23:30:00-04:00")?.description == "2026-10-06")
        #expect(Clerk.captureDay("2026-10-07T03:30:00+00:00")?.description == "2026-10-07")
    }
}

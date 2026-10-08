@testable import Clerk
import Darwin
import Foundation
import Testing

// Regression tests for the third hostile review (increments 4 to 6). Invented data only.

@Suite(.serialized) struct ReviewRegression3Tests {
    // 18. "At the latest" and "au plus tard" make a due date.
    @Test func r06_rolePrefixes() {
        #expect(DateGrammar.role(sentence: "Le notaire répond au plus tard vendredi.", whenText: "vendredi", waiting: true) == .due)
        #expect(DateGrammar.role(sentence: "The bank replies at the latest Friday.", whenText: "Friday", waiting: true) == .due)
    }

    // Amounts: cents, a name ending in k, millions.
    @Test func r16_amounts() {
        #expect(Amounts.parse("fifty cents")?.value == 0.5)
        #expect(Amounts.scan("Pay Frank 625 dollars for the work")?.value == 625)
        #expect(Amounts.parse("2 million dollars")?.value == 2_000_000)
        #expect(Amounts.parse("deux cents dollars")?.value == 200)
    }
}

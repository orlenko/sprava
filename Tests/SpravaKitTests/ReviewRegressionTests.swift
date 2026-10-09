import Foundation
@testable import SpravaKit
import Testing

/// One test per confirmed finding of the increment-1 hostile review.
@Suite struct ReviewRegressionTests {
    @Test func int64MinDoesNotCrash() throws {
        let (value, safety) = try JSONParser.parse(#"{"x": -9223372036854775808}"#)
        #expect(value["x"]?.numberValue?.safeInteger == nil)
        #expect(safety.unsafeNumbers == ["$.x"])
    }

    @Test func normalizationEquivalentKeysAreDistinct() throws {
        let (value, safety) = try JSONParser.parse("{\"caf\u{E9}\":1,\"cafe\u{301}\":2}")
        #expect(safety.isSafe)
        #expect(value["caf\u{E9}"]?.numberValue?.text == "1")
        #expect(value["cafe\u{301}"]?.numberValue?.text == "2")
        #expect(JSONValue.string("caf\u{E9}") != JSONValue.string("cafe\u{301}"))
    }

    @Test func deepNestingWithLongKeysStaysCheap() throws {
        let key = String(repeating: "k", count: 2000)
        func nested(_ depth: Int) -> String {
            String(repeating: "{\"\(key)\":", count: depth) + "1" + String(repeating: "}", count: depth)
        }
        let clock = ContinuousClock()
        let elapsed = try clock.measure { _ = try JSONParser.parse(nested(120)) }
        #expect(elapsed < .seconds(2))
        #expect(throws: JSONParseError.self) { try JSONParser.parse(nested(200)) }
        #expect(throws: JSONParseError.self) { try JSONParser.parse(String(repeating: "[", count: 100_000)) }
    }

    @Test func weekDatesStayInRange() {
        #expect(CalendarDate.lenient("9999W527") == nil)
        #expect(CalendarDate.lenient("9999-W52-7") == nil)
        #expect(CalendarDate.lenient("9999-W52-5")?.description == "9999-12-31")
    }

    @Test func timestampsAreStrictRFC3339() {
        #expect(Timestamp.parse("2026-10-05t10:00:00z") != nil)
        #expect(Timestamp.parse("2026-10-05T10:00:00.250+05:30") != nil)
        for bad in ["2026-02-30T10:00:00Z", "2026-10-05T25:00:00Z", "2026-10-05T10:00:00+0530",
                    "2026-10-05T10:00:00+05", "2026-10-05T10:00:00Zjunk", "2026-10-05 10:00:00Z", "2026-10-05"] {
            #expect(Timestamp.parse(bad) == nil, "\(bad)")
        }
    }
}

import Foundation
@testable import SpravaKit
import Testing

@Suite struct JSONParserTests {
    @Test func keepsKeyOrderAndNumbersAsWritten() throws {
        let (value, safety) = try JSONParser.parse(#"{"b": 1, "a": 2.0, "c": [true, null, "x"]}"#)
        #expect(safety.isSafe)
        let object = try #require(value.objectValue)
        #expect(object.keys == ["b", "a", "c"])
        #expect(object["a"]?.numberValue?.text == "2.0")
        #expect(object["a"]?.numberValue?.isIntegerLiteral == false)
        #expect(object["b"]?.numberValue?.safeInteger == 1)
    }

    @Test func reportsDuplicateKeysLoneSurrogatesAndUnsafeIntegers() throws {
        let (_, safety) = try JSONParser.parse(#"{"a": 1, "a": 2, "s": "\ud800", "n": 9007199254740993}"#)
        #expect(safety.duplicateKeys == ["$.a"])
        #expect(safety.loneSurrogates == ["$.s"])
        #expect(safety.unsafeNumbers == ["$.n"])
    }

    @Test func decodesSurrogatePairsAndEscapes() throws {
        let (value, safety) = try JSONParser.parse(#"["😀", "Звіт", "a\nb\"c"]"#)
        #expect(safety.isSafe)
        #expect(value.arrayValue?.compactMap(\.stringValue) == ["😀", "Звіт", "a\nb\"c"])
    }

    @Test(arguments: ["", "{", "[1,]", "{\"a\" 1}", "01", "1.", "nul", "\"\u{01}\"", "{} x", "\u{FEFF}{}"])
    func rejectsInvalidJSON(_ text: String) {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(text) }
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: JSONParseError.self) { try JSONParser.parse(Data([0x22, 0xFF, 0x22])) }
    }
}

@Suite struct CalendarDateTests {
    @Test func strictAcceptsOnlyRealYYYYMMDD() {
        #expect(CalendarDate.strict("2026-10-07")?.description == "2026-10-07")
        #expect(CalendarDate.strict("2026-02-29") == nil)
        #expect(CalendarDate.strict("2028-02-29") != nil)
        #expect(CalendarDate.strict("20261007") == nil)
        #expect(CalendarDate.strict("2026-10-7") == nil)
    }

    @Test func lenientMatchesPythonFromisoformat() {
        #expect(CalendarDate.lenient("20260705")?.description == "2026-07-05")
        // 2026-W27-1 is Monday 29 June 2026; a missing weekday is Monday.
        #expect(CalendarDate.lenient("2026-W27-1")?.description == "2026-06-29")
        #expect(CalendarDate.lenient("2026W27")?.description == "2026-06-29")
        #expect(CalendarDate.lenient("2026W275")?.description == "2026-07-03")
        // 2026 has 53 ISO weeks; 2025 does not.
        #expect(CalendarDate.lenient("2026-W53") != nil)
        #expect(CalendarDate.lenient("2025-W53") == nil)
        #expect(CalendarDate.lenient("2026-W27-8") == nil)
        #expect(CalendarDate.lenient("next week") == nil)
    }

    @Test func dayArithmeticRoundTrips() {
        let d = CalendarDate(year: 2026, month: 12, day: 31)!
        #expect(d.adding(days: 1).description == "2027-01-01")
        #expect(CalendarDate(year: 2026, month: 3, day: 1)!.adding(days: -1).description == "2026-02-28")
        #expect(CalendarDate(year: 2026, month: 10, day: 7)!.isoWeekday == 3)
        for n in stride(from: 700_000, to: 760_000, by: 997) {
            #expect(CalendarDate(dayNumber: n).dayNumber == n)
        }
    }
}

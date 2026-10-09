import Darwin
import Foundation
@testable import SpravaKit
import Testing

/// Regression tests for the second hostile review (increments 2 and 3). Each test names the finding it pins.
@Suite(.serialized) struct ReviewRegression2Tests {
    // 14. Keys that differ only by normalization stay two keys in the canonical form.
    @Test func canonicalKeysCompareByCodeUnits() throws {
        let v = try JSONParser.parse(Data("{\"\u{00E9}\":1,\"e\u{0301}\":2}".utf8)).value
        let w = try JSONParser.parse(Data("{\"\u{00E9}\":9,\"e\u{0301}\":2}".utf8)).value
        #expect(try Canonical.hash(v) != (try Canonical.hash(w)))
        #expect(try Canonical.serialize(v) == "{\"e\u{0301}\":2,\"\u{00E9}\":1}")
    }

    // Third review: a long member name above many unsafe values made the safety report hold a full copy of
    // that name per problem (gigabytes from a file of about a megabyte). The report is now bounded.
    @Test func safetyReportStaysBoundedUnderALongParentKey() throws {
        let key = String(repeating: "\u{00E9}", count: 128 * 1024)  // 256 KiB of two-byte scalars
        let numbers = Array(repeating: "9007199254740993", count: 2_000).joined(separator: ",")
        let surrogates = Array(repeating: "\"\\ud800\"", count: 2_000).joined(separator: ",")
        let duplicates = Array(repeating: "{\"k\":1,\"k\":2}", count: 200).joined(separator: ",")
        let text = "{\"\(key)\":{\"n\":[\(numbers)],\"s\":[\(surrogates)],\"d\":[\(duplicates)]}}"
        let safety = try JSONParser.parse(Data(text.utf8)).safety
        #expect(!safety.isSafe)
        for list in [safety.unsafeNumbers, safety.loneSurrogates, safety.duplicateKeys] {
            #expect(list.count == JSONSafetyReport.maxEntries)
            #expect(list.allSatisfy { $0.utf8.count <= JSONSafetyReport.maxPathBytes && $0.hasSuffix("...") })
            #expect(list.allSatisfy { $0.hasPrefix("$.\u{00E9}") })
        }
        // Short paths are still reported whole.
        let small = try JSONParser.parse(Data("{\"a\":{\"b\":[1,9007199254740993]}}".utf8)).safety
        #expect(small.unsafeNumbers == ["$.a.b[1]"])
    }
}

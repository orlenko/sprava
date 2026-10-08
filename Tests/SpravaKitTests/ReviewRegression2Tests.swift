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
}

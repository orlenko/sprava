@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct ReplayTests {
    func sampleLines() throws -> [JSONObject] {
        let url = try #require(TestFixtures.bundle.url(forResource: "ops", withExtension: "ndjson", subdirectory: "Fixtures/ops"))
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(try JSONParser.parse(String($0)).value.objectValue)
        }
    }

    /// binder-v0 §6.6: replaying the sample log reproduces every after_hash and the final catalog.
    @Test func sampleLogReplaysToEveryRecordedHash() throws {
        let lines = try sampleLines()
        let final = try Replay.run(lines)
        let url = try #require(TestFixtures.bundle.url(forResource: "final-catalog", withExtension: "json", subdirectory: "Fixtures/ops"))
        let expected = try JSONParser.parse(try Data(contentsOf: url)).value
        #expect(try Canonical.hash(.object(final)) == (try Canonical.hash(expected)))
        #expect(.object(final) == expected)   // same keys in the same order, too
    }

    @Test func aTamperedLineIsReported() throws {
        var lines = try sampleLines()
        var args = lines[6]["args"]!.objectValue!
        args.set("follow_up_at", .string("2026-10-14"))
        lines[6].set("args", .object(args))
        #expect(throws: Replay.Mismatch.self) { try Replay.run(lines) }
    }
}

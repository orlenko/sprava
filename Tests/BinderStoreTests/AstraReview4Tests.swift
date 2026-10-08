@testable import BinderStore
import CryptoKit
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the fourth adversarial review of increment 1 (key and credential files in intake, hub
/// withdrawal while the outbox fails, private corrections that close items, correction cards that could not be
/// kept, unreadable op logs, exhausted id sequences) and the MCP socket's modes. Invented data only.
@Suite(.serialized) struct AstraReview4Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    // MARK: - 5. An op log that cannot be read is never taken for none

    @Test func anUnreadableOpLogStopsAdoptionBeforeAnyWrite() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        // A binder never adopted has no log: that alone is an empty one.
        #expect(try store.readOpLog().ops.isEmpty)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("first"))]), now: now)
        let sprava = folder.appendingPathComponent(".sprava")
        let names = ["ops.ndjson", "owner.json", "snapshot.json", "adopted/catalog.json"]
        let before = try names.map { try Data(contentsOf: sprava.appendingPathComponent($0)) }

        let log = sprava.appendingPathComponent("ops.ndjson")
        chmod(log.path, 0o200)
        defer { chmod(log.path, 0o600) }
        #expect(throws: TekaStore.Refused.self) { try store.readOpLog() }
        #expect(throws: TekaStore.Refused.self) {
            try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("second"))]), now: now)
        }
        chmod(log.path, 0o600)
        #expect(try names.map { try Data(contentsOf: sprava.appendingPathComponent($0)) } == before)
    }

    // MARK: - 6. An exhausted id sequence is an error, never a crash

    @Test func anExhaustedSequenceIsRefused() throws {
        func catalog(_ id: String) throws -> JSONObject {
            try #require(try JSONParser.parse(#"{"meta":{"name":"example"},"open_items":[{"id":"\#(id)"}]}"#).value.objectValue)
        }
        #expect(throws: TekaStore.Refused.self) {
            try IDMint.next(catalog: try catalog("example-2026-9223372036854775807"), opLog: [], year: 2026)
        }
        // Another year's sequence is untouched, and a number past 32 bits is written out whole.
        #expect(try IDMint.next(catalog: try catalog("example-2026-9223372036854775807"), opLog: [], year: 2027) == "example-2027-001")
        #expect(try IDMint.next(catalog: try catalog("example-2026-4294967296"), opLog: [], year: 2026) == "example-2026-4294967297")
        // Approving a new item there is refused, not a trap.
        let add = JSONObject([(key: "op", value: .str("add_item")),
                              (key: "args", value: .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Invented task"))]))]))])
        #expect(throws: TekaStore.Refused.self) {
            try Placeholders.resolve([add], catalog: try catalog("example-2026-9223372036854775807"), opLog: [], year: 2026, at: "2026-10-06T00:00:00Z")
        }
    }
}

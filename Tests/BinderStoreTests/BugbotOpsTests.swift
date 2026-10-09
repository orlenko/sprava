import BinderFormat
@testable import BinderStore
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

// Regression tests for the Bugbot review of the ops layer (privacy ratchet, hub lane, proposals, store, guard,
// adoption). Invented data only.

@Suite(.serialized) struct BugbotOpsTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    /// Edits catalog.json the way another program would: no lock, no op.
    func outsideEdit(_ folder: URL, _ change: (inout JSONObject) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        change(&catalog)
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
    }

    @Test func anUpdateCardShowsOldAndNewValues() throws {   // p8-Qm
        let catalog = try #require(try JSONParser.parse(#"{"open_items":[{"id":"x-1","title":"Old title","redact":true,"kind":"payment"}]}"#).value.objectValue)
        let op = try #require(try JSONParser.parse(#"{"op":"update_item","args":{"id":"x-1","set":{"title":"New title"},"unset":["redact"]}}"#).value.objectValue)
        let line = Proposal.describe(op, catalog: catalog)
        #expect(line.contains("title: Old title -> New title"), "\(line)")
        #expect(line.contains("remove redact (was true)"))
        #expect(line.contains("privacy change"))
        let quiet = try #require(try JSONParser.parse(#"{"op":"update_item","args":{"id":"x-1","set":{"priority":"high"}}}"#).value.objectValue)
        #expect(!Proposal.describe(quiet, catalog: catalog).contains("privacy"))
    }

    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    @Test func mintingSkipsIDsSeenOnlyInTheImport() throws {   // qgAN8
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        try outsideEdit(folder) { c in
            c.set("open_items", .array((c["open_items"]?.arrayValue ?? []).filter { $0["id"] != .str("estate-example-2026-012") }))
        }
        try TekaStore(folder: folder).settle(now: now)
        let catalog = try #require(Teka.read(folder).catalog)
        let log = try TekaStore(folder: folder).readOpLog().ops
        #expect(try IDMint.next(catalog: catalog, opLog: log, year: 2026) == "estate-example-2026-013")
    }

    // MARK: - Guard and validation

    func guardLine(_ type: String, _ args: JSONValue, actor: JSONObject) -> JSONObject {
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .str("2026-10-07T09:00:00Z"))
        line.set("actor", .object(actor))
        if actor["kind"] == .str("brain") {
            line.set("proposal", .str("p1"))
            line.set("approved_by", .str("user"))
        }
        line.set("op", .string(type))
        line.set("args", args)
        return line
    }

    func v0Catalog() throws -> JSONObject {
        let url = try #require(TestFixtures.bundle.url(forResource: "sprava-v0", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
    }

    @Test func aFreeLogEntryNeedsAnAction() throws {   // qIe1W
        let catalog = try v0Catalog()
        for entry: JSONValue in [.obj([]), .obj([("action", .int(3))]), .obj([("action", .str(" "))])] {
            #expect(throws: TransactionGuard.Rejection.self) {
                try TransactionGuard.check([guardLine("add_log_entry", .obj([("entry", entry)]), actor: user)], on: catalog)
            }
        }
        _ = try TransactionGuard.check([guardLine("add_log_entry", .obj([("entry", .obj([("action", .str("offloaded"))]))]), actor: user)], on: catalog)
    }

    @Test func recurrenceIsNotRemovedInThisVersion() throws {   // p8-RD
        let catalog = try v0Catalog()
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("sprava/0.1"))])
        for actor in [brain, user] {
            let line = guardLine("update_item", .obj([("id", .str("estate-example-2026-010")), ("unset", .array([.str("recurrence")]))]), actor: actor)
            #expect {
                try TransactionGuard.check([line], on: catalog)
            } throws: { ($0 as? TransactionGuard.Rejection)?.description.contains("recurrence") == true }
        }
    }

    @Test func closureFieldsHaveLogEntryTypes() throws {   // p8-Re
        let catalog = try v0Catalog()
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("sprava/0.1"))])
        for args: JSONValue in [.obj([("id", .str("estate-example-2026-007")), ("closed_at", .int(5))]),
                                .obj([("id", .str("estate-example-2026-007")), ("source", .obj([]))]),
                                .obj([("id", .str("estate-example-2026-007")), ("note", .int(1))])] {
            #expect(throws: TransactionGuard.Rejection.self) { try TransactionGuard.check([guardLine("complete", args, actor: brain)], on: catalog) }
        }
        let external = JSONObject([(key: "kind", value: .str("external")), (key: "client", value: .str("sprava/0.1"))])
        _ = try TransactionGuard.check([guardLine("complete", .obj([("id", .str("estate-example-2026-007")), ("closed_at", .null),
                                                                     ("source", .str("osavul"))]), actor: external)], on: catalog)
    }

    @Test func spravasOwnAddendumDoesNotMeanLifeprojReaches() throws {   // qfZ4T
        let only = try makeTeka(fixture: "lifeproj-v2-fresh") { f in
            try Data(ManualAddendum.text.utf8).write(to: f.appendingPathComponent("CLAUDE.md"))
        }
        #expect(Adoption.survey(only, inRegistry: false)["lifeproj_can_reach"] == .bool(false))
        let result = try Adoption.adopt(only, inRegistry: false, deviceID: "t", today: today, now: now)
        let stamp = try #require(result.proposals.first { $0.title == "Stamp this binder as binder v0" })
        #expect(Proposal.describe(stamp.ops[0], catalog: nil).contains("meta.disclosure = none"))
        // An instruction outside the addendum still counts.
        let both = try makeTeka(fixture: "lifeproj-v2-fresh") { f in
            try Data(("# Binder\n\n" + ManualAddendum.text + "\n## Digest\n\nRun `lifeproj publish` at the end.\n").utf8)
                .write(to: f.appendingPathComponent("CLAUDE.md"))
        }
        #expect(Adoption.survey(both, inRegistry: false)["lifeproj_can_reach"] == .bool(true))
    }
}

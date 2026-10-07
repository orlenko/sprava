import Foundation
import Testing
@testable import SpravaCore

@Suite struct GuardTests {
    let user = JSONValue.obj([("kind", .str("user")), ("client", .str("sprava/0.1"))])
    let clerk = JSONValue.obj([("kind", .str("clerk")), ("client", .str("sprava/0.1")), ("model", .str("apple-on-device"))])

    func catalog() throws -> JSONObject {
        let url = try #require(Bundle.module.url(forResource: "sprava-v0", withExtension: "json", subdirectory: "Fixtures"))
        return try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
    }

    func op(_ type: String, _ args: [(String, JSONValue)], actor: JSONValue? = nil,
            extra: [(String, JSONValue)] = []) -> JSONObject {
        JSONObject([("id", .str(UUID().uuidString.lowercased())), ("at", .str("2026-10-07T09:00:00Z")),
                    ("actor", actor ?? user)].map { (key: $0.0, value: $0.1) }
                   + extra.map { (key: $0.0, value: $0.1) }
                   + [(key: "op", value: .str(type)), (key: "args", value: .obj(args))])
    }

    func newItem(_ id: String, _ fields: [(String, JSONValue)] = []) -> JSONValue {
        .obj([("id", .str(id)), ("title", .str("Call the notary")), ("status", .str("open")),
              ("priority", .str("normal")), ("due", .str("2026-10-12")),
              ("created_at", .str("2026-10-07T09:00:00Z")), ("updated_at", .str("2026-10-07T09:00:00Z"))] + fields)
    }

    @Test func acceptsAValidAddAndCompleteBatch() throws {
        let c = try catalog()
        let ops = [op("add_item", [("item", newItem("estate-example-2026-020"))]),
                   op("complete", [("id", .str("estate-example-2026-020")), ("closed_at", .str("2026-10-07T09:00:00Z")),
                                   ("source", .str("user"))])]
        let (result, hashes) = try TransactionGuard.check(ops, on: c)
        #expect(hashes.count == 2)
        let log = result["processing_log"]!.arrayValue!
        #expect(log.last?["id"] == .str("estate-example-2026-020"))
        #expect(log.last?["action"] == .str("done"))
        #expect(log.last?["final"]?["due"] == .str("2026-10-12"))
    }

    @Test func rejectsAnItemThatBreaksTheRules() throws {
        let bad = newItem("estate-example-2026-021").objectValue!
        var dateless = bad
        dateless.remove("due")
        #expect(throws: TransactionGuard.Rejection.self) {
            try TransactionGuard.check([op("add_item", [("item", .object(dateless))])], on: try catalog())
        }
        var waiting = bad
        waiting.set("status", .str("waiting"))
        #expect(throws: TransactionGuard.Rejection.self) {
            try TransactionGuard.check([op("add_item", [("item", .object(waiting))])], on: try catalog())
        }
    }

    @Test func refusesReusedIDsAndUnapprovedClerkOps() throws {
        // estate-example-2026-003 is closed in the processing log.
        #expect(throws: TransactionGuard.Rejection.self) {
            try TransactionGuard.check([op("add_item", [("item", newItem("estate-example-2026-003"))])], on: try catalog())
        }
        #expect(throws: TransactionGuard.Rejection.self) {
            try TransactionGuard.check([op("add_item", [("item", newItem("estate-example-2026-022"))], actor: clerk)], on: try catalog())
        }
        let approved = op("add_item", [("item", newItem("estate-example-2026-022"))], actor: clerk,
                          extra: [("proposal", .str(UUID().uuidString.lowercased())), ("approved_by", .str("user"))])
        #expect(throws: Never.self) { try TransactionGuard.check([approved], on: try catalog()) }
    }

    @Test func onlyTheUserSetsDisclosure() throws {
        let byClerk = op("set_disclosure", [("disclosure", .str("full"))], actor: clerk,
                         extra: [("proposal", .str("p")), ("approved_by", .str("user"))])
        #expect(throws: TransactionGuard.Rejection.self) { try TransactionGuard.check([byClerk], on: try catalog()) }
        let (result, _) = try TransactionGuard.check([op("set_disclosure", [("disclosure", .str("full"))])], on: try catalog())
        #expect(result["meta"]?["disclosure"] == .str("full"))
    }

    @Test func aBrokenRecordCanBeRepairedOneAtATime() throws {
        // Two broken items; fixing one is accepted though the other stays broken.
        var c = try catalog()
        var items = c["open_items"]!.arrayValue!
        for i in [0, 3] {
            var o = items[i].objectValue!
            o.remove("due")
            items[i] = .object(o)
        }
        c.set("open_items", .array(items))
        #expect(TransactionGuard.violations(c).count == 2)
        let fix = op("update_item", [("id", items[0]["id"]!), ("set", .obj([("due", .str("2026-10-20"))]))])
        let (fixed, _) = try TransactionGuard.check([fix], on: c)
        #expect(TransactionGuard.violations(fixed).count == 1)
        // Touching a broken record without repairing it is refused.
        let touch = op("update_item", [("id", items[3]["id"]!), ("set", .obj([("priority", .str("low"))]))])
        #expect(throws: TransactionGuard.Rejection.self) { try TransactionGuard.check([touch], on: c) }
    }

    @Test func recurringItemsAdvanceAndNeverClose() throws {
        let c = try catalog()
        let id = JSONValue.str("estate-example-2026-010")   // has recurrence in the fixture
        #expect(throws: TransactionGuard.Rejection.self) {
            try TransactionGuard.check([op("complete", [("id", id), ("closed_at", .str("2026-10-07T09:00:00Z")),
                                                         ("source", .str("user"))])], on: c)
        }
        let advance = op("complete", [("id", id), ("closed_at", .str("2026-10-07T09:00:00Z")), ("source", .str("user")),
                                      ("occurrence_due", .str("2026-11-14")), ("next_due", .str("2027-02-14"))])
        let (result, _) = try TransactionGuard.check([advance], on: c)
        #expect(result["open_items"]!.arrayValue!.first { $0["id"] == id }?["due"] == .str("2027-02-14"))
        #expect(result["processing_log"]!.arrayValue!.last?["action"] == .str("occurrence"))
    }
}

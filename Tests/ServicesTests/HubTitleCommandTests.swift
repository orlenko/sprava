import BinderFormat
import BinderStore
import Foundation
import Hub
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// What the hub shows of an item's title through the command table: a hub title the person confirmed stays
/// until they allow an outside change; a closed item shows once as done, with its id only, then drops.
/// Invented data only.
@Suite(.serialized) struct HubTitleCommandTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-hub-title-\(label)-\(UUID().uuidString)")
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func proposals(_ c: Commands, _ folder: URL) throws -> [JSONValue] {
        try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
    }

    /// A lifeproj v2 binder adopted and approved to ready, publishing at full, with a spool next to it.
    func readyBinder(_ c: Commands) throws -> (URL, URL) {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path)), ("in_registry", .bool(true))])
        for card in try proposals(c, folder) {
            _ = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        }
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    /// Changes one item in catalog.json the way another program would: no lock, no op.
    func outsideEdit(_ folder: URL, item id: String, _ change: (inout JSONObject) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        catalog.set("open_items", .array((catalog["open_items"]?.arrayValue ?? []).map { v in
            guard v["id"] == .string(id), case .object(var o) = v else { return v }
            change(&o)
            return .object(o)
        }))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
    }

    func hubTitles(_ folder: URL, _ spool: URL) throws -> [String] {
        _ = try HubLane.publish(folder, root: spool, now: now)
        let slice = try JSONParser.parse(try Data(contentsOf: spool.appendingPathComponent("inbox/rental-elm-street.agenda.json"))).value
        return slice["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
    }

    func approvePrivacyCard(_ c: Commands, _ folder: URL, line: String) throws {
        let card = try #require(try proposals(c, folder).first { card in
            card["state"] == .str("proposed") && card["lines"]?.arrayValue?.contains { $0.stringValue?.contains(line) == true } == true
        })
        #expect(card["verified"] == .bool(true))
        #expect(card["lines"]?.arrayValue?.contains { $0.stringValue?.contains("privacy change") == true } == true)
        let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        #expect(r["ok"] == .bool(true), "\(r)")
    }

    func adoptedBinder() throws -> (URL, URL) {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try Adoption.adopt(folder, inRegistry: true, deviceID: "t", today: today, now: now)
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    func slice(_ spool: URL) throws -> JSONValue {
        try JSONParser.parse(try Data(contentsOf: spool.appendingPathComponent("inbox/rental-elm-street.agenda.json"))).value
    }

    @Test func aHubTitleRemovedOrChangedOutsideStaysUntilThePersonAllowsIt() throws {
        let c = Commands(support: temp("support"), deviceID: "dev")
        let (folder, spool) = try readyBinder(c)
        let natural = "Звіт для бухгалтера"
        let r = try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("update_item")),
                             ("args", .obj([("id", .str("item-0006")), ("set", .obj([("slice_title", .str("Invented paperwork"))]))]))])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(try hubTitles(folder, spool).contains("Invented paperwork"))

        // Removed outside: the hub keeps the confirmed title, never the natural one.
        try outsideEdit(folder, item: "item-0006") { $0.remove("slice_title") }
        var titles = try hubTitles(folder, spool)
        #expect(titles.contains("Invented paperwork") && !titles.contains(natural), "\(titles)")
        // Changed outside: the same.
        try outsideEdit(folder, item: "item-0006") { $0.set("slice_title", .str("Invented changed title")) }
        titles = try hubTitles(folder, spool)
        #expect(titles.contains("Invented paperwork") && !titles.contains("Invented changed title"), "\(titles)")

        // The person allows the change on a privacy card; then the hub follows it.
        try approvePrivacyCard(c, folder, line: "slice_title")
        titles = try hubTitles(folder, spool)
        #expect(titles.contains("Invented changed title"), "\(titles)")

        // A removal allowed the same way lets the natural title through, and only then.
        try outsideEdit(folder, item: "item-0006") { $0.remove("slice_title") }
        #expect(!(try hubTitles(folder, spool)).contains(natural))
        try approvePrivacyCard(c, folder, line: "remove slice_title")
        #expect(try hubTitles(folder, spool).contains(natural))
        // Nothing is left waiting once the found title is the confirmed one.
        #expect(try PrivacyRatchet.ensureCard(folder: folder, client: "t", now: now) == nil)
    }

    @Test func aClosedItemShowsOnlyItsIDEvenAfterAnOutsideEdit() throws {
        let c = Commands(support: temp("support"), deviceID: "dev")
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path)), ("in_registry", .bool(true))])
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
        for card in listed {
            _ = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        }
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        func slice() throws -> [JSONValue] {
            _ = try HubLane.publish(folder, root: spool, now: now)
            return try JSONParser.parse(try Data(contentsOf: spool.appendingPathComponent("inbox/rental-elm-street.agenda.json"))).value["items"]?.arrayValue ?? []
        }
        func apply(_ op: String, _ args: [(String, JSONValue)]) throws {
            let r = try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .string(op)), ("args", .obj(args))])
            #expect(r["ok"] == .bool(true), "\(r)")
        }
        let natural = "Звіт для бухгалтера"
        try apply("update_item", [("id", .str("item-0006")), ("set", .obj([("slice_title", .str("Invented paperwork"))]))])
        try apply("update_item", [("id", .str("item-0003")), ("set", .obj([("redact", .bool(true)), ("kind", .str("other"))]))])
        let before = try slice()
        #expect(before.contains { $0["title"] == .str("Invented paperwork") })
        let redactedID = try #require(before.first { $0["title"] == .str("[redacted]") }?["id"])

        // Removed outside, then both items completed before any privacy card is approved.
        try outsideEdit(folder, item: "item-0006") { $0.remove("slice_title") }
        try outsideEdit(folder, item: "item-0003") { $0.remove("redact") }
        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        for id in ["item-0006", "item-0003"] {
            try apply("complete", [("id", .string(id)), ("closed_at", .string(at)), ("source", .str("user"))])
        }
        let after = try slice()
        let done = after.filter { $0["status"] == .str("done") }
        #expect(done.count == 2, "\(after)")
        // A closed item is published once with its id only (no title, tags or dates), under the slice id it had:
        // neither the natural title nor the lifted redaction ever reaches the hub.
        #expect(done.allSatisfy { $0["title"] == .str("[closed]") }, "\(done)")
        let paperworkID = try #require(before.first { $0["title"] == .str("Invented paperwork") }?["id"])
        #expect(Set(done.compactMap { $0["id"] }) == [paperworkID, redactedID], "\(done)")
        #expect(!after.contains { $0["title"]?.stringValue == natural }, "\(after)")
    }

    @Test func aClosedItemShowsOnceAsDoneThenDrops() throws {
        let (folder, spool) = try adoptedBinder()
        _ = try HubLane.publish(folder, root: spool, now: now)
        let c = Commands(support: folder.deletingLastPathComponent().appendingPathComponent("s"), deviceID: "t")
        _ = c.handle(JSONWriter.compact(.obj([("command", .str("apply")), ("binder", .string(folder.path)), ("op", .str("complete")),
                                              ("args", .obj([("id", .str("item-0003")), ("closed_at", .str("2026-10-07T09:00:00Z")), ("source", .str("user"))]))])))
        _ = try HubLane.publish(folder, root: spool, now: now)
        let once = try slice(spool)["items"]!.arrayValue!.first { $0["id"] == .str("rental-elm-street-item-0003") }
        #expect(once?["status"] == .str("done"))
        _ = try HubLane.publish(folder, root: spool, now: now)
        #expect(try slice(spool)["items"]!.arrayValue!.contains { $0["id"] == .str("rental-elm-street-item-0003") } == false)
    }
}

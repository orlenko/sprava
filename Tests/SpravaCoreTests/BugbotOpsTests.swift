import Darwin
import Foundation
import Testing
@testable import SpravaCore

// Regression tests for the Bugbot review of the ops layer (privacy ratchet, hub lane, proposals, store, guard,
// adoption). Invented data only.

@Suite(.serialized) struct BugbotOpsTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func commands() -> Commands {
        Commands(support: FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-\(UUID().uuidString)"), deviceID: "dev")
    }

    /// A binder made by Sprava: stamped v0, at disclosure none, with an empty spool next to it.
    func createdBinder(_ c: Commands, name: String = "estate-sample") throws -> (URL, URL) {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let r = try call(c, [("command", .str("create_binder")), ("parent", .string(parent.path)), ("name", .string(name))])
        let folder = URL(fileURLWithPath: try #require(r["binder"]?.stringValue, "\(r)"), isDirectory: true)
        let spool = parent.appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    /// A lifeproj v2 binder adopted and approved to ready, publishing at full, with a spool next to it.
    func readyBinder(_ c: Commands) throws -> (URL, URL) {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        _ = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path)), ("in_registry", .bool(true))])
        for card in try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? [] {
            _ = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        }
        let spool = folder.deletingLastPathComponent().appendingPathComponent("spool")
        try FileManager.default.createDirectory(at: spool, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return (folder, spool)
    }

    /// Edits catalog.json the way another program would: no lock, no op.
    func outsideEdit(_ folder: URL, _ change: (inout JSONObject) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        change(&catalog)
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
    }

    func setMeta(_ key: String, _ value: JSONValue) -> (inout JSONObject) -> Void {
        { c in
            var meta = c["meta"]?.objectValue ?? JSONObject()
            meta.set(key, value)
            c.set("meta", .object(meta))
        }
    }

    func updateItem(_ id: String, _ change: @escaping (inout JSONObject) -> Void) -> (inout JSONObject) -> Void {
        { c in
            let items = (c["open_items"]?.arrayValue ?? []).map { v -> JSONValue in
                guard v["id"] == .string(id), case .object(var o) = v else { return v }
                change(&o)
                return .object(o)
            }
            c.set("open_items", .array(items))
        }
    }

    func apply(_ c: Commands, _ folder: URL, _ op: String, _ args: JSONValue) throws -> JSONValue {
        try call(c, [("command", .str("apply")), ("binder", .string(folder.path)), ("op", .string(op)), ("args", args)])
    }

    func sliceURL(_ spool: URL, _ name: String) -> URL { spool.appendingPathComponent("inbox/\(name).agenda.json") }

    // MARK: - The privacy ratchet (qIlEh)

    @Test func anOutsideDisclosureWideningWaitsForAPrivacyCard() throws {
        let c = commands()
        let (folder, spool) = try createdBinder(c)
        try outsideEdit(folder, setMeta("disclosure", .str("full")))
        // The hub sees nothing until the person approves.
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: sliceURL(spool, "estate-sample").path))
        // The card is the person's own set_disclosure, verified, and made once.
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
        let card = try #require(listed.first { $0["lines"]?.arrayValue?.first?.stringValue?.hasPrefix("Set disclosure to full") == true })
        #expect(card["verified"] == .bool(true))
        #expect(card["lines"]?.arrayValue?.first?.stringValue?.contains("privacy change") == true)
        let again = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
        #expect(again.count == listed.count)
        let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(try HubLane.publish(folder, root: spool, now: now) == .published(items: 0, overwrittenByOther: false))
    }

    @Test func anOutsideWideningDoesNotOpenTheBinderToBrains() throws {
        let c = commands()
        let (folder, _) = try createdBinder(c)
        try outsideEdit(folder, setMeta("disclosure", .str("full")))
        let client = MCPClientRecord(id: "brain-1", name: "Brain", tokenSHA256: "", binders: [folder.standardizedFileURL.path: "propose"],
                                     createdAt: "", revoked: false)
        let server = MCPServer(client: client, commands: c, shelf: { Shelf.rows(registry: nil, picked: [folder]) }, now: { self.now })
        #expect(server.visible().isEmpty)
        // The person's own raise opens it at once.
        _ = try apply(c, folder, "set_disclosure", .obj([("disclosure", .str("full"))]))
        #expect(server.visible().count == 1)
    }

    @Test func anOutsideRedactionLiftStaysRedactedOnTheHub() throws {
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("redact", .bool(true)), ("kind", .str("payment"))]))]))
        // Lifted outside before any publish, so the hub cursors never saw the redaction.
        try outsideEdit(folder, updateItem("item-0006") { $0.remove("redact") })
        _ = try HubLane.publish(folder, root: spool, now: now)
        let slice = try JSONParser.parse(try Data(contentsOf: sliceURL(spool, "rental-elm-street"))).value
        let titles = slice["items"]?.arrayValue?.compactMap { $0["title"]?.stringValue } ?? []
        #expect(titles.contains("[redacted]"))
        let lines = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue?
            .flatMap { $0["lines"]?.arrayValue ?? [] }.compactMap(\.stringValue) ?? []
        #expect(lines.contains { $0.contains("remove redact") && $0.contains("privacy change") })
    }

    @Test func narrowingTakesEffectAtOnce() throws {
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        try outsideEdit(folder, setMeta("disclosure", .str("none")))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .removed)
        #expect(!FileManager.default.fileExists(atPath: sliceURL(spool, "rental-elm-street").path))
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
}

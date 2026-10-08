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

    // MARK: - Hub lane

    @Test func narrowingToTitleWithdrawsTheFullSlice() throws {   // p8-QK
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        _ = try apply(c, folder, "set_disclosure", .obj([("disclosure", .str("title"))]))
        guard case .notPublished = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("expected notPublished"); return }
        #expect(!FileManager.default.fileExists(atPath: sliceURL(spool, "rental-elm-street").path))
        #expect(HubLane.loadCursors(folder).sliceHash == nil)
    }

    @Test func unreadableCursorsStopPublishing() throws {   // qIe1n
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("redact", .bool(true)), ("kind", .str("payment"))]))]))
        _ = try HubLane.publish(folder, root: spool, now: now)
        let before = try Data(contentsOf: sliceURL(spool, "rental-elm-street"))
        try outsideEdit(folder, updateItem("item-0006") { $0.remove("redact") })
        try Data("{".utf8).write(to: folder.appendingPathComponent(".sprava/cursors.json"))
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(folder, root: spool, now: now) }
        #expect(try Data(contentsOf: sliceURL(spool, "rental-elm-street")) == before)
        #expect(String(decoding: before, as: UTF8.self).contains("[redacted]"))
    }

    @Test func aFailedSliceRemovalIsReported() throws {   // qHLt7
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        let hash = HubLane.loadCursors(folder).sliceHash
        let inbox = spool.appendingPathComponent("inbox")
        chmod(inbox.path, 0o500)
        defer { chmod(inbox.path, 0o700) }
        _ = try apply(c, folder, "set_disclosure", .obj([("disclosure", .str("none"))]))
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(folder, root: spool, now: now) }
        #expect(HubLane.loadCursors(folder).sliceHash == hash)
    }

    @Test func anUnreadableOutboxIsAFailure() throws {   // qHLuC
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        #expect(try HubLane.drain(folder, root: spool, now: now) == HubLane.DrainResult())
        let outbox = spool.appendingPathComponent("outbox")
        try FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        #expect(try HubLane.drain(folder, root: spool, now: now) == HubLane.DrainResult())
        let file = outbox.appendingPathComponent("rental-elm-street.intake.json")
        try Data(#"{"completions":[{"id":"item-0003","action":"done","at":"2026-10-07T08:00:00Z"}]}"#.utf8).write(to: file)
        chmod(file.path, 0o000)
        defer { chmod(file.path, 0o600) }
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(folder, root: spool, now: now) }
    }

    @Test func aDeletedSliceIsPublishedAgain() throws {   // qIlEJ
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        try FileManager.default.removeItem(at: sliceURL(spool, "rental-elm-street"))
        guard case .published = try HubLane.publish(folder, root: spool, now: now) else { Issue.record("expected published"); return }
        #expect(FileManager.default.fileExists(atPath: sliceURL(spool, "rental-elm-street").path))
        #expect(try HubLane.publish(folder, root: spool, now: now) == .unchanged)
    }

    @Test func aDamagedSliceKeyIsNeverReplaced() throws {   // qI0_M
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        let keyURL = folder.appendingPathComponent(".sprava/slice-key")
        let short = Data(repeating: 7, count: 10)
        try short.write(to: keyURL)
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("priority", .str("high"))]))]))
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(folder, root: spool, now: now) }
        #expect(try Data(contentsOf: keyURL) == short)
    }

    @Test func aClosedDuplicateShowsOnceAsDone() throws {   // p8-RS
        let c = commands()
        let (folder, spool) = try readyBinder(c)
        _ = try HubLane.publish(folder, root: spool, now: now)
        // A hand-written closure with another action leaves the item open with a closed id.
        try outsideEdit(folder) { cat in
            var log = cat["processing_log"]?.arrayValue ?? []
            log.append(.obj([("id", .str("item-0006")), ("action", .str("completed")), ("at", .str("2026-10-07"))]))
            cat.set("processing_log", .array(log))
        }
        let r = try apply(c, folder, "complete", .obj([("id", .str("item-0006"))]))
        #expect(r["ok"] == .bool(true), "\(r)")
        _ = try HubLane.publish(folder, root: spool, now: now)
        let items = try JSONParser.parse(try Data(contentsOf: sliceURL(spool, "rental-elm-street"))).value["items"]?.arrayValue ?? []
        let shown = items.filter { $0["id"] == .str("rental-elm-street-item-0006") }
        #expect(shown.count == 1 && shown.first?["status"] == .str("done"))
    }

    @Test func collidingBinderNamesAreFound() throws {   // qewBo
        let a = try makeTeka(fixture: "lifeproj-v1-legacy", folderName: "tax-2026")
        let b = try makeTeka(fixture: "lifeproj-v1-legacy", folderName: "Tax-2026") { f in
            let url = f.appendingPathComponent("catalog.json")
            let text = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "\"tax-2026\"", with: "\"Tax-2026\"")
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        let other = try makeTeka(fixture: "lifeproj-v2-live")
        let rows = Shelf.rows(registry: nil, picked: [a, b, other])
        let colliding = HubLane.collidingFolders(rows, today: today)
        #expect(colliding == [a.standardizedFileURL.path, b.standardizedFileURL.path])
        // A former name another binder still drains under counts too.
        let renamed = try makeTeka(fixture: "lifeproj-v2-fresh", folderName: "estate-renamed") { f in
            let url = f.appendingPathComponent("catalog.json")
            var cat = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
            var meta = cat["meta"]?.objectValue ?? JSONObject()
            meta.set("name", .str("estate-renamed"))
            meta.set("former_names", .array([.obj([("name", .str("Rental-Elm-Street")), ("until", .str("2027-01-01"))])]))
            cat.set("meta", .object(meta))
            try Data(JSONWriter.pretty(.object(cat)).utf8).write(to: url)
        }
        #expect(HubLane.collidingFolders(Shelf.rows(registry: nil, picked: [other, renamed]), today: today).count == 2)
    }
}

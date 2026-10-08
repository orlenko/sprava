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

    // MARK: - Proposals and store durability

    struct Boom: Error {}

    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    func body(_ op: String, _ args: JSONValue) -> JSONObject {
        JSONObject([(key: "op", value: .string(op)), (key: "args", value: args)])
    }

    /// A file in the binder's intake/ and its digest.
    func intakeFile(_ folder: URL, _ name: String, _ text: String) throws -> String {
        let url = folder.appendingPathComponent("intake/\(name)")
        try Data(text.utf8).write(to: url)
        return try #require(DocumentPaths.sha256(of: url))
    }

    func filing(_ name: String, sha: String, to dir: String = "letters", placeholder: Int) -> JSONObject {
        body("file_document", .obj([("from", .string("intake/\(name)")),
                                    ("document", .obj([("id", .string("$new:\(placeholder)")), ("title", .string("Scan \(name)")),
                                                       ("path", .string("\(dir)/\(name)")), ("sha256", .string(sha))]))]))
    }

    func item(_ folder: URL, _ id: String) -> JSONValue? {
        Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["id"] == .string(id) }
    }

    @Test func aLinkedProposalsFolderIsRefused() throws {   // p8-QZ
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-elsewhere-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let proposals = folder.appendingPathComponent(".sprava/proposals")
        try FileManager.default.removeItem(at: proposals)
        try FileManager.default.createSymbolicLink(at: proposals, withDestinationURL: elsewhere)
        let card = Proposal.make(title: "x", actor: user, ops: [body("drop", .obj([("id", .str("item-0006"))]))], now: now)
        #expect(throws: TekaStore.Refused.self) { try ProposalStore.save(card, in: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
        #expect(ProposalStore.list(in: folder).isEmpty)
    }

    @Test func anOverwrittenFilingIsOfferedWhole() throws {   // p8-RK
        let c = commands()
        let (folder, _) = try createdBinder(c)
        let sha = try intakeFile(folder, "scan-a.pdf", "invented letter A")
        let before = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let store = TekaStore(folder: folder)
        let card = Proposal.make(title: "File a letter", actor: user, ops: [
            filing("scan-a.pdf", sha: sha, placeholder: 1),
            body("add_item", .obj([("item", .obj([("id", .str("$new:2")), ("title", .str("Reply to letter A")), ("status", .str("open")),
                                                   ("priority", .str("normal")), ("no_deadline", .bool(true))]))])),
        ], now: now)
        try ProposalStore.save(card, in: folder)
        try store.approve(card, now: now)
        try before.write(to: folder.appendingPathComponent("catalog.json"))   // another program puts the old copy back
        let settler = TekaStore(folder: folder)
        try settler.settle(now: now)
        let id = try #require(settler.createdProposals.first)
        let again = try ProposalStore.load(id, in: folder, expectedDigest: nil)
        #expect(again.ops.compactMap { $0["op"]?.stringValue } == ["file_document", "add_item"])
        #expect(again.ops[0]["args"]?["from"] == nil)
        try TekaStore(folder: folder).approve(again, now: now)
        #expect(Teka.read(folder).catalog?["documents"]?.arrayValue?.count == 1)
        // An op that cannot be rebuilt makes a card for a repair by hand, never a part of the batch.
        let lost = [body("add_log_entry", .obj([("entry", .obj([("action", .str("noted"))]))]))]
        let manual = try #require(TekaStore.reapplyCard(lost, client: "sprava/0.1", now: now))
        #expect(manual.raw["provenance"]?["manual_repair"] == .bool(true))
        try ProposalStore.save(manual, in: folder)
        #expect(throws: TekaStore.Refused.self) { try TekaStore(folder: folder).approve(manual, now: now) }
    }

    @Test func anUnreadableDashboardIsLeftAlone() throws {   // qI0_Y
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let keeper = DashboardKeeper(folder: folder)
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        let file = folder.appendingPathComponent("DASHBOARD.md")
        let big = Data(("## Notes\n\nkept by hand\n" + String(repeating: "x", count: 5 * 1024 * 1024)).utf8)
        try big.write(to: file)
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("priority", .str("high"))]))]))
        #expect(throws: TekaStore.Refused.self) { try keeper.refresh(today: today, timeZone: utc, now: now) }
        #expect(try Data(contentsOf: file) == big)
    }

    @Test func aCardIsCheckedAgainstWhatItIsAppliedTo() throws {   // qBsr8
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let card = Proposal.make(title: "Raise it", actor: user,
                                 ops: [body("update_item", .obj([("id", .str("item-0006")), ("set", .obj([("priority", .str("high"))]))]))], now: now)
        try ProposalStore.save(card, in: folder)
        let saved = try ProposalStore.load(card.id, in: folder, expectedDigest: nil)   // with its `expect`
        let store = TekaStore(folder: folder)
        store.testHookBeforeLock = { try? self.outsideEdit(folder, self.updateItem("item-0006") { $0.set("title", .str("Changed outside")) }) }
        #expect(throws: TekaStore.Refused.self) { try store.approve(saved, now: now) }
        #expect(item(folder, "item-0006")?["title"] == .str("Changed outside"))
        #expect(item(folder, "item-0006")?["priority"] == .str("low"))
    }

    @Test func anUnreadableShelfStopsCreateBinder() throws {   // qBssv
        let c = commands()
        try FileManager.default.createDirectory(at: c.support, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: c.support.appendingPathComponent("shelf.json"))
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let r = try call(c, [("command", .str("create_binder")), ("parent", .string(parent.path)), ("name", .str("estate-sample"))])
        #expect(r["ok"] == .bool(false))
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }

    @Test func digestsThatCannotBeKeptAreAFailure() throws {   // qJwVe
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let runtime = c.support.appendingPathComponent("runtime")
        chmod(runtime.path, 0o500)
        defer { chmod(runtime.path, 0o700) }
        let card = Proposal.make(title: "x", actor: user, ops: [body("drop", .obj([("id", .str("item-0006"))]))], now: now)
        try ProposalStore.save(card, in: folder)
        #expect(throws: (any Error).self) { try c.trustProposals([card.id], in: folder) }
    }

    @Test func undoSeesAnEditMadeBeforeTheLock() throws {   // qIe1Q
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let r = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("title", .str("New A"))]))]))
        let opID = try #require(r["op"]?.stringValue)
        let store = TekaStore(folder: folder)
        store.testHookBeforeLock = { try? self.outsideEdit(folder, self.updateItem("item-0006") { $0.set("title", .str("Outside")) }) }
        #expect(throws: (any Error).self) { try store.undo(opID: opID, now: now) }
        #expect(item(folder, "item-0006")?["title"] == .str("Outside"))
    }

    @Test func undoNeverOverwritesANewerChange() throws {   // qfZ4P
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let a = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("priority", .str("low"))]))]))
        _ = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("priority", .str("high"))]))]))
        let r = try call(c, [("command", .str("undo")), ("binder", .string(folder.path)), ("op_id", a["op"]!)])
        #expect(r["ok"] == .bool(false))
        #expect(item(folder, "item-0006")?["priority"] == .str("high"))
    }

    @Test func anEditDuringTheLogFlushAbortsAndRetries() throws {   // qcRsL
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let store = TekaStore(folder: folder)
        var fired = false
        store.testHookAfterAppend = {
            guard !fired else { return }
            fired = true
            try self.outsideEdit(folder, self.updateItem("item-0003") { $0.set("title", .str("Edited outside")) })
        }
        let change = TekaStore.OpBody(op: "update_item", args: JSONObject([(key: "id", value: .str("item-0006")),
                                                                         (key: "set", value: .obj([("priority", .str("high"))]))]), actor: user)
        let lines = try store.apply([change], now: now)
        let ops = try store.readOpLog().ops
        let abort = try #require(ops.last { $0["op"] == .str("abort") })
        #expect(abort["args"]?["ops"]?.arrayValue?.count == 1)
        #expect(abort["args"]?["ops"]?.arrayValue?.first != lines.first?["id"])
        #expect(ops.contains { $0["op"] == .str("external_edit") })
        #expect(item(folder, "item-0003")?["title"] == .str("Edited outside"))
        #expect(item(folder, "item-0006")?["priority"] == .str("high"))
        #expect((try? Replay.run(ops)) != nil)
    }

    @Test func aFailedFilingPutsMovedFilesBack() throws {   // qcRsR
        let c = commands()
        let (folder, _) = try createdBinder(c)
        let one = try intakeFile(folder, "one.pdf", "invented letter one")
        let two = try intakeFile(folder, "two.pdf", "invented letter two")
        let card = Proposal.make(title: "File two letters", actor: user,
                                 ops: [filing("one.pdf", sha: one, placeholder: 1), filing("two.pdf", sha: two, placeholder: 2)], now: now)
        try ProposalStore.save(card, in: folder)
        let store = TekaStore(folder: folder)
        store.testHookAfterAppend = {
            // A crash after the first move; the second destination was taken meanwhile.
            let letters = folder.appendingPathComponent("letters")
            try FileManager.default.createDirectory(at: letters, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: folder.appendingPathComponent("intake/one.pdf"), to: letters.appendingPathComponent("one.pdf"))
            try Data("someone else".utf8).write(to: letters.appendingPathComponent("two.pdf"))
            throw Boom()
        }
        #expect(throws: Boom.self) { try store.approve(card, now: now) }
        try TekaStore(folder: folder).settle(now: now)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("intake/one.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("letters/one.pdf").path))
        #expect(try TekaStore(folder: folder).readOpLog().ops.last?["op"] == .str("abort"))
    }

    @Test func mintingSkipsIDsSeenOnlyInTheImport() throws {   // qgAN8
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        try outsideEdit(folder) { c in
            c.set("open_items", .array((c["open_items"]?.arrayValue ?? []).filter { $0["id"] != .str("estate-example-2026-012") }))
        }
        try TekaStore(folder: folder).settle(now: now)
        let catalog = try #require(Teka.read(folder).catalog)
        let log = try TekaStore(folder: folder).readOpLog().ops
        #expect(IDMint.next(catalog: catalog, opLog: log, year: 2026) == "estate-example-2026-013")
    }

    @Test func aFilingIsNotOfferedForUndo() throws {   // qIe10
        let c = commands()
        let (folder, _) = try createdBinder(c)
        let sha = try intakeFile(folder, "scan-b.pdf", "invented letter B")
        let card = Proposal.make(title: "File a letter", actor: user, ops: [filing("scan-b.pdf", sha: sha, placeholder: 1)], now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)
        let listed = try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? []
        let shown = try #require(listed.first { $0["id"] == .string(card.id) })
        let r = try call(c, [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", shown["id"]!), ("digest", shown["digest"]!)])
        #expect(r["ok"] == .bool(true), "\(r)")
        let history = try call(c, [("command", .str("history")), ("binder", .string(folder.path))])["ops"]?.arrayValue ?? []
        let filed = try #require(history.first { $0["line"]?.stringValue?.contains("letters/scan-b.pdf") == true })
        #expect(filed["undoable"] == .bool(false))
    }

    @Test func clearingAWaitingItemsDueSetsNoDeadline() throws {   // qIe18
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let add = body("add_item", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Hear back from the agent")), ("status", .str("waiting")),
                                                         ("priority", .str("normal")), ("due", .str("2026-11-01")), ("waiting_on", .str("the agent")),
                                                         ("follow_up_at", .str("2026-10-20"))]))]))
        let edited = try CardEdits.apply([.obj([("index", .int(0)), ("due", .str(""))])], to: [add])
        #expect(edited[0]["args"]?["item"]?["no_deadline"] == .bool(true))
        try TekaStore.dryRun(edited, actor: user, folder: folder, now: now)
    }

    @Test func revokeWithdrawsCardsOfAClientRegisteredAgain() throws {   // p8-Qs
        let c = commands()
        let (a, _) = try readyBinder(c)
        let (b, _) = try createdBinder(c)
        _ = try call(c, [("command", .str("register_client")), ("client_id", .str("c1")), ("binders", .obj([(a.path, .str("propose"))]))])
        _ = try call(c, [("command", .str("revoke_client")), ("client_id", .str("c1"))])
        _ = try call(c, [("command", .str("register_client")), ("client_id", .str("c1")), ("binders", .obj([(b.path, .str("propose"))]))])
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("sprava/0.1")), (key: "model", value: .str("c1"))])
        let card = Proposal.make(title: "x", actor: brain, ops: [body("add_log_entry", .obj([("entry", .obj([("action", .str("noted"))]))]))], now: now)
        try ProposalStore.save(card, in: b)
        let r = try call(c, [("command", .str("revoke_client")), ("client_id", .str("c1"))])
        #expect(r["withdrawn"] == .int(1))
        #expect(ProposalStore.list(in: b).first { $0.0.id == card.id }?.0.state == "rejected")
    }

    @Test func anUnknownOrBrokenLevelBlocksWrites() throws {   // qJwVc
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let url = folder.appendingPathComponent("catalog.json")
        for version in ["1", "x"] {
            try outsideEdit(folder, setMeta("format_version", .string(version)))
            let before = try Data(contentsOf: url)
            let r = try apply(c, folder, "update_item", .obj([("id", .str("item-0006")), ("set", .obj([("priority", .str("high"))]))]))
            #expect(r["ok"] == .bool(false))
            #expect(try Data(contentsOf: url) == before)
        }
        // The stamp repair is the one write a broken stamp accepts.
        let patch = JSONValue.array([.obj([("op", .str("replace")), ("path", .str("/meta/format_version")), ("value", .str("0"))])])
        let repair = TekaStore.OpBody(op: "migrate", args: JSONObject([(key: "patch", value: patch)]), actor: JSONObject([(key: "kind", value: .str("import"))]))
        try TekaStore(folder: folder).apply([repair], now: now)
        #expect(Teka.read(folder).catalog?["meta"]?["format_version"] == .str("0"))
    }

    @Test func aBrainClosureCarriesItsTimeAndSource() throws {   // qgAPA
        let c = commands()
        let (folder, _) = try readyBinder(c)
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("sprava/0.1")), (key: "model", value: .str("c1"))])
        let card = Proposal.make(title: "Done", actor: brain, ops: [body("complete", .obj([("id", .str("item-0006"))]))], now: now)
        try ProposalStore.save(card, in: folder)
        let line = try #require(try TekaStore(folder: folder).approve(card, now: now).first)
        #expect(line["args"]?["closed_at"] == line["at"])
        #expect(line["args"]?["source"] == .str("brain"))
    }
}

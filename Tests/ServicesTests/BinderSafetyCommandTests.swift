import BinderFormat
import BinderStore
import Darwin
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The binder's safety through the command table: linked or unreadable state, cards checked against what they
/// change, undo against newer changes, filings put back on failure, catalog levels and stamps. Invented data only.
@Suite(.serialized) struct BinderSafetyCommandTests: BinderCommandFixture {
    struct Boom: Error {}


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
        let priorDocuments = try #require(try JSONParser.parse(before).value["documents"]?.arrayValue)
        #expect(Teka.read(folder).catalog?["documents"]?.arrayValue?.count == priorDocuments.count + 1)
        // An op that cannot be rebuilt makes a card for a repair by hand, never a part of the batch.
        let lost = [body("set_disclosure", .obj([("disclosure", .str("title"))]))]
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

    // MARK: - Adoption

    /// A binder from an invented catalog, adopted through the commands; returns the cards listed afterwards.
    func adoptCatalog(_ c: Commands, name: String, _ text: String, manual: String? = nil) throws -> (URL, [JSONValue]) {
        let folder = try makeTeka(fixture: "lifeproj-v2-fresh", folderName: name) { f in
            try Data(text.utf8).write(to: f.appendingPathComponent("catalog.json"))
            if let manual { try Data(manual.utf8).write(to: f.appendingPathComponent("CLAUDE.md")) }
        }
        let r = try call(c, [("command", .str("adopt")), ("binder", .string(folder.path))])
        #expect(r["ok"] == .bool(true), "\(r)")
        return (folder, try cards(c, folder))
    }

    func cards(_ c: Commands, _ folder: URL) throws -> [JSONValue] {
        (try call(c, [("command", .str("proposals")), ("binder", .string(folder.path))])["proposals"]?.arrayValue ?? [])
            .filter { $0["state"] == .str("proposed") }
    }

    func approve(_ c: Commands, _ folder: URL, _ card: JSONValue, edits: JSONValue? = nil) throws -> JSONValue {
        var fields: [(String, JSONValue)] = [("command", .str("approve")), ("binder", .string(folder.path)), ("proposal", card["id"]!), ("digest", card["digest"]!)]
        if let edits { fields.append(("edits", edits)) }
        return try call(c, fields)
    }

    @Test func anItemThatBreaksTheRulesGetsARepairCard() throws {   // qgXO-
        let c = commands()
        let (folder, listed) = try adoptCatalog(c, name: "estate-sample", """
        {"meta": {"schema_version": 2, "name": "estate-sample"}, "documents": [], "processing_log": [],
         "open_items": [{"id": "estate-sample-2026-001", "title": "Ask the bank for the statement", "status": "open", "priority": "normal"}]}
        """)
        let repair = try #require(listed.first { $0["title"] == .str("Fill in what this item is missing") })
        #expect(listed.count == 1)   // no stamp while the item is dateless
        #expect(repair["editable"]?.arrayValue?.first?["index"] == .int(0))
        #expect(repair["notes"]?.arrayValue?.contains { $0.stringValue?.contains("fill in what is missing") == true } == true)
        let r = try approve(c, folder, repair, edits: .array([.obj([("index", .int(0)), ("due", .str("2026-12-01"))])]))
        #expect(r["ok"] == .bool(true), "\(r)")
        let stamp = try #require(try cards(c, folder).first { $0["title"] == .str("Stamp this binder as binder v0") })
        #expect(try approve(c, folder, stamp)["ok"] == .bool(true))
        #expect(Teka.read(folder).state == .ready, "\(Teka.read(folder).reasons)")
    }

    @Test func aLifeprojV1CatalogIsOfferedTheStamp() throws {   // qJwVl
        let c = commands()
        let (folder, listed) = try adoptCatalog(c, name: "tax-2026", """
        {"meta": {"schema_version": 1, "name": "tax-2026"}, "documents": [], "processing_log": [],
         "open_items": [{"id": "tax-2026-2026-001", "title": "Collect the donation receipts", "status": "open", "priority": "normal", "due": "2026-12-01"}]}
        """)
        let stamp = try #require(listed.first { $0["title"] == .str("Stamp this binder as binder v0") })
        #expect(stamp["lines"]?.arrayValue?.first?.stringValue?.contains("meta.schema_version = 2") == true)
        #expect(try approve(c, folder, stamp)["ok"] == .bool(true))
        #expect(Teka.read(folder).state == .ready, "\(Teka.read(folder).reasons)")
    }

    @Test func aPreLifeprojCatalogIsMigratedThenStamped() throws {   // qJwVl
        let c = commands()
        let (folder, listed) = try adoptCatalog(c, name: "tax-2026", """
        {"meta": {"name": "tax-2026"}, "documents": [], "processing_log": [],
         "open_items": [{"id": "tax-2026-2026-001", "title": "Collect the donation receipts", "status": "open", "priority": "normal", "due": "2026-12-01"}]}
        """)
        let first = try #require(listed.first { $0["lines"]?.arrayValue?.first?.stringValue?.contains("meta.schema_version = 1") == true })
        #expect(try approve(c, folder, first)["ok"] == .bool(true))
        #expect(Teka.read(folder).level == .lifeprojV1)
        let stamp = try #require(try cards(c, folder).first { $0["title"] == .str("Stamp this binder as binder v0") })
        #expect(try approve(c, folder, stamp)["ok"] == .bool(true))
        #expect(Teka.read(folder).state == .ready, "\(Teka.read(folder).reasons)")
    }
}

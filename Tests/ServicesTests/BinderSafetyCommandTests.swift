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
        let repair = try #require(listed.first { $0["title"] == .str("Keep this to-do with no deadline, or give it a date") })
        #expect(listed.count == 1)   // no stamp while the item is dateless
        #expect(repair["editable"]?.arrayValue?.first?["index"] == .int(0))
        #expect(repair["notes"]?.arrayValue?.contains { $0.stringValue?.contains("it has no date") == true } == true)
        let r = try approve(c, folder, repair, edits: .array([.obj([("index", .int(0)), ("due", .str("2026-12-01"))])]))
        #expect(r["ok"] == .bool(true), "\(r)")
        let stamp = try #require(try cards(c, folder).first { $0["title"] == .str("Stamp this binder as binder v0") })
        #expect(try approve(c, folder, stamp)["ok"] == .bool(true))
        #expect(Teka.read(folder).state == .ready, "\(Teka.read(folder).reasons)")
    }

    /// An invented catalog with `dateless` to-dos that lack only a date, one with a date, and one that lacks a priority.
    private func datelessCatalog(_ name: String, dateless: Int) -> String {
        let items = (1...dateless).map { n in
            #"{"id": "\#(name)-2026-\#(String(format: "%03d", n))", "title": "Invented chore \#(n)", "status": "open", "priority": "normal"}"#
        } + [#"{"id": "\#(name)-2026-900", "title": "Invented dated chore", "status": "open", "priority": "normal", "due": "2027-01-15"}"#,
             #"{"id": "\#(name)-2026-901", "title": "Invented chore with no priority", "status": "open", "due": "2027-01-16"}"#]
        return #"{"meta": {"schema_version": 2, "name": "\#(name)"}, "documents": [], "processing_log": [], "open_items": ["#
            + items.joined(separator: ", ") + "]}"
    }

    // #691: twenty to-dos with no date made twenty cards. They now share one, which keeps each with no deadline.
    @Test func toDosThatLackOnlyADateShareOneCard() throws {
        let c = commands()
        let (folder, listed) = try adoptCatalog(c, name: "house-sample", datelessCatalog("house-sample", dateless: 20))
        let shared = try #require(listed.first { $0["title"] == .str("Keep these 20 to-dos with no deadline, or give any of them a date") })
        #expect(listed.count == 2)   // the shared card, and the card of the item with no priority
        #expect(listed.contains { $0["title"] == .str("Fill in what this item is missing") })
        #expect(shared["editable"]?.arrayValue?.count == 20)
        // One of them gets a date on the card; the others are approved as offered.
        let r = try approve(c, folder, shared, edits: .array([.obj([("index", .int(4)), ("due", .str("2027-03-01"))])]))
        #expect(r["ok"] == .bool(true), "\(r)")
        let items = Teka.read(folder).items
        #expect(items.first { $0.idText == "house-sample-2026-005" }?.object?["due"] == .str("2027-03-01"))
        #expect(items.first { $0.idText == "house-sample-2026-005" }?.object?["no_deadline"] == nil)
        let others = items.filter { $0.idText < "house-sample-2026-021" && $0.idText != "house-sample-2026-005" }
        #expect(others.count == 19 && others.allSatisfy { $0.object?["no_deadline"] == .bool(true) && $0.object?["due"] == nil })
        #expect(items.first { $0.idText == "house-sample-2026-900" }?.object?["due"] == .str("2027-01-15"))
        // The other repair still stands between the binder and its stamp.
        #expect(try cards(c, folder).contains { $0["title"] == .str("Stamp this binder as binder v0") } == false)
    }

    @Test func approvingTheSharedCardAsOfferedLeadsToTheStamp() throws {
        let c = commands()
        let name = "garden-sample"
        let catalog = datelessCatalog(name, dateless: 3).replacingOccurrences(of: #""status": "open", "due": "2027-01-16""#,
                                                                              with: #""status": "open", "priority": "low", "due": "2027-01-16""#)
        let (folder, listed) = try adoptCatalog(c, name: name, catalog)
        #expect(listed.count == 1)
        #expect(try approve(c, folder, try #require(listed.first))["ok"] == .bool(true))
        let stamp = try #require(try cards(c, folder).first { $0["title"] == .str("Stamp this binder as binder v0") })
        #expect(try approve(c, folder, stamp)["ok"] == .bool(true))
        #expect(Teka.read(folder).state == .ready, "\(Teka.read(folder).reasons)")
    }

    // A waiting to-do with no date was refused its follow-up date at adoption, since that alone did not make it valid.
    // It lacks only a date all the same, so it joins the shared card, which gives it both.
    @Test func aWaitingToDoWithNoDateJoinsTheSharedCard() throws {
        let c = commands()
        let name = "shed-sample"
        let catalog = """
        {"meta": {"schema_version": 2, "name": "\(name)"}, "documents": [], "processing_log": [],
         "open_items": [{"id": "\(name)-2026-001", "title": "Invented chore", "status": "open", "priority": "normal"},
                        {"id": "\(name)-2026-002", "title": "Invented wait", "status": "waiting", "priority": "normal", "waiting_on": "an invented office"},
                        {"id": "\(name)-2026-003", "title": "Invented repeat", "status": "open", "priority": "normal", "recurrence": {"freq": "monthly", "day": 5}},
                        {"id": "\(name)-2026-004", "title": "Invented wait with an unreadable follow-up", "status": "waiting", "priority": "normal",
                         "waiting_on": "an invented office", "follow_up_at": "tomorrow"}]}
        """
        let (folder, listed) = try adoptCatalog(c, name: name, catalog)
        let shared = try #require(listed.first { $0["title"] == .str("Keep these 2 to-dos with no deadline, or give any of them a date") })
        // A repeat needs a real date, and a follow-up date that cannot be read is the person's to settle: each keeps
        // a card of its own, so the shared card can be approved as offered.
        #expect(listed.count == 3 && listed.filter { $0["title"] == .str("Fill in what this item is missing") }.count == 2)
        #expect(try approve(c, folder, shared)["ok"] == .bool(true))
        let wait = try #require(Teka.read(folder).items.first { $0.idText == "\(name)-2026-002" }?.object)
        #expect(wait["no_deadline"] == .bool(true) && wait["follow_up_at"]?.stringValue != nil)
        #expect(wait["derived"] == .array([.str("follow_up_at")]))
        // Only the repeat still breaks a rule.
        #expect(Set(Teka.read(folder).findings.map(\.location)) == ["open_items[2]", "open_items[3]"])
    }

    // A card holds at most a hundred of them, so a binder with hundreds still lists its cards.
    @Test func hundredsOfDatelessToDosAreSplitAcrossCardsThatCanBeListed() throws {
        let c = commands()
        let (_, listed) = try adoptCatalog(c, name: "attic-sample", datelessCatalog("attic-sample", dateless: 250))
        let titles = listed.compactMap { $0["title"]?.stringValue }.filter { $0.hasPrefix("Keep these") }
        #expect(titles == ["Keep these 100 to-dos with no deadline, or give any of them a date (part 1 of 3)",
                           "Keep these 100 to-dos with no deadline, or give any of them a date (part 2 of 3)",
                           "Keep these 50 to-dos with no deadline, or give any of them a date (part 3 of 3)"])
        #expect(listed.count == 4)
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

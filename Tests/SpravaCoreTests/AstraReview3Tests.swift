import Darwin
import Foundation
import Testing
@testable import SpravaCore

/// Regressions from the third adversarial review of increment 1 (closed items under the title ratchet, rewrites
/// of tampered cards, the clerk and the disclosure ratchet, readings that could not be written, waiting parties on
/// repair cards, failed state backups, and file names in the capture journal). Invented data only.
@Suite(.serialized) struct AstraReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra3-\(label)-\(UUID().uuidString)")
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
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

    /// Rewrites a stored card's file the way another program would, keeping it valid JSON.
    func tamper(_ id: String, in folder: URL, _ change: (inout JSONObject) -> Void) throws -> Data {
        let url = ProposalStore.dir(folder).appendingPathComponent("\(id).json")
        var raw = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        change(&raw)
        let data = Data(JSONWriter.pretty(.object(raw)).utf8)
        try data.write(to: url)
        return data
    }

    /// A card's first add_item retitled, as a tampering program might.
    func retitleFirstItem(_ raw: inout JSONObject) {
        var ops = raw["ops"]?.arrayValue ?? []
        guard case .object(var op)? = ops.first, var args = op["args"]?.objectValue, var item = args["item"]?.objectValue else { return }
        item.set("title", .str("Invented tampered task"))
        args.set("item", .object(item))
        op.set("args", .object(args))
        ops[0] = .object(op)
        raw.set("ops", .array(ops))
    }

    // MARK: - 1. A closed item keeps the hub title the person confirmed

    @Test func aClosedItemKeepsItsConfirmedHubTitleAndRedaction() throws {
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
        #expect(done.contains { $0["title"] == .str("Invented paperwork") }, "\(done)")
        #expect(!after.contains { $0["title"]?.stringValue == natural }, "\(after)")
        // The redacted one goes out as it was published: same id, no title.
        #expect(done.contains { $0["id"] == redactedID && $0["title"] == .str("[redacted]") }, "\(done)")
    }

    // MARK: - 2. A stored card changed by another program is never trusted again by a rewrite

    @Test func aRewriteRefusesACardChangedOutside() throws {
        let c = Commands(support: temp("support"), deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t"))])
        let item = JSONValue.obj([("id", .str("$new:1")), ("title", .str("Invented task")), ("status", .str("open")),
                                  ("priority", .str("normal")), ("no_deadline", .bool(true))])
        let card = Proposal.make(title: "Invented card", actor: actor,
                                 ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", item)]))])],
                                 provenance: JSONObject(), now: now)
        try ProposalStore.save(card, in: folder)
        try c.trustProposals([card.id], in: folder)

        // As Sprava wrote it: rewritten and trusted.
        try c.rewriteTrusted(card.id, in: folder) { p in
            var raw = p.raw
            raw.set("title", .str("Invented card, annotated"))
            return Proposal(raw: raw)
        }
        #expect(c.isTrusted(card.id, in: folder))

        // Changed outside: left as it is, unverified.
        let changed = try tamper(card.id, in: folder, retitleFirstItem)
        #expect(throws: ProposalStore.Tampered.self) { try c.rewriteTrusted(card.id, in: folder) { $0 } }
        #expect(throws: ProposalStore.Tampered.self) { try c.loadTrusted(card.id, in: folder) }
        #expect(try Data(contentsOf: ProposalStore.dir(folder).appendingPathComponent("\(card.id).json")) == changed)
        #expect(!c.isTrusted(card.id, in: folder))
    }

    /// A typed note the way the app sends it: the event, then its notice.
    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
    }

    func journal(_ s: PSetup) -> String { (try? String(contentsOf: s.inbox.journalURL, encoding: .utf8)) ?? "" }

    @Test func annotatingATamperedCodeBuiltCardLeavesItUnverified() async throws {
        let s = try pSetup()
        try note(s, "File the estate inventory with the notary", hint: "estate-example")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let work = try #require(s.inbox.nextForClerk())
        #expect(work.tier0Binder != nil)
        #expect(s.commands.isTrusted(work.tier0, in: s.folder))
        let changed = try tamper(work.tier0, in: s.folder, retitleFirstItem)

        let filing = [FilingBinder(name: "estate-example", description: "Estate: notary, inventory", folder: s.folder,
                                   words: FilingBinder.significantWords("estate inventory notary"),
                                   openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))]
        let model = RecordingModel([.obj([("items", .array([item("File the estate inventory", "File the inventory", "file")]))])])
        model.dup = ("estate-example-2026-007", "same")
        let interp = await Clerk(model: model).read(work.event, filing: filing, hint: nil, now: pNow)
        let out = s.inbox.commitClerk(work, interp, filing: filing, rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(!out.replaced)
        // Not annotated, not trusted again: it can only be rejected.
        #expect(try Data(contentsOf: ProposalStore.dir(s.folder).appendingPathComponent("\(work.tier0).json")) == changed)
        #expect(!s.commands.isTrusted(work.tier0, in: s.folder))
        #expect(journal(s).contains("card_changed_outside"))
    }

    @Test func aPrivacyRaiseNeverTrustsATamperedCard() throws {
        let s = try pSetup()
        let adapter = "11111111-2222-4333-8444-5555555555c1"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "T1", revision: "rev1", text: "Meet the invented notary about the deed")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let unfiled = try #require(s.inbox.unfiled().first)
        try s.inbox.file(unfiled.id, into: s.folder, commands: s.commands)
        let changed = try tamper(unfiled.id, in: s.folder, retitleFirstItem)

        let raise = try pEvent(s, device: adapter, app: "adapter", ref: "T1", revision: "rev1", text: "Meet the invented notary about the deed") {
            $0.set("sensitivity", .str("private")); $0.set("supersedes", .string(first))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(try Data(contentsOf: ProposalStore.dir(s.folder).appendingPathComponent("\(unfiled.id).json")) == changed)
        #expect(!s.commands.isTrusted(unfiled.id, in: s.folder))
        // Nothing to retry: the card can never be approved.
        #expect(try s.inbox.readState().raises?[raise] == nil)
        #expect(journal(s).contains("card_changed_outside"))
    }

    @Test func theDocumentReadingIsNeverBuiltOnATamperedCard() async throws {
        let support = temp("support")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try call(commands, [("command", .str("adopt")), ("binder", .string(folder.path))])
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("INVENTED NOTICE. The invented levy of $120.00 is due November 1, 2026.".utf8)
            .write(to: folder.appendingPathComponent("intake/levy.txt"))
        let watcher = IntakeWatcher(support: support)
        let rows = [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))]
        for _ in 0..<2 {
            let prepared = watcher.prepare(binders: rows, deviceID: "dev", reader: .inProcess)
            _ = watcher.scan(binders: rows, commands: commands, now: now, prepared: prepared, requireReading: true)
        }
        let entry = try #require(watcher.nextForReading())
        _ = try tamper(entry.card, in: folder) { $0.set("title", .str("Invented tampered card")) }
        let binder = FilingBinder(name: Teka.read(folder).name, description: "", folder: folder,
                                  openItems: FilingBinder.candidates(catalog: Teka.read(folder).catalog))
        let doc = await Clerk(model: RecordingModel([])).readDocument(entry.reading, name: entry.name, binder: binder, now: now)
        let out = watcher.commitReading(entry, doc, commands: commands, now: now)
        #expect(out.cardChanged && !out.replaced)
        let open = ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" }
        #expect(open.map(\.id) == [entry.card])
        #expect(!commands.isTrusted(entry.card, in: folder))
    }

    // MARK: - 3. The clerk and capture routing read disclosure through the ratchet

    @Test func aDisclosureRaisedOutsideNeverNamesTheBinderToTheClerk() throws {
        let s = try pSetup()
        let folder = try makeTeka(fixture: "sprava-v0", folderName: "estate-secret") { f in
            let url = f.appendingPathComponent("catalog.json")
            var o = try #require(try JSONParser.parse(Data(contentsOf: url)).value.objectValue)
            var meta = try #require(o["meta"]?.objectValue)
            meta.set("name", .str("estate-secret"))
            meta.set("disclosure", .str("none"))
            o.set("meta", .object(meta))
            try Data(JSONWriter.pretty(.object(o)).utf8).write(to: url)
        }
        _ = try call(s.commands, [("command", .str("adopt")), ("binder", .string(folder.path))])
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: pNow) }
        try FilingList(support: s.support).set(folder, .init(description: "Inventory and notary paperwork", filing: true))
        func row() -> ShelfRow { ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder)) }
        let label = try #require(FilingList(support: s.support).binders(rows: [row()], deviceID: "dev").first?.name)
        #expect(label.hasPrefix("binder-"))

        // Raised to full outside Sprava, no privacy card approved.
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(Data(contentsOf: url)).value.objectValue)
        var meta = try #require(catalog["meta"]?.objectValue)
        meta.set("disclosure", .str("full"))
        catalog.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        #expect(PrivacyRatchet.disclosure(row()) == "none")

        #expect(FilingList(support: s.support).binders(rows: [row()], deviceID: "dev").map(\.name) == [label])
        #expect(FilingList.name(of: row()) == label)
        // A note naming it is not filed into it either.
        try note(s, "File the estate inventory with the notary", hint: "estate-secret")
        _ = s.inbox.sweep(binders: [row()], commands: s.commands, now: pNow)
        #expect(!ProposalStore.list(in: folder).contains { $0.0.state == "proposed" })
        #expect(s.inbox.unfiled().count == 1)
    }

    // MARK: - 4. A reading that could not be written is made again

    @Test func aReadingThatCouldNotBeWrittenIsMadeOnALaterScan() throws {
        let support = temp("support")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try call(commands, [("command", .str("adopt")), ("binder", .string(folder.path))])
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("INVENTED NOTICE. The invented levy of $120.00 is due November 1, 2026.".utf8)
            .write(to: folder.appendingPathComponent("intake/levy.txt"))
        let watcher = IntakeWatcher(support: support)
        let rows = [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))]
        @discardableResult
        func scan() -> IntakeWatcher.ScanResult {
            let prepared = watcher.prepare(binders: rows, deviceID: "dev", reader: .inProcess)
            return watcher.scan(binders: rows, commands: commands, now: now, prepared: prepared, requireReading: true)
        }
        func seen() throws -> IntakeWatcher.Seen? { try watcher.load()[folder.standardizedFileURL.path]?["levy.txt"] }
        scan()   // first sight: waits to hold still

        let readings = IntakeReadings(support: support)
        try AtomicFile.makePrivateFolder(readings.dir)
        chmod(readings.dir.path, 0o500)
        defer { chmod(readings.dir.path, 0o700) }
        // The card is made all the same, and the cursor says its reading is missing.
        #expect(scan().carded == 1)
        let card = try #require(try seen()?.card)
        #expect(commands.isTrusted(card, in: folder))
        #expect(readings.forCard(card) == nil)
        #expect(try seen()?.readingMissing == true)
        // Still unwritable: still missing, never carded twice.
        #expect(scan().carded == 0)
        #expect(try seen()?.readingMissing == true)

        chmod(readings.dir.path, 0o700)
        scan()
        #expect(try seen()?.card == card)
        #expect(try seen()?.readingMissing == nil)
        #expect(readings.forCard(card)?.sha256 != nil)
        #expect(watcher.nextForReading()?.card == card)
    }

    // MARK: - 5. A repair card takes the waiting party the person writes

    @Test func aRepairCardTakesAWaitingParty() throws {
        let op = JSONObject([(key: "op", value: .str("update_item")),
                             (key: "args", value: .obj([("id", .str("item-0004")), ("set", .obj([("status", .str("waiting"))])),
                                                        ("unset", .array([.str("waiting_on")]))]))])
        let edited = try CardEdits.apply([.obj([("index", .int(0)), ("waiting_on", .str("  Invented Property Office "))])], to: [op])
        #expect(edited[0]["args"]?["set"]?["waiting_on"] == .str("Invented Property Office"))
        #expect(edited[0]["args"]?["unset"] == nil)
        #expect(throws: CardEdits.Failure.self) { try CardEdits.apply([.obj([("index", .int(0)), ("waiting_on", .str("  "))])], to: [op]) }
        #expect(throws: CardEdits.Failure.self) {
            try CardEdits.apply([.obj([("index", .int(0)), ("waiting_on", .string(String(repeating: "x", count: 201)))])], to: [op])
        }
    }

    // MARK: - 6. A failed backup of Sprava's own state is a failure

    @Test func aFailedStateBackupAndRetentionAreCountedAndStayDue() throws {
        let support = temp("support")
        // No restic here: every restic run fails.
        let b = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: nil, uploadCheck: { _ in .notInICloud })
        var s = Backup.Settings()
        s.primary = temp("mirror").path
        try b.save(s)
        #expect(b.isConfigured)
        let m = b.maintain(rows: [], deviceID: "dev", now: now)
        #expect(!m.stateSnapshot && !m.retention && !m.checked)
        #expect(m.failed == 3)
        #expect(m.failedParts == ["state_snapshot", "retention", "check"])
        let st = try b.state()
        #expect(st.stateSnapshotAt == nil && st.lastForget == nil && st.lastCheck == nil)
        // Due again on the next run.
        #expect(b.maintain(rows: [], deviceID: "dev", now: now.addingTimeInterval(60)).failedParts == ["state_snapshot", "retention", "check"])
    }

    // MARK: - 7. A malformed capture file name never reaches the journal

    @Test func aMalformedCaptureFileNameIsNotJournaled() throws {
        let s = try pSetup()
        let device = s.producer.root.appendingPathComponent(pDevice)
        try AtomicFile.makePrivateFolder(device)
        try Data(#"{"format": "sprava-capture-event"}"#.utf8).write(to: device.appendingPathComponent("Confidential appointment.json"))
        let r = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(r.quarantined == 1)
        let text = journal(s)
        #expect(text.contains("quarantined") && text.contains("invalid-name"), "\(text)")
        #expect(!text.contains("Confidential"), "\(text)")
    }
}

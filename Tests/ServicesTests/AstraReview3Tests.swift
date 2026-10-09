import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

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

    // MARK: - 1. A closed item never shows a title the person did not confirm

    @Test func aClosedItemShowsNoTitleUnderItsPublishedID() throws {
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
        // A closed item goes out once with no title at all (binder-v0 §8.2 publishes none for a closure), under the
        // id it was published with, so the hub closes the task it already shows.
        #expect(done.allSatisfy { $0["title"] == .str("[closed]") }, "\(done)")
        #expect(!after.contains { $0["title"]?.stringValue == natural }, "\(after)")
        #expect(done.contains { $0["id"] == redactedID }, "\(done)")
    }

    /// A typed note the way the app sends it: the event, then its notice.
    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
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
        #expect(try FilingList(support: s.support).name(of: row()) == label)
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
}

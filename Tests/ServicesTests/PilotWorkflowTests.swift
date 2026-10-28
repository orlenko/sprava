import Backup
import BinderFormat
import BinderStore
import Foundation
@testable import Services
import Shelf
import SpravaKit
import Testing

/// `scripts/test.sh` points the lifeproj registry at a missing file; without it `create_binder` would read the real one.
private let pilotIsolated = !(ProcessInfo.processInfo.environment["CMIRROR_CONFIG"] ?? "").isEmpty
private let pilotHasRestic = Restic.locate() != nil

/// The pilot's workflows end to end, through the command table and the runtime's jobs as the app drives them: a tax year
/// for next year kept private and traceable through a dated item, its completion and Undo; a condo board that files a
/// dropped document and waits on a follow-up; and that binder backed up to a real restic repository and restored.
/// Invented binders, temporary folders and an invented key only; dates are relative to today.
///
/// Not exercised here: the app's dialogs and windows (NSAlert layout, the installed UI), the XPC connection, a real
/// provider or brain, the Keychain, real iCloud or a second disk (the upload and location checks are stand-ins), the
/// sandboxed reader (documents are read in process), and background registration.
@Suite(.serialized, .enabled(if: pilotIsolated)) struct PilotWorkflowTests {

    let now = Date()
    let base: URL
    let commands: Commands
    var support: URL { commands.support }
    var today: CalendarDate { CalendarDate.today(now: now) }

    init() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-pilot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("binders"), withIntermediateDirectories: true)
        commands = Commands(support: base.appendingPathComponent("support"), deviceID: "dev")
    }

    @discardableResult
    func ok(_ fields: [(String, JSONValue)]) throws -> JSONValue {
        let r = try JSONParser.parse(commands.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
        #expect(r["ok"] == .bool(true), "\(fields.first?.1 ?? .null): \(r)")
        return r
    }

    func create(_ template: String, year: Int) throws -> URL {
        let r = try ok([("command", .str("create_binder")), ("parent", .string(base.appendingPathComponent("binders").path)),
                        ("name", .str("")), ("template", .string(template)), ("year", .int(year))])
        return URL(fileURLWithPath: try #require(r["binder"]?.stringValue), isDirectory: true)
    }

    /// Approves every card waiting in the binder, as the person would from the binder's page.
    func approveAll(_ folder: URL, documentFolder: String? = nil) throws {
        let listed = try ok([("command", .str("proposals")), ("binder", .string(folder.path))])
        let cards = (listed["proposals"]?.arrayValue ?? []).filter { $0["state"] == .str("proposed") }
        #expect(!cards.isEmpty)
        for card in cards {
            var fields: [(String, JSONValue)] = [("command", .str("approve")), ("binder", .string(folder.path)),
                                                 ("proposal", card["id"] ?? .null), ("digest", card["digest"] ?? .null)]
            if let documentFolder { fields.append(("document_folder", .string(documentFolder))) }
            try ok(fields)
        }
    }

    func apply(_ folder: URL, _ op: String, _ args: [(String, JSONValue)]) throws -> String {
        let r = try ok([("command", .str("apply")), ("binder", .string(folder.path)), ("op", .string(op)), ("args", .obj(args))])
        return try #require(r["op"]?.stringValue)
    }

    /// Adds an item the person typed; returns its minted id.
    func add(_ folder: URL, _ title: String, due: CalendarDate? = nil) throws -> JSONValue {
        var item: [(String, JSONValue)] = [("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")),
                                           ("priority", .str("normal"))]
        item.append(due.map { ("due", .string($0.description)) } ?? ("no_deadline", .bool(true)))
        _ = try apply(folder, "add_item", [("item", .obj(item))])
        return try #require(Teka.read(folder).items.first { $0.title == title }?.raw["id"])
    }

    func item(_ folder: URL, _ id: JSONValue) -> JSONObject? {
        Teka.read(folder).catalog?["open_items"]?.arrayValue?.first { $0["id"] == id }?.objectValue
    }

    /// The binder stays private, and its catalog is exactly what its op log replays to: every change is traceable.
    func privateAndTraceable(_ folder: URL) throws {
        let teka = Teka.read(folder)
        #expect(teka.state == .ready, "\(teka.reasons)")
        #expect(teka.catalog?["meta"]?["disclosure"] == .str("none"))
        let settings = try ok([("command", .str("binder_settings")), ("binder", .string(folder.path))])
        #expect(settings["filing"] == .bool(false))
        let ops = try TekaStore(folder: folder).readOpLog().ops
        #expect(try Replay.run(ops) == teka.catalog)
    }

    @Test func aTaxYearForNextYearStaysPrivateThroughADatedItemItsCompletionAndUndo() throws {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let year = gregorian.component(.year, from: now) + 1
        let folder = try create("tax-year", year: year)
        #expect(folder.lastPathComponent == "tax-\(year)")
        let settings = try ok([("command", .str("binder_settings")), ("binder", .string(folder.path))])
        #expect(settings["description"]?.stringValue?.hasPrefix("Tax year \(year)") == true)
        try approveAll(folder)
        let checklist = Teka.read(folder).items
        #expect(checklist.count == BinderTemplate.taxYear.checklist.count && checklist.allSatisfy(\.hasNoDeadline))

        // A date the person chose, never a statutory one.
        let due = today.adding(days: 30)
        let id = try add(folder, "Book a review with the invented bookkeeper", due: due)
        #expect(item(folder, id)?["due"] == .string(due.description))
        let completed = try apply(folder, "complete", [("id", id)])
        #expect(item(folder, id) == nil)
        let undone = try ok([("command", .str("undo")), ("binder", .string(folder.path)), ("op_id", .string(completed))])
        #expect(undone["ok"] == .bool(true))
        // Reopened as it was, with its date, under a new id the log ties to the old one (binder-v0 §6.10).
        let reopened = try #require(Teka.read(folder).items.first { $0.title == "Book a review with the invented bookkeeper" }?.raw.objectValue)
        #expect(reopened["status"] == .str("open") && reopened["due"] == .string(due.description))
        let log = Teka.read(folder).catalog?["processing_log"]?.arrayValue ?? []
        #expect(log.contains { $0["reopened_from"] == id && $0["item"] == reopened["id"] }, "\(log.suffix(2))")
        let ops = try TekaStore(folder: folder).readOpLog().ops
        let undo = try #require(ops.last)
        #expect(undo["compensates"] == .string(completed) && undo["actor"]?["kind"] == .str("user"))
        try privateAndTraceable(folder)
    }

    /// A condo-board binder with its checklist approved and a dropped document filed under `meetings/`.
    func condoWithMinutes() throws -> (folder: URL, name: String, bytes: Data) {
        let folder = try create("condo-board", year: gregorianYear())
        #expect(folder.lastPathComponent == "condo-board")
        try approveAll(folder)
        #expect(Teka.read(folder).items.count == BinderTemplate.condoBoard.checklist.count)

        // Dropped on the binder as the app does: through the runtime's drop command, then the intake job.
        let name = "Invented board minutes.txt"
        let bytes = Data("Minutes of an invented board meeting. Motion to collect two roof quotes carried.\n".utf8)
        let source = base.appendingPathComponent("dropped-\(UUID().uuidString)")
        try bytes.write(to: source)
        let request = JSONWriter.compact(.obj([("command", .str("intake_drop")), ("binder", .string(folder.path)), ("name", .string(name))]))
        let shelf = ShelfStore(supportDirectory: support)
        let dropped = try JSONParser.parse(commands.dropIntake(request, file: try FileHandle(forReadingFrom: source), listed: { picked in
            try shelf.readFolders().contains { $0.standardizedFileURL.path == picked.standardizedFileURL.path }
        })).value
        #expect(dropped["ok"] == .bool(true), "\(dropped)")
        let context = JobContext(support: support, commands: commands, rows: { Shelf.rows(registry: nil, picked: [folder]) },
                                 commandQueue: nil, log: { _ in })
        // The first scan sees the file; the next, finding it held still, reads it and makes its card.
        for _ in 0..<2 { #expect(IntakeJob.run(context, reader: .inProcess, now: now) == .ok) }
        let cards = ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" }
        #expect(cards.count == 1 && cards.first?.ops.contains { $0["op"] == .str("file_document") } == true, "\(cards.map(\.title))")
        try approveAll(folder, documentFolder: "meetings")
        return (folder, name, bytes)
    }

    func gregorianYear() -> Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        return gregorian.component(.year, from: now)
    }

    @Test func aCondoBoardFilesADroppedDocumentAndWaitsOnAFollowUp() throws {
        let (folder, name, bytes) = try condoWithMinutes()
        // The original bytes, filed where the person chose, recorded in the catalog, gone from intake/.
        #expect(try Data(contentsOf: folder.appendingPathComponent("meetings/\(name)")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("intake/\(name)").path))
        let documents = Teka.read(folder).catalog?["documents"]?.arrayValue ?? []
        #expect(documents.contains { $0["path"] == .string("meetings/\(name)") }, "\(documents)")

        let followUp = today.adding(days: 7)
        let id = try add(folder, "Get a second quote for the invented roof repair")
        _ = try apply(folder, "set_status", [("id", id), ("status", .str("waiting")), ("waiting_on", .str("the invented contractor")),
                                             ("follow_up_at", .string(followUp.description))])
        let waiting = try #require(item(folder, id))
        #expect(waiting["status"] == .str("waiting") && waiting["waiting_on"] == .str("the invented contractor"))
        #expect(waiting["follow_up_at"] == .string(followUp.description))
        try privateAndTraceable(folder)
    }

    /// A restore drill through the backup job, then a copy restored by hand from the same repository: the document's bytes
    /// and the catalog come back as they are in the binder.
    @Test(.enabled(if: pilotHasRestic)) func theCondoBinderRestoresFromARealResticRepository() throws {
        let (folder, name, bytes) = try condoWithMinutes()
        let key = "INVENTED-PILOT-KEY-AAAAA-BBBBB"
        let mirror = base.appendingPathComponent("mirror/Sprava Backup", isDirectory: true)
        let backup = Backup(support: support, key: key, uploadCheck: { _ in .uploaded }, hubSpool: base.appendingPathComponent("spool"))
        try backup.setUp(primary: mirror, iCloudKeychain: false)
        try ok([("command", .str("backup_request")), ("kind", .str("drill")), ("binder", .string(folder.path))])
        let context = JobContext(support: support, commands: commands, rows: { Shelf.rows(registry: nil, picked: [folder]) },
                                 commandQueue: nil, log: { _ in })
        #expect(BackupJob.run(context, backup: backup, now: now) { _, _, _ in } == .ok)
        let request = try #require(try BackupRequests(support: support).all().first)
        #expect(request.state == "done" && request.message == "the restore drill passed", "\(request.state) \(request.message ?? "")")

        let restic = Restic(binary: try #require(Restic.locate()), repository: mirror, key: key, support: support)
        // The job also snapshots Sprava's own state; the binder's snapshots carry its tag.
        let snapshot = try #require(try restic.snapshots(tag: "binder:\(try Backup.backupID(folder))").last)
        let target = base.appendingPathComponent("restored", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try restic.restore(snapshot.id, into: target)
        // Sprava backs a binder up from inside its folder, so the copy is the target itself.
        let restored = target
        #expect(try Data(contentsOf: restored.appendingPathComponent("meetings/\(name)")) == bytes)
        #expect(Teka.read(restored).catalog == Teka.read(folder).catalog)
    }
}

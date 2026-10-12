import BinderFormat
import BinderStore
import Capture
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The clerk's reading of an intake file, through the command table: never built on a card another program
/// changed, and made on a later scan when it could not be written. Invented data only.
@Suite(.serialized) struct IntakeReadingRecoveryTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func temp(_ label: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-reading-\(label)-\(UUID().uuidString)")
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
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

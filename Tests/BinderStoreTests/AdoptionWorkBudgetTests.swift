import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct AdoptionWorkBudgetTests {
    /// A waiting item with no follow-up date: the one mechanical fix adoption gives it is that date.
    private func waiting(_ n: Int) -> JSONValue {
        .obj([("id", .str("invented-\(n)")), ("title", .str("Invented wait \(n)")), ("status", .str("waiting")), ("priority", .str("normal")),
              ("due", .str("2027-01-15")), ("waiting_on", .str("an invented office"))])
    }

    private func write(_ folder: URL, items: [JSONValue], documents: Int = 0, padding: Int = 0) throws -> Data {
        let file = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: file)).value.objectValue)
        catalog.set("open_items", .array(items))
        catalog.set("documents", .array((0..<documents).map { n in
            .obj([("id", .str("doc-\(n)")), ("title", .str("Invented notice \(n)")), ("path", .str("notices/invented-\(n).md")), ("date", .str("2026-05-01"))])
        }))
        if padding > 0 { catalog.set("invented_padding", .str(String(repeating: "x", count: padding))) }
        let data = Data(JSONWriter.compact(.object(catalog)).utf8)
        try data.write(to: file)
        return data
    }

    // #688: the bound counted every row, so no binder with more than a hundred records could be adopted.
    @Test func aBinderWithHundredsOfRecordsIsAdoptedInOneWrite() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let plain = (0..<80).map { n in
            JSONValue.obj([("id", .str("plain-\(n)")), ("title", .str("Invented task \(n)")), ("status", .str("open")), ("priority", .str("normal")),
                           ("due", .str("2027-02-01"))])
        }
        _ = try write(folder, items: plain + (0..<40).map(waiting), documents: 400)
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        #expect(result.mechanical.count == 40)
        // One write: the forty fixes are one batch, and the untouched items made no op.
        #expect(Set(result.mechanical.compactMap { $0["batch"]?.stringValue }).count == 1)
        #expect(result.mechanical.allSatisfy { $0["batch_size"] == .int(40) })
        let teka = Teka.read(folder)
        #expect(teka.items.filter { $0.idText.hasPrefix("invented-") }.allSatisfy { $0.followUpAt != nil })
        #expect(teka.catalog?["documents"]?.arrayValue?.count == 400)
        #expect(!FileManager.default.fileExists(atPath: Adoption.unfinishedMarker(folder).path))
    }

    // A fix the guard refuses leaves the others applied; its item goes to the person on a repair card.
    @Test func aRefusedFixDoesNotHoldBackTheOthers() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        // No one is named to wait on, so the follow-up date alone does not make this item valid.
        let broken = JSONValue.obj([("id", .str("broken-1")), ("title", .str("Invented wait with no party")), ("status", .str("waiting")),
                                    ("priority", .str("normal")), ("due", .str("2027-01-15"))])
        _ = try write(folder, items: [waiting(1), broken, waiting(2)])
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        #expect(Set(result.mechanical.compactMap { $0["args"]?["id"]?.stringValue }) == ["invented-1", "invented-2"])
        #expect(result.proposals.contains { $0.raw["provenance"]?["repair"] != nil && $0.ops.first?["args"]?["id"] == .str("broken-1") })
    }

    /// An item left at done in the open list: adoption closes it on a card, and the stamp's card is checked with every such closure.
    private func done(_ n: Int) -> JSONValue {
        .obj([("id", .str("done-\(n)")), ("title", .str("Invented finished task \(n)")), ("status", .str("done")), ("priority", .str("normal")),
              ("due", .str("2026-03-01"))])
    }

    /// An item with no priority: no fix and no closure, only a repair card, whose saving reads the whole catalog.
    private func repairOnly(_ n: Int) -> JSONValue {
        .obj([("id", .str("r-\(n)")), ("title", .str("Invented task \(n)")), ("status", .str("open")), ("due", .str("2027-02-01"))])
    }

    // Each case is past one bound: the catalog's bytes; then open items times bytes, where the items need a fix, a
    // closure, or only a repair card (the three review rounds of #688's fix: each found a kind of item the bound did
    // not count, so every open item counts now); then every record's count.
    @Test(arguments: 0..<5) func excessiveCatalogWorkRefusesBeforeAnyWrite(bound: Int) throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("catalog.json")
        let before: Data
        switch bound {
        case 0: before = try write(folder, items: [waiting(0)], padding: Adoption.maxCatalogBytes)
        case 1: before = try write(folder, items: (0..<400).map(waiting), padding: 400_000)
        case 2: before = try write(folder, items: (0..<400).map(done), padding: 400_000)
        case 3: before = try write(folder, items: (0..<400).map(repairOnly), padding: 400_000)
        default: before = try write(folder, items: [], documents: Adoption.maxRows + 1)
        }
        if (1...3).contains(bound) { #expect(400 * before.count > Adoption.maxItemWork) }
        #expect(throws: TekaStore.Refused.self) {
            _ = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        }
        #expect(Owner.device(of: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func historyPastItsBoundIsRefusedAndPreserved() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent(".sprava")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("ops.ndjson")
        let before = Data(repeating: 32, count: Adoption.maxHistoryBytes + 1)
        try before.write(to: history)
        #expect(throws: TekaStore.Refused.self) {
            _ = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        }
        #expect(Owner.device(of: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("adoption-unfinished").path))
        #expect(try Data(contentsOf: history) == before)
    }

    @Test func aStartedAdoptionCanResumeAfterItsSnapshotGrowsHistory() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: file)).value.objectValue)
        catalog.set("invented_padding", .str(String(repeating: "x", count: 300_000)))
        let before = Data(JSONWriter.compact(.object(catalog)).utf8)
        try before.write(to: file)
        try Adoption.requireBoundedWork(folder)
        let store = TekaStore(folder: folder)
        try store.adopt(survey: Adoption.survey(folder, inRegistry: false),
                        owner: JSONObject([(key: "device", value: .str("invented-device"))]))
        try Data().write(to: Adoption.unfinishedMarker(folder))
        _ = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        #expect(!FileManager.default.fileExists(atPath: Adoption.unfinishedMarker(folder).path))
        #expect(try store.readOpLog().ops.filter { $0["op"] == .str("import_snapshot") }.count == 1)
        #expect(try Data(contentsOf: folder.appendingPathComponent(".sprava/adopted/catalog.json")) == before)
    }

    @Test func aLinkedSpravaDirectoryIsRefusedBeforeBudgetReads() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-outside-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let history = outside.appendingPathComponent("ops.ndjson")
        let bytes = Data("{\"invented\":true}\n".utf8)
        try bytes.write(to: history)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(".sprava"), withDestinationURL: outside)
        #expect(throws: TekaStore.Refused.self) { try Adoption.requireBoundedWork(folder) }
        #expect(try Data(contentsOf: history) == bytes)
        #expect(!FileManager.default.fileExists(atPath: outside.appendingPathComponent("owner.json").path))
    }
}

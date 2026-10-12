import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct AdoptionWorkBudgetTests {
    @Test(arguments: [false, true]) func excessiveCatalogWorkRefusesBeforeAnyWrite(padded: Bool) throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONParser.parse(try Data(contentsOf: file)).value.objectValue)
        let item = try #require(catalog["open_items"]?.arrayValue?.first?.objectValue)
        catalog.set("open_items", .array((0..<(padded ? 20 : 101)).map { n in
            var copy = item; copy.set("id", .str("invented-\(n)")); return .object(copy)
        }))
        if padded { catalog.set("invented_padding", .str(String(repeating: "x", count: 300_000))) }
        let before = Data(JSONWriter.compact(.object(catalog)).utf8)
        try before.write(to: file)
        #expect(throws: TekaStore.Refused.self) {
            _ = try Adoption.adopt(folder, inRegistry: false, deviceID: "invented-device", today: today)
        }
        #expect(Owner.device(of: folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path))
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func historyBytesShareTheRepeatedReadBudgetAndArePreserved() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        defer { try? FileManager.default.removeItem(at: folder) }
        let directory = folder.appendingPathComponent(".sprava")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let history = directory.appendingPathComponent("ops.ndjson")
        let before = Data(repeating: 32, count: 1 << 20)
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

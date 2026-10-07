import Foundation
import Testing
@testable import SpravaCore

@Suite(.serialized) struct HolosImporterTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let toronto = TimeZone(identifier: "America/Toronto")!

    func history() throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: "history", withExtension: "json", subdirectory: "Fixtures/holos")))
    }

    func setup() throws -> (HolosImporter, CaptureInbox, Commands) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-holos-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        let root = base.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (HolosImporter(root: root, support: support), CaptureInbox(root: root, support: support), Commands(support: support, deviceID: "dev"))
    }

    @Test func localesAreNormalized() {
        #expect(HolosImporter.locale("fr_CA") == "fr-CA")
        #expect(HolosImporter.locale("en_CA@calendar=gregorian") == "en-CA")
        #expect(HolosImporter.locale("en-CA-u-ca-gregory") == "en-CA")
        #expect(HolosImporter.locale("de-x-private") == "de")
        #expect(HolosImporter.locale(nil) == "und")
        #expect(HolosImporter.locale("??") == "und")
    }

    @Test func theRevisionIgnoresAudioAndKeyOrder() throws {
        let a = try JSONParser.parse(Data(#"{"id":"X","text":"t","audio":{"file":"x.m4a"}}"#.utf8)).value.objectValue!
        let b = try JSONParser.parse(Data(#"{"text":"t","id":"X"}"#.utf8)).value.objectValue!
        #expect(try HolosImporter.revision(a) == HolosImporter.revision(b))
        #expect(try HolosImporter.revision(a).wholeMatch(of: /[0-9a-f]{64}/) != nil)
    }

    @Test func dictationsMapToEventsAndBecomeCards() throws {
        let (importer, inbox, commands) = try setup()
        let r = try importer.importHistory(try history(), inbox: inbox, timeZone: toronto, now: now)
        #expect(r.written == 2 && r.unreadable == 1)
        let device = try #require(inbox.producers().first { $0.value == "holos" }?.key)
        let folder = importer.root.appendingPathComponent(device)
        let events = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).compactMap {
            try JSONParser.parse(Data(contentsOf: $0)).value.objectValue
        }
        let first = try #require(events.first { $0["source"]?["ref"] == .str("B2C3D4E5-0000-4000-8000-000000000002") })
        #expect(first["captured_at"] == .str("2026-10-06T10:05:09-04:00"))
        #expect(first["ended_at"] == .str("2026-10-06T10:05:15-04:00"))
        #expect(first["locale"] == .str("en-CA"))
        #expect(first["alt_text"] == .str("um ask the invented landlord about the deposit"))
        #expect(first["app_context"] == nil)   // a bundle identifier is never copied
        #expect(first["extensions"]?["holos"]?["outcome"] == .obj([("kind", .str("inserted")), ("partial", .bool(false))]))
        #expect(first["extensions"]?["holos"]?["language"] == .str("en_CA@calendar=gregorian"))
        #expect(!JSONWriter.compact(.object(first)).contains("com.example"))
        let second = try #require(events.first { $0["source"]?["ref"] == .str("A1B2C3D4-0000-4000-8000-000000000001") })
        #expect(second["app_context"] == .obj([("app", .str("Invented Notes")), ("terminal", .bool(true))]))
        #expect(second["extensions"]?["holos"]?["unwritten"] == .str(" inventé"))
        #expect(second["alt_text"] == nil)

        // The inbox reads them as a registered producer and builds Tier 0 cards with no binder.
        let swept = inbox.sweep(binders: [], commands: commands, now: now)
        #expect(swept.ingested == 2 && swept.quarantined == 0 && swept.unfiled == 2)
        #expect(inbox.unfiled().allSatisfy { $0.title == "Add from a dictation" && $0.raw["provenance"]?["unverified_source"] == nil })

        // A second run writes nothing new.
        #expect(try importer.importHistory(try history(), inbox: inbox, timeZone: toronto, now: now).skipped == 2)
    }

    @Test func theImporterStopsOnceHolosWritesItsOwnEvents() throws {
        let (importer, inbox, _) = try setup()
        try inbox.registerProducer(folder: "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", app: "holos")
        #expect(try importer.importHistory(try history(), inbox: inbox, now: now).stoppedForGood)
    }
}

import BinderFormat
@testable import BinderStore
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from Bugbot's review of BinderStore part 2 (PR #10): the survey reads only regular files inside the
/// binder and never a status's text, the addendum marker counts only on a line of its own, sync roots match whole
/// path components, and the stamp and the dashboard report what they cannot read. Invented data only.
@Suite(.serialized) struct BugbotAdoptionDashboardTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    /// The live lifeproj fixture with its first open item's status replaced by `status`.
    func binder(status: String? = nil) throws -> URL {
        try makeTeka(fixture: "lifeproj-v2-live") { folder in
            guard let status else { return }
            let url = folder.appendingPathComponent("catalog.json")
            guard case .object(var catalog) = try JSONParser.parse(try Data(contentsOf: url)).value,
                  var items = catalog["open_items"]?.arrayValue, case .object(var first) = items[0] else { return }
            first.set("status", .string(status))
            items[0] = .object(first)
            catalog.set("open_items", .array(items))
            try Data(JSONWriter.pretty(.object(catalog)).utf8).write(to: url)
        }
    }

    @Test func theSurveyCountsAStatusOutsideTheListWithoutItsText() throws {
        let folder = try binder(status: "call Invented Person about the gate")
        let survey = Adoption.survey(folder, inRegistry: false)
        #expect(!JSONWriter.compact(.object(survey)).contains("Invented Person"))
        #expect(survey["items_by_status"]?["unknown"] == .int(1))
    }

    @Test func theSurveyOpensNoPipeAndNoLinkOutOfTheBinder() throws {
        let folder = try binder()
        let outside = folder.deletingLastPathComponent().appendingPathComponent("elsewhere.json")
        try Data(#"{"hooks": {"Stop": []}, "note": "lifeproj publish"}"#.utf8).write(to: outside)
        #expect(mkfifo(folder.appendingPathComponent("CLAUDE.md").path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("AGENTS.md").path, withDestinationPath: outside.path)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("catalog_check.py").path, withDestinationPath: "/dev/zero")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(".claude/settings.json").path,
                                                   withDestinationPath: outside.path)
        // Returning at all is the first check: a pipe or a device read the plain way never ends.
        let survey = Adoption.survey(folder, inRegistry: false)
        #expect(survey["checker"] == .str("modified-or-unknown"))
        #expect(survey["hooks_may_send_data"] == .bool(false))
    }

    @Test func aManualLinkedInsideTheBinderIsStillRead() throws {
        let folder = try binder()
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("docs"), withIntermediateDirectories: true)
        try Data("Run lifeproj publish after each digest.\n".utf8).write(to: folder.appendingPathComponent("docs/manual.md"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("CLAUDE.md").path, withDestinationPath: "docs/manual.md")
        #expect(Adoption.survey(folder, inRegistry: false)["lifeproj_can_reach"] == .bool(true))
    }

    @Test func aMarkerMentionedInProseHidesNothingFromTheReachTest() throws {
        let folder = try binder()
        let manual = "# Invented binder\n\nTo hand this binder to Sprava, paste `\(ManualAddendum.marker)` at the end.\n\n"
            + "## Digest\n\nRun lifeproj publish after each digest.\n"
        try Data(manual.utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        #expect(Adoption.survey(folder, inRegistry: false)["lifeproj_can_reach"] == .bool(true))
        // The addendum itself, on its own line, still hides its own `lifeproj publish`.
        try Data(("# Invented binder\n\n" + ManualAddendum.text).utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        #expect(Adoption.survey(folder, inRegistry: false)["lifeproj_can_reach"] == .bool(false))
    }

    @Test func syncRootsMatchWholePathComponents() {
        let home = "/Users/example"
        #expect(Adoption.inSyncRoot(home + "/Library/CloudStorage/Invented-Drive/tax-2026", home: home))
        #expect(Adoption.inSyncRoot(home + "/Library/Mobile Documents/com~apple~CloudDocs/tax-2026", home: home))
        #expect(Adoption.inSyncRoot(home + "/Library/CloudStorage", home: home))
        #expect(!Adoption.inSyncRoot(home + "/Library/CloudStorageBackup/tax-2026", home: home))
        #expect(!Adoption.inSyncRoot(home + "/Library/Mobile Documents Old/tax-2026", home: home))
    }

    @Test func offeringTheStampReportsAnUnreadableOpLog() throws {
        let folder = try binder()
        let result = try Adoption.adopt(folder, inRegistry: false, deviceID: "test-device", today: today, now: now)
        let store = TekaStore(folder: folder)
        for p in result.proposals where p.raw["provenance"]?["adoption"] == .str("stamp") { try store.reject(p, reason: nil, now: now) }
        let log = folder.appendingPathComponent(".sprava/ops.ndjson")
        #expect(chmod(log.path, 0) == 0)
        defer { chmod(log.path, 0o600) }
        #expect(throws: (any Error).self) { try Adoption.offerStamp(folder, now: now) }
    }

    func switchedDashboard() throws -> (URL, DashboardKeeper) {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let keeper = DashboardKeeper(folder: folder)
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        return (folder, keeper)
    }

    @Test func aLinkInPlaceOfTheDashboardStateIsNotTakenForTheSwitch() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let hand = "# Invented dashboard kept by hand\n"
        try Data(hand.utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
        let elsewhere = folder.deletingLastPathComponent().appendingPathComponent("state.json")
        try Data(#"{"switched": true}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(".sprava/dashboard.json").path,
                                                   withDestinationPath: elsewhere.path)
        #expect(throws: StateFile.Unreadable.self) { try DashboardKeeper(folder: folder).refresh(today: today, timeZone: utc, now: now) }
        #expect(try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8) == hand)
    }

    @Test func refreshReportsACatalogThatIsGoneOrUnreadable() throws {
        let (folder, keeper) = try switchedDashboard()
        let dashboard = try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8)
        try Data("{".utf8).write(to: folder.appendingPathComponent("catalog.json"))
        #expect(throws: (any Error).self) { try keeper.refresh(today: today.adding(days: 1), timeZone: utc, now: now) }
        try FileManager.default.removeItem(at: folder.appendingPathComponent("catalog.json"))
        #expect(throws: (any Error).self) { try keeper.refresh(today: today.adding(days: 1), timeZone: utc, now: now) }
        #expect(try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8) == dashboard)
    }
}

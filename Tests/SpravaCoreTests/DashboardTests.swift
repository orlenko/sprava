import Foundation
import Testing
@testable import SpravaCore

@Suite(.serialized) struct DashboardTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func adopted() throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        return folder
    }

    @Test func escapingAndCodeSpans() {
        #expect(Dashboard.escape("![x](https://tracker.example/p.png)") == "\\!\\[x\\]\\(https://tracker.example/p.png\\)")
        #expect(Dashboard.escape("a\tb\nc\u{202E}d\u{07}") == "a b cd")
        #expect(Dashboard.escape("<b>#1|2</b>") == "\\<b\\>\\#1\\|2\\</b\\>")
        #expect(Dashboard.codeSpan("id-1") == "`id-1`")
        #expect(Dashboard.codeSpan("a`b") == "``a`b``")
        #expect(Dashboard.codeSpan("`x") == "`` `x ``")
    }

    @Test func theRenderingIsStableAndItsMarkerCoversEverythingAboveNotes() throws {
        let folder = try adopted()
        let catalog = try #require(Teka.read(folder).catalog)
        let a = Dashboard.render(catalog: catalog, folderName: "estate-example", today: today, timeZone: utc, hasManual: false, notes: nil, impl: "sprava/0.1")
        let b = Dashboard.render(catalog: catalog, folderName: "estate-example", today: today, timeZone: utc, hasManual: false, notes: nil, impl: "sprava/0.1")
        #expect(a == b)
        #expect(a.hasPrefix("<!-- teka-dashboard v0 sha256:"))
        #expect(!a.contains("\r"))
        #expect(!Dashboard.editedOutsideNotes(a))
        #expect(a.contains("## Nudge") && a.contains("## Recently closed") && a.contains("## Where things live"))
        #expect(a.contains("_None._") || a.contains("- `"))
        // An edit inside Notes changes no hash; an edit above it does.
        #expect(!Dashboard.editedOutsideNotes(a + "a fact kept by hand\n"))
        #expect(Dashboard.editedOutsideNotes(a.replacingOccurrences(of: "## At a glance", with: "## At a glance!")))
    }

    @Test func theSwitchKeepsTheOldTextInNotesAndRefreshSavesOutsideEdits() throws {
        let folder = try adopted()
        let old = "# Estate dashboard\n\n## Balance\n\nRunning balance: invented 1,000\n###### deep\n"
        try Data(old.utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
        let keeper = DashboardKeeper(folder: folder)
        #expect(try keeper.refresh(today: today, timeZone: utc, now: now) == .notSwitched)
        #expect(try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8) == old)   // never before the switch

        try keeper.switchOn(today: today, timeZone: utc, now: now)
        let text = try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8)
        let notes = try #require(Dashboard.split(text).1)
        #expect(notes.contains("## Estate dashboard") && notes.contains("### Balance") && notes.contains("###### deep"))
        #expect(notes.contains("Running balance: invented 1,000"))
        let copies = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".sprava/adopted").path)
        #expect(copies.contains { $0.hasPrefix("DASHBOARD-") })

        #expect(try keeper.refresh(today: today, timeZone: utc, now: now) == .unchanged)
        // A change to the catalog renders again and keeps Notes byte for byte.
        try TekaStore(folder: folder).apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                                        (key: "set", value: .obj([("priority", .str("low"))]))]),
                                                   actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        #expect(try keeper.refresh(today: today, timeZone: utc, now: now) == .rendered(editedOutsideNotes: false))
        #expect(Dashboard.split(try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8)).1 == notes)
        // Someone edits above Notes: the edited file is saved before the next rendering.
        let edited = try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8).replacingOccurrences(of: "## Overdue", with: "## Overdue (hand)")
        try Data(edited.utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
        #expect(try keeper.refresh(today: today, timeZone: utc, now: now.addingTimeInterval(60)) == .rendered(editedOutsideNotes: true))
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(".sprava/adopted").path)
        #expect(after.filter { $0.hasPrefix("DASHBOARD-") }.count == 2)
        #expect(!(try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8)).contains("(hand)"))
    }

    @Test func theDoctorAsksForTheAddendum() throws {
        let folder = try adopted()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-doctor-\(UUID().uuidString)")
        let device = try #require(Owner.device(of: folder))
        let rows = [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))]
        try Data("# Manual\nRun lifeproj publish after each digest.\n".utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        var findings = Doctor.run(rows: rows, deviceID: device, registry: nil, support: support, spool: support)
        #expect(findings.contains { $0.level == .fix && $0.text.contains("addendum") })
        try Data(("# Manual\n" + ManualAddendum.text).utf8).write(to: folder.appendingPathComponent("CLAUDE.md"))
        findings = Doctor.run(rows: [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))],
                              deviceID: device, registry: nil, support: support, spool: support)
        #expect(!findings.contains { $0.text.contains("addendum") })
    }
}

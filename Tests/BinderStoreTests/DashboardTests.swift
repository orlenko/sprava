import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct DashboardTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func adopted() throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        return folder
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

    func dashboard(_ folder: URL) throws -> String { try String(contentsOf: folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8) }

    func touchCatalog(_ folder: URL, _ priority: String) throws {
        try TekaStore(folder: folder).apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                                        (key: "set", value: .obj([("priority", .string(priority))]))]),
                                                   actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
    }

    // Layer 5 review, finding 3: Notes an editor saves while the dashboard is rendered are kept.
    @Test func notesSavedDuringARefreshAreKept() throws {
        let folder = try adopted()
        var keeper = DashboardKeeper(folder: folder)
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        try touchCatalog(folder, "low")
        let fired = StopFlag()
        let url = folder.appendingPathComponent("DASHBOARD.md")
        keeper.testHookBeforeWrite = {
            guard !fired.get() else { return }
            fired.set()
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? Data((text + "An invented fact saved meanwhile\n").utf8).write(to: url)
        }
        #expect(try keeper.refresh(today: today, timeZone: utc, now: now) == .rendered(editedOutsideNotes: false))
        let text = try dashboard(folder)
        #expect(Dashboard.split(text).1?.contains("An invented fact saved meanwhile") == true)
        #expect(!Dashboard.editedOutsideNotes(text))
    }

    // Layer 5 second review, finding 2: Notes saved after the last comparison, as the new file takes the old one's
    // place, are put back and rendered in, never lost.
    @Test func notesSavedAsTheFileIsReplacedAreKept() throws {
        let folder = try adopted()
        var keeper = DashboardKeeper(folder: folder)
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        try touchCatalog(folder, "low")
        let fired = StopFlag()
        let url = folder.appendingPathComponent("DASHBOARD.md")
        keeper.testHookBeforeSwap = {
            guard !fired.get() else { return }
            fired.set()
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? Data((text + "An invented fact saved at the last moment\n").utf8).write(to: url)
        }
        #expect(try keeper.refresh(today: today, timeZone: utc, now: now) == .rendered(editedOutsideNotes: false))
        let text = try dashboard(folder)
        #expect(Dashboard.split(text).1?.contains("An invented fact saved at the last moment") == true)
        #expect(!Dashboard.editedOutsideNotes(text))
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: folder.path)).contains { $0.hasSuffix(".tmp") })
    }

    // A dashboard that is there but cannot be read now is an error, never taken for an absent one and written over.
    @Test func anUnreadableDashboardIsReportedAndKept() throws {
        let folder = try adopted()
        let keeper = DashboardKeeper(folder: folder)
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        try touchCatalog(folder, "low")
        let url = folder.appendingPathComponent("DASHBOARD.md")
        let before = try Data(contentsOf: url)
        chmod(url.path, 0o000)
        defer { chmod(url.path, 0o644) }
        #expect(throws: TekaStore.Refused.self) { try keeper.refresh(today: today, timeZone: utc, now: now) }
        chmod(url.path, 0o644)
        #expect(try Data(contentsOf: url) == before)
    }

    // Layer 5 review, finding 4: copies kept in the same second never replace one another.
    @Test func copiesKeptInOneSecondAreAllKept() throws {
        let folder = try adopted()
        try Data("# Invented old dashboard\n".utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
        let keeper = DashboardKeeper(folder: folder)
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        for mark in ["first", "second"] {
            let edited = try dashboard(folder).replacingOccurrences(of: "## Overdue", with: "## Overdue (\(mark))")
            try Data(edited.utf8).write(to: folder.appendingPathComponent("DASHBOARD.md"))
            #expect(try keeper.refresh(today: today, timeZone: utc, now: now) == .rendered(editedOutsideNotes: true))
        }
        let dir = folder.appendingPathComponent(".sprava/adopted")
        let copies = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("DASHBOARD-") }
        #expect(copies.count == 3)
        let texts = try copies.map { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }
        #expect(texts.contains { $0.contains("(first)") } && texts.contains { $0.contains("(second)") })
        #expect(texts.contains { $0.hasPrefix("# Invented old dashboard") })
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: dir.path)).contains { $0.hasSuffix(".tmp") })
    }

    // Layer 5 review, finding 6: a dashboard state file that cannot be read is reported and never saved over.
    @Test func anUnreadableStateIsReported() throws {
        let folder = try adopted()
        let keeper = DashboardKeeper(folder: folder)
        try keeper.switchOn(today: today, timeZone: utc, now: now)
        let stateURL = folder.appendingPathComponent(".sprava/dashboard.json")
        try Data(#"{"switched":tr"#.utf8).write(to: stateURL)
        try touchCatalog(folder, "low")
        #expect(throws: StateFile.Unreadable.self) { try keeper.refresh(today: today, timeZone: utc, now: now) }
        #expect(throws: StateFile.Unreadable.self) { try keeper.switchOn(today: today, timeZone: utc, now: now) }
        #expect(try Data(contentsOf: stateURL) == Data(#"{"switched":tr"#.utf8))
        // A missing state still means not switched.
        try FileManager.default.removeItem(at: stateURL)
        #expect(try keeper.refresh(today: today, timeZone: utc, now: now) == .notSwitched)
    }
}

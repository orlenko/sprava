import Foundation
import Testing
@testable import SpravaCore

/// Copies an invented fixture into a temporary folder named like a binder, so reading has a real folder.
func makeTeka(fixture: String, folderName: String? = nil, subdirectory: String? = nil,
              mutate: ((URL) throws -> Void)? = nil) throws -> URL {
    let source = try #require(Bundle.module.url(forResource: fixture, withExtension: "json",
                                                subdirectory: subdirectory.map { "Fixtures/\($0)" } ?? "Fixtures"))
    let data = try Data(contentsOf: source)
    let parsedName = try JSONParser.parse(data).value["meta"]?["name"]?.stringValue
    let name = folderName ?? parsedName ?? "teka"
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-tests-\(UUID().uuidString)")
    let folder = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try data.write(to: folder.appendingPathComponent("catalog.json"))
    try mutate?(folder)
    return folder
}

let today = CalendarDate(year: 2026, month: 10, day: 7)!
let utc = TimeZone(identifier: "UTC")!

func ids(_ page: NowPage, _ bucket: Bucket) -> [String] { page.items[bucket, default: []].map(\.idText) }

@Suite struct TekaReadingTests {
    @Test func stampedV0IsReadyAndBucketsFollowTheSpec() throws {
        let teka = Teka.read(try makeTeka(fixture: "sprava-v0"))
        #expect(teka.level == .tekaV0)
        #expect(teka.findings.isEmpty, "\(teka.findings)")
        #expect(teka.state == .ready, "\(teka.reasons)")
        let page = teka.nowPage(today: today, timeZone: utc)
        #expect(ids(page, .next7) == ["estate-example-2026-007"])
        #expect(ids(page, .later) == ["estate-example-2026-009", "estate-example-2026-010"])
        #expect(ids(page, .waiting) == ["estate-example-2026-008"])
        #expect(ids(page, .nudge) == ["estate-example-2026-012"])
        #expect(page.hiddenCount == 1)
        #expect(page.closed.isEmpty)
    }

    @Test func liveLifeprojV2NeedsMigrationAndKeepsDoneItemsVisible() throws {
        let teka = Teka.read(try makeTeka(fixture: "lifeproj-v2-live"))
        #expect(teka.level == .lifeprojV2)
        #expect(teka.state == .needsMigration)
        let page = teka.nowPage(today: today, timeZone: utc)
        #expect(ids(page, .later) == ["item-0003"])
        // A waiting item with no follow_up_at is in Nudge, never Overdue, though its due has passed.
        #expect(ids(page, .nudge) == ["rental-elm-street-2026-004"])
        #expect(ids(page, .noDeadline) == ["item-0006"])
        #expect(page.closed.map(\.idText).contains("item-0005"))
        #expect(page.closed.last?.closedOn == nil)
    }

    @Test func legacyV1IsReadableWithLooseItems() throws {
        let teka = Teka.read(try makeTeka(fixture: "lifeproj-v1-legacy"))
        #expect(teka.level == .lifeprojV1)
        #expect(teka.state == .needsMigration)
        #expect(teka.findings.isEmpty)   // strict rules are not applied to v1
        let page = teka.nowPage(today: today, timeZone: utc)
        #expect(Set(ids(page, .noDeadline)) == ["loose", "t2"])
    }

    @Test func freshLifeprojCatalogIsReadable() throws {
        let teka = Teka.read(try makeTeka(fixture: "lifeproj-v2-fresh"))
        #expect(teka.level == .lifeprojV2)
        #expect(teka.findings.isEmpty)
        #expect(teka.items.isEmpty)
    }

    @Test(arguments: [
        ("catalog-both-due-and-no-deadline", RuleFinding.Code.dueAndNoDeadline),
        ("catalog-v0-compact-date", .badDue),
        ("catalog-v0-done-in-open-items", .doneInOpenItems),
        ("catalog-v0-null-due", .nullValue),
        ("catalog-v0-redact-without-kind", .redactedWithoutKind),
        ("catalog-v0-waiting-without-follow-up", .waitingWithoutFollowUp),
        ("catalog-waiting-without-party", .waitingWithoutParty),
    ])
    func invalidCatalogsReportTheirRule(fixture: String, code: RuleFinding.Code) throws {
        let teka = Teka.read(try makeTeka(fixture: fixture, subdirectory: "invalid"))
        #expect(teka.findings.contains { $0.code == code }, "\(teka.findings)")
        #expect(teka.state < .ready)
    }

    @Test func noCatalogIsNotATekaAndGarbageIsCorrupt() throws {
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        #expect(Teka.read(empty).state == .notATeka)
        try Data("{not json".utf8).write(to: empty.appendingPathComponent("catalog.json"))
        #expect(Teka.read(empty).state == .corrupt)
        try Data("[]".utf8).write(to: empty.appendingPathComponent("catalog.json"))
        #expect(Teka.read(empty).state == .corrupt)
    }

    @Test func nameMismatchAndSymlinkNeedAttention() throws {
        let renamed = Teka.read(try makeTeka(fixture: "sprava-v0", folderName: "estate-renamed"))
        #expect(renamed.state == .needsAttention)
        let linked = try makeTeka(fixture: "sprava-v0") { folder in
            try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent(".sprava"),
                                                       withDestinationURL: FileManager.default.temporaryDirectory)
        }
        #expect(Teka.read(linked).state == .needsAttention)
    }

    @Test func unsafeJSONNeedsAttention() throws {
        let folder = try makeTeka(fixture: "sprava-v0") { folder in
            try Data(#"{"meta": {"schema_version": 2, "schema_version": 1}, "open_items": []}"#.utf8)
                .write(to: folder.appendingPathComponent("catalog.json"))
        }
        let teka = Teka.read(folder)
        #expect(teka.states[.needsAttention] != nil)
    }

    @Test func readingWritesNothing() throws {
        let folder = try makeTeka(fixture: "lifeproj-v2-live")
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        let data = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        _ = Teka.read(folder).nowPage(today: today)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == before)
        #expect(try Data(contentsOf: folder.appendingPathComponent("catalog.json")) == data)
    }
}

@Suite struct CatalogLevelTests {
    func level(_ meta: String) throws -> CatalogLevel {
        let value = try JSONParser.parse("{\"meta\": \(meta)}").value
        return CatalogLevel.classify(try #require(value.objectValue))
    }

    @Test func levelTable() throws {
        #expect(try level(#"{"schema_version": 2}"#) == .lifeprojV2)
        #expect(try level(#"{"schema_version": 1}"#) == .lifeprojV1)
        #expect(try level(#"{"schema_version": 2.0}"#) == .lifeprojV1)
        #expect(try level(#"{"schema_version": "2"}"#) == .lifeprojV1)
        #expect(try level(#"{"schema_version": 0}"#) == .preLifeproj)
        #expect(try level(#"{}"#) == .preLifeproj)
        #expect(try level(#"{"schema_version": true}"#) == .unknown("schema_version is boolean"))
        #expect(try level(#"{"schema_version": 3}"#) == .unknown("schema_version 3"))
        #expect(try level(#"{"schema_version": 2, "format": "teka", "format_version": "0"}"#) == .tekaV0)
        #expect(try level(#"{"schema_version": 2.0, "format": "teka", "format_version": "0"}"#) == .tekaV0BadSchemaVersion)
        #expect(try level(#"{"schema_version": 2, "format": "teka"}"#) == .brokenStamp)
        if case .unknown = try level(#"{"schema_version": 2, "format": "teka", "format_version": "1"}"#) {} else {
            Issue.record("a newer format_version must be an unknown level")
        }
        if case .unknown = try level(#"{"schema_version": 2, "format": "Teka", "format_version": "0"}"#) {} else {
            Issue.record("format is case-sensitive")
        }
    }
}

@Suite struct BucketTests {
    func item(_ json: String) throws -> Item { Item(raw: try JSONParser.parse(json).value, index: 0) }

    @Test func overdueTodayNextLater() throws {
        #expect(NowPage.bucket(for: try item(#"{"status":"open","due":"2026-10-06"}"#), today: today) == .overdue)
        #expect(NowPage.bucket(for: try item(#"{"status":"open","due":"2026-10-07"}"#), today: today) == .today)
        #expect(NowPage.bucket(for: try item(#"{"status":"open","due":"2026-10-14"}"#), today: today) == .next7)
        #expect(NowPage.bucket(for: try item(#"{"status":"open","due":"2026-10-15"}"#), today: today) == .later)
        #expect(NowPage.bucket(for: try item(#"{"status":"open","due":"20261006"}"#), today: today) == .overdue)
        #expect(NowPage.bucket(for: try item(#"{"status":"open","due":"soon"}"#), today: today) == .noDeadline)
        #expect(NowPage.bucket(for: try item(#"{"due":"2026-10-06"}"#), today: today) == .overdue)
    }

    @Test func waitingNeverOverdue() throws {
        let late = try item(#"{"status":"waiting","due":"2026-01-01","follow_up_at":"2026-10-20"}"#)
        #expect(NowPage.bucket(for: late, today: today) == .waiting)
        let chase = try item(#"{"status":"blocked","follow_up_at":"2026-10-07"}"#)
        #expect(NowPage.bucket(for: chase, today: today) == .nudge)
    }

    @Test func recentlyClosedWindowIsSevenDays() throws {
        let log = [
            #"{"id":"a","action":"done","closed_at":"2026-10-01T10:00:00Z"}"#,
            #"{"id":"b","action":"dropped","closed_at":"2026-09-30T23:00:00Z"}"#,
            #"{"id":"c","action":"done","closed_at":"2026-10-03"}"#,
            #"{"id":"d","action":"done","closed_at":null,"at":"2026-10-05T08:00:00Z"}"#,
            #"{"action":"filed","at":"2026-10-06T08:00:00Z"}"#,
            #"{"id":"e","action":"done","closed_at":"2027-01-01T00:00:00Z"}"#,
        ].map { LogEntry(raw: try! JSONParser.parse($0).value) }
        let page = NowPage(items: [], log: log, today: today, timeZone: utc)
        #expect(page.closed.map(\.idText) == ["e", "d", "c", "a"])
        #expect(page.closed.first?.closedOn == today)   // a future date counts as today
    }

    @Test func orderWithinABucket() throws {
        let items = [
            #"{"id":"3","title":"b","status":"open","priority":"low","due":"2026-10-09"}"#,
            #"{"id":"2","title":"a","status":"open","priority":"low","due":"2026-10-09"}"#,
            #"{"id":"1","title":"z","status":"open","priority":"high","due":"2026-10-09"}"#,
            #"{"id":"0","title":"q","status":"open","priority":"normal","due":"2026-10-08"}"#,
        ].enumerated().map { Item(raw: try! JSONParser.parse($1).value, index: $0) }
        let page = NowPage(items: items, log: [], today: today, timeZone: utc)
        #expect(ids(page, .next7) == ["0", "1", "2", "3"])
    }
}

@Suite struct RegistryTests {
    @Test func readsProjectsAndArchived() {
        let toml = """
        # cmirror configuration
        identity_file = "~/.config/age/key.txt"

        [lifeproj]
        teka_home = "~/binders"

        [projects.kitchen-reno]
        working_dir = "~/binders/kitchen-reno"
        encrypted_dir = "/tmp/enc/kitchen-reno"

        [projects."tax-2026"]
        working_dir = '/Users/example/binders/tax-2026'

        [archived.estate-example]
        working_dir = "~/binders/estate-example"
        """
        let registry = LifeprojRegistry.parse(toml)
        #expect(registry.entries.map(\.name) == ["kitchen-reno", "tax-2026", "estate-example"])
        #expect(registry.entries[1].workingDir == "/Users/example/binders/tax-2026")
        #expect(registry.entries[2].archived)
        let rows = Shelf.rows(registry: registry, picked: [])
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.teka.state == .notATeka })
    }

    @Test func shelfStoreKeepsPickedFoldersOutsideBinders() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-support-\(UUID().uuidString)")
        let store = ShelfStore(supportDirectory: support)
        let folder = try makeTeka(fixture: "sprava-v0")
        try store.add(folder)
        try store.add(folder)
        #expect(store.pickedFolders().map(\.standardizedFileURL) == [folder.standardizedFileURL])
        let rows = Shelf.rows(registry: nil, picked: store.pickedFolders())
        #expect(rows.first?.stateLabel == "not yet adopted")
        try store.remove(folder)
        #expect(store.pickedFolders().isEmpty)
    }

    /// lifeproj's registry stays off the Shelf unless the person turns it on; adding a folder keeps the choice.
    @Test func theRegistryIsOffTheShelfUnlessTurnedOn() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-support-\(UUID().uuidString)")
        let store = ShelfStore(supportDirectory: support)
        let folder = try makeTeka(fixture: "sprava-v0")
        try store.add(folder)
        #expect(!store.showsRegistry)
        #expect(try store.registryForShelf() == nil)
        #expect(store.rows().map(\.source) == [.picked])
        try Data(#"{"schemaVersion":1,"folders":[],"showRegistry":true}"#.utf8).write(to: store.file)
        try store.add(folder)
        #expect(store.showsRegistry)
    }

    @Test func theBinderOpenedLastIsOnTopAndOthersSink() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-support-\(UUID().uuidString)")
        let recent = RecentBinders(supportDirectory: support)
        let a = try makeTeka(fixture: "sprava-v0"), b = try makeTeka(fixture: "sprava-v0"), c = try makeTeka(fixture: "sprava-v0")
        let rows = Shelf.rows(registry: nil, picked: [a, b, c])
        let t = Date(timeIntervalSince1970: 1_791_360_000)
        recent.touch(a, now: t)
        recent.touch(c, now: t.addingTimeInterval(60))
        let ordered = RecentBinders.order(rows, opened: recent.opened()).map(\.folder.standardizedFileURL)
        #expect(ordered == [c, a, b].map(\.standardizedFileURL))
        recent.touch(b, now: t.addingTimeInterval(120))
        #expect(RecentBinders.order(rows, opened: recent.opened()).first?.folder.standardizedFileURL == b.standardizedFileURL)
    }
}

import BinderStore
import Companion
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import SQLite3
import Testing
@testable import Services

private final class PublishingSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
/// Stands in for the publisher with a relay that accepts every upload: it records what is pending as published,
/// as the publisher does after a `204`. The calls are recorded by name.
private actor FakeTarget: CompanionPublishingTarget {
    let profile: CompanionProfile
    var calls: [String] = []
    init(_ profile: CompanionProfile) { self.profile = profile }
    func uploadView(binderID: String) async throws -> CompanionPublicationProgress {
        calls.append("view")
        guard let view = try profile.pendingView(binderID: binderID) else { return .idle }
        try profile.completeView(view); return .uploaded(name: view.name)
    }
    func uploadIndex(generatedAt: String) async throws -> CompanionPublicationProgress {
        calls.append("index")
        let index = try profile.pendingIndex() ?? profile.prepareIndex(generatedAt: generatedAt)
        try profile.completeIndex(index); return .uploaded(name: index.name)
    }
    func cleanRemovedBinders(limit: Int) async throws -> Int { calls.append("clean"); return 0 }
    func taken() -> [String] { defer { calls = [] }; return calls }
}
private let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
private let morning = Date(timeIntervalSince1970: 1_794_560_400) // 2026-11-13T09:00:00Z

/// An invented support folder, a claimed relay, and one adopted binder on the Shelf that this Mac ("mac-a") owns.
private struct PublishingFixture {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-publishing-" + UUID().uuidString)
    let secrets = PublishingSecrets()
    let binder: URL
    var database: URL { support.appendingPathComponent("companion/state.sqlite") }

    init() throws {
        binder = try makeTeka(fixture: "sprava-v0", folderName: "invented-garden")
        try TekaStore(folder: binder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("mac-a"))]), now: morning)
        try ShelfStore(supportDirectory: support).add(binder)
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 31, count: 32).base64EncodedString())
        _ = try profile().prepareAccount()
        var db: OpaquePointer?
        guard sqlite3_open(database.path, &db) == SQLITE_OK,
              sqlite3_exec(db, "UPDATE profile SET claim_state = 'claimed' WHERE slot = 1", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        sqlite3_close(db)
    }
    func profile() throws -> CompanionProfile { try CompanionProfile(database: database, relay: relay, secrets: secrets) }
    func show(_ folder: URL? = nil) throws -> String {
        try profile().showBinder(try CompanionBinderIdentities(support: support).identity(for: folder ?? binder)).id
    }
    func rows() throws -> [ShelfRow] { try ShelfStore(supportDirectory: support).rowsForJobs() }
    func remove() { try? FileManager.default.removeItem(at: support); try? FileManager.default.removeItem(at: binder.deletingLastPathComponent()) }
}

@Test func aShownBinderIsSnapshotOnlyWhenItsCatalogOrTheDayChanges() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    let id = try f.show(), target = FakeTarget(try f.profile()), publishing = CompanionPublishing(support: f.support, deviceID: "mac-a")
    let first = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning, timeZone: utc)
    #expect(first.snapshots == 1 && first.uploads == 1 && first.indexes == 1)
    #expect(await target.taken() == ["view", "index", "clean"])

    let quiet = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning.addingTimeInterval(60), timeZone: utc)
    #expect(quiet.snapshots == 0 && quiet.uploads == 0 && quiet.indexes == 0)
    #expect(await target.taken() == ["view", "clean"])

    // An edit made outside Sprava is settled under the binder's lock and makes a new version.
    let catalog = f.binder.appendingPathComponent("catalog.json")
    try Data(String(decoding: try Data(contentsOf: catalog), as: UTF8.self).replacingOccurrences(of: "\"open_items\"", with: "\"x_invented\": 1, \"open_items\"").utf8).write(to: catalog)
    let edited = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning.addingTimeInterval(120), timeZone: utc)
    #expect(edited.snapshots == 1)
    #expect(edited.uploads == 1)

    let tomorrow = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning.addingTimeInterval(86_400), timeZone: utc)
    #expect(tomorrow.snapshots == 1)
}

@Test func anIndexResumedFromAnEarlierRunIsFollowedByAFreshOne() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    _ = try f.show()
    let target = FakeTarget(try f.profile()), publishing = CompanionPublishing(support: f.support, deviceID: "mac-a")
    _ = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning, timeZone: utc)
    // An index recorded before an upload failed: it names no view uploaded since, so it cannot be the last one.
    _ = try f.profile().prepareIndex(generatedAt: "2026-11-13T09:00:30Z")
    _ = await target.taken()
    _ = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning.addingTimeInterval(60), timeZone: utc)
    #expect(await target.taken() == ["view", "index", "clean"])
    _ = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning.addingTimeInterval(120), timeZone: utc)
    #expect(await target.taken() == ["view", "index", "clean"])
}

@Test func aBinderNotShownIsNeverReadAndTheEmptyIndexIsPublishedOnce() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    let target = FakeTarget(try f.profile()), publishing = CompanionPublishing(support: f.support, deviceID: "mac-a")
    _ = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning, timeZone: utc)
    #expect(await target.taken() == ["index", "clean"])
    _ = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning.addingTimeInterval(60), timeZone: utc)
    #expect(await target.taken() == ["clean"])
}

@Test func aShownBinderTakenOffTheShelfIsSwitchedOffAndTheIndexRepublished() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    _ = try f.show()
    let target = FakeTarget(try f.profile()), publishing = CompanionPublishing(support: f.support, deviceID: "mac-a")
    _ = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning, timeZone: utc)
    _ = await target.taken()
    try ShelfStore(supportDirectory: f.support).remove(f.binder)
    let report = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning.addingTimeInterval(60), timeZone: utc)
    #expect(report.hidden == 1 && report.indexes == 1)
    #expect(await target.taken() == ["index", "clean"])
    let identity = try #require(try CompanionBinderIdentities(support: f.support).existing(for: f.binder))
    #expect(try f.profile().binderSharing(identity) == nil)
}

@Test func anotherFolderPutWhereAShownBinderWasIsNeverPublished() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    let id = try f.show(), target = FakeTarget(try f.profile())
    let publishing = CompanionPublishing(support: f.support, deviceID: "mac-a")
    // While the runtime is stopped, the binder is moved away and a copy (a different folder) takes its place.
    let away = f.binder.deletingLastPathComponent().appendingPathComponent("invented-garden-away", isDirectory: true)
    try FileManager.default.moveItem(at: f.binder, to: away)
    try FileManager.default.copyItem(at: away, to: f.binder)
    let report = try await publishing.run(profile: f.profile(), target: target, rows: f.rows(), now: morning, timeZone: utc)
    #expect(report.hidden == 1 && report.snapshots == 0)
    #expect(try f.profile().pendingView(binderID: id) == nil)
    #expect(await target.taken() == ["index", "clean"])
}

@Test func aShownBinderWhoseFolderIsAwayForNowKeepsItsLastViewAndStaysShown() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    _ = try f.show()
    let away = f.binder.deletingLastPathComponent().appendingPathComponent("invented-garden-offloaded", isDirectory: true)
    try FileManager.default.moveItem(at: f.binder, to: away)
    let report = try await CompanionPublishing(support: f.support, deviceID: "mac-a")
        .run(profile: f.profile(), target: FakeTarget(try f.profile()), rows: f.rows(), now: morning, timeZone: utc)
    #expect(report.hidden == 0 && report.skipped == 1)
    try FileManager.default.moveItem(at: away, to: f.binder)
    let identity = try #require(try CompanionBinderIdentities(support: f.support).existing(for: f.binder))
    #expect(try f.profile().binderSharing(identity)?.state == .shown)
}

@Test func aShownBinderThisMacCannotWriteKeepsItsLastViewAndStaysShown() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    let id = try f.show(), target = FakeTarget(try f.profile())
    let other = CompanionPublishing(support: f.support, deviceID: "mac-b")
    let report = try await other.run(profile: f.profile(), target: target, rows: f.rows(), now: morning, timeZone: utc)
    #expect(report.snapshots == 0 && report.skipped == 1 && report.hidden == 0)
    #expect(try f.profile().pendingView(binderID: id) == nil)
    let identity = try #require(try CompanionBinderIdentities(support: f.support).existing(for: f.binder))
    #expect(try f.profile().binderSharing(identity)?.state == .shown)
}

@Test func anUnreadableShelfFailsTheJobInsteadOfHidingEveryBinder() async throws {
    let f = try PublishingFixture(); defer { f.remove() }
    _ = try f.show()
    let shelf = f.support.appendingPathComponent("shelf.json")
    try Data("not json".utf8).write(to: shelf)
    let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { _ in .claimed })
    let job = CompanionJob.publishing(session: session, database: f.database, secrets: f.secrets, support: f.support, deviceID: "mac-a")
    #expect(await job.run() == .error(code: "companion_failed", culprit: nil))
    let identity = try #require(try CompanionBinderIdentities(support: f.support).existing(for: f.binder))
    #expect(try f.profile().binderSharing(identity)?.state == .shown)
}

@Test func theViewReadingCarriesBucketsRecentClosuresAndTheBinderName() throws {
    let catalog = try #require(try JSONParser.parse(Data(#"""
    {"meta": {"name": "Invented garden"},
     "open_items": [{"id": "g1", "title": "Order invented seeds", "due": "2026-11-13"},
                    {"id": "g2", "title": "Hear from the invented nursery", "status": "waiting", "follow_up_at": "2026-11-20"}],
     "processing_log": [{"id": "g0", "title": "Rake invented leaves", "action": "done", "closed_at": "2026-11-12T10:00:00Z"},
                        {"id": "old", "title": "Long ago", "action": "done", "closed_at": "2026-10-01"},
                        {"at": "2026-11-12T10:00:00Z", "note": "not a closure"}]}
    """#.utf8)).value.objectValue)
    let reading = CompanionViewReading.of(catalog: catalog, folder: URL(fileURLWithPath: "/invented/garden"),
        today: CalendarDate(year: 2026, month: 11, day: 13)!, generatedAt: "2026-11-13T09:00:00Z", timeZone: utc)
    #expect(reading.name == "Invented garden")
    #expect(reading.buckets[.today] == [.str("g1")] && reading.buckets[.waiting] == [.str("g2")])
    #expect(reading.recentlyClosed.map { $0["id"] } == [.str("g0")])
    #expect(reading.openItems.count == 2)
}

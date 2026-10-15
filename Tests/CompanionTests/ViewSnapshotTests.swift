import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class SnapshotSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private struct SnapshotFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-snapshot-" + UUID().uuidString)
    let secrets = SnapshotSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    let local = try! CompanionLocalBinderIdentity(bytes: Data(repeating: 42, count: 16))
    func profile() throws -> CompanionProfile { try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets) }
    func prepare() throws -> (CompanionProfile, String) {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 19, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        return (p, try p.showBinder(local).id)
    }
    func open(_ p: CompanionProfile, _ v: CompanionViewPublication) throws -> JSONValue {
        let kb = try #require(try secrets.read(account: p.binderKeyAccount(v.binderID, epoch: v.epoch)))
        let owner = try #require(try CompanionOwnerVault(backend: secrets).load(relay))
        return try CompanionSealedObject.open(name: v.name, epoch: v.epoch, key: SymmetricKey(data: kb), bytes: v.bytes, owner: owner.signingKey.publicKey)
    }
}
private func snapshotReading(_ recurrence: String = "monthly", title: String = "Inspect", duplicate: Bool = false) -> CompanionViewReading {
    let row = JSONValue.object(JSONObject([("id", .string("item")), ("title", .string(title)), ("recurrence", .string(recurrence)), ("notes", .string("Invented private note"))]))
    return CompanionViewReading(name: "Sample binder", today: "2026-10-15", generatedAt: "2026-10-15T12:00:00Z", openItems: duplicate ? [row, row] : [row])
}

@Test func aSnapshotCommitsVersionHashesAndCiphertextTogetherAndRestartRetriesThoseExactBytes() throws {
    let f = SnapshotFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), first = try p.prepareView(binderID: id, reading: snapshotReading()).publication
    let restarted = try f.profile(), retry = try #require(try restarted.pendingView(binderID: id))
    #expect(first.version == 1 && first.epoch == 1 && retry.bytes == first.bytes && retry.name == first.name)
    let payload = try f.open(p, retry)
    #expect(CompanionWire.unsigned(payload["version"]) == 1 && payload["items"]?.arrayValue?.first?["notes"] == .string("Invented private note"))
    #expect(try p.store.read { try $0.rows("SELECT highest_reserved, highest_indexed FROM phone_binders") } == [[.integer(1), .integer(0)]])
    let records = try p.store.read { try $0.rows("SELECT id, hash, changed_in FROM phone_item_snapshots") }
    #expect(records.count == 1 && records[0][1].text?.hasPrefix("sha256:") == true && records[0][2].integer == 1)
    #expect(first.bytes.range(of: Data("Invented private note".utf8)) == nil)
    #expect(try restarted.completeView(retry))
    #expect(try p.pendingView(binderID: id) == nil)
    let index = try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z")
    let account = try #require(try p.currentAccount()), owner = try #require(try CompanionOwnerVault(backend: f.secrets).load(f.relay))
    let entries = try CompanionSealedObject.open(name: index.name, epoch: index.epoch, key: account.key, bytes: index.bytes, owner: owner.signingKey.publicKey)["binders"]?.arrayValue
    #expect(entries?.count == 1 && entries?.first?["id"] == .string(id) && CompanionWire.unsigned(entries?.first?["view_version"]) == 1)
}

@Test func wholeRecordHistorySurvivesRestartAndDuplicateIdsDropTheirOldFingerprint() throws {
    let f = SnapshotFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare()
    _ = try p.prepareView(binderID: id, reading: snapshotReading())
    let same = try f.profile().prepareView(binderID: id, reading: snapshotReading()).publication
    #expect(CompanionWire.unsigned(try f.open(p, same)["items"]?.arrayValue?.first?["changed_in"]) == 1)
    let changed = try p.prepareView(binderID: id, reading: snapshotReading("weekly")).publication
    #expect(CompanionWire.unsigned(try f.open(p, changed)["items"]?.arrayValue?.first?["changed_in"]) == 3)
    let duplicated = try p.prepareView(binderID: id, reading: snapshotReading(duplicate: true))
    #expect(duplicated.issues.count == 1)
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM phone_item_snapshots") } == [[.integer(0)]])
    let unique = try p.prepareView(binderID: id, reading: snapshotReading()).publication
    let uniquePayload = try f.open(p, unique)
    #expect(unique.version == 5 && CompanionWire.unsigned(uniquePayload["items"]?.arrayValue?.first?["changed_in"]) == 5)
}

@Test func aFailedSnapshotCommitOrOversizedReadingLeavesThePreviousSnapshotAndPendingBytesIntact() throws {
    let f = SnapshotFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), first = try p.prepareView(binderID: id, reading: snapshotReading()).publication
    #expect(throws: CompanionCredentialError.unavailable) {
        try p.prepareView(binderID: id, reading: snapshotReading("weekly"), beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(throws: CompanionViewProjectionError.tooLarge) { try p.prepareView(binderID: id, reading: snapshotReading(title: String(repeating: "t", count: 780000))) }
    #expect(try f.profile().pendingView(binderID: id)?.bytes == first.bytes)
    #expect(try p.store.read { try $0.rows("SELECT highest_reserved FROM phone_binders") } == [[.integer(1)]])
    let retry = try p.prepareView(binderID: id, reading: snapshotReading()).publication
    let retryPayload = try f.open(p, retry)
    #expect(retry.version == 2 && CompanionWire.unsigned(retryPayload["items"]?.arrayValue?.first?["changed_in"]) == 1)
}

@Test func oldUploadCompletionsCannotPublishAndRetiredNamesAreNeverReused() throws {
    let f = SnapshotFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), first = try p.prepareView(binderID: id, reading: snapshotReading()).publication
    #expect(try p.completeView(first))
    let second = try p.prepareView(binderID: id, reading: snapshotReading("weekly")).publication
    let third = try p.prepareView(binderID: id, reading: snapshotReading("daily")).publication
    #expect(try p.completeView(second) == false)
    #expect(try p.store.read { try $0.rows("SELECT version, state FROM phone_views ORDER BY version") } == [[.integer(1), .text("uploaded")], [.integer(3), .text("uploading")]])
    let forged = CompanionViewPublication(binderID: id, version: third.version, epoch: third.epoch, bytes: Data("different".utf8))
    #expect(throws: CompanionPublicationError.invalid) { try p.completeView(forged) }
    try p.supersedeView(third)
    #expect(try p.pendingView(binderID: id) == nil)
    #expect(try p.completeView(third) == false)
    let fourth = try p.prepareView(binderID: id, reading: snapshotReading("daily")).publication
    let fourthPayload = try f.open(p, fourth)
    #expect(fourth.version == 4 && CompanionWire.unsigned(fourthPayload["items"]?.arrayValue?.first?["changed_in"]) == 3)
    #expect(try p.completeView(fourth))
}

@Test func removalMissingKeysAndSuspendedOrRevokedEpochsNeverProduceNewViewBytes() throws {
    let f = SnapshotFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), first = try p.prepareView(binderID: id, reading: snapshotReading()).publication
    try p.recordClaimState(.checkingRefusal)
    #expect(try p.pendingView(binderID: id) == nil)
    #expect(throws: CompanionPublicationError.unavailable) { try p.prepareView(binderID: id, reading: snapshotReading()) }
    try p.recordClaimState(.claimed)
    let d = CompanionWire.base64(Data(repeating: 7, count: 16))
    try p.store.write { t in
        try t.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'revoked', 0, 1, 0)", .text(d))
        try t.execute("INSERT INTO recipients VALUES (1, ?)", .text(d))
    }
    #expect(try p.pendingView(binderID: id) == nil)
    #expect(try p.completeView(first) == false)
    #expect(throws: CompanionPublicationError.unavailable) { try p.prepareView(binderID: id, reading: snapshotReading()) }
    try p.store.write { try $0.execute("DELETE FROM recipients") }
    f.secrets.values.removeValue(forKey: p.binderKeyAccount(id, epoch: 1))
    let count = f.secrets.values.count
    #expect(throws: CompanionCredentialError.unavailable) { try p.prepareView(binderID: id, reading: snapshotReading()) }
    #expect(f.secrets.values.count == count)
    try p.hideBinder(f.local)
    #expect(try p.completeView(first) == false)
    #expect(try p.pendingView(binderID: id) == nil)
    #expect(throws: CompanionPublicationError.unavailable) { try p.prepareView(binderID: id, reading: snapshotReading()) }
    #expect(try p.store.read { try $0.rows("SELECT highest_reserved FROM phone_binders") } == [[.integer(1)]])
}

@Test func separateConnectionsReserveDistinctVersionsAndTypedUnicodeIdsKeepSeparateDurableHistories() async throws {
    let f = SnapshotFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare()
    let ids: [JSONValue] = [.number(JSONNumber(text: "7")), .string("7"), .string("é"), .string("e\u{301}")]
    let rows = ids.map { JSONValue.object(JSONObject([("id", $0), ("title", .string("Sample"))])) }
    let reading = CompanionViewReading(name: "Sample binder", today: "2026-10-15", generatedAt: "2026-10-15T12:00:00Z", openItems: rows)
    let profiles = try (0..<10).map { _ in try f.profile() }
    let versions = try await withThrowingTaskGroup(of: Int64.self) { group in
        for profile in profiles { group.addTask { try profile.prepareView(binderID: id, reading: reading).publication.version } }
        var result: [Int64] = []; for try await version in group { result.append(version) }; return result.sorted()
    }
    #expect(versions == Array(Int64(1)...10))
    let newest = try #require(try p.pendingView(binderID: id)), items = try #require(try f.open(p, newest)["items"]?.arrayValue)
    #expect(newest.version == 10 && items.count == 4 && items.allSatisfy { CompanionWire.unsigned($0["changed_in"]) == 1 })
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM phone_item_snapshots") } == [[.integer(4)]])
}

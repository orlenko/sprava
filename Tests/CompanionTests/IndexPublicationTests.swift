import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class IndexSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private struct IndexFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-index-" + UUID().uuidString)
    let secrets = IndexSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    func profile() throws -> CompanionProfile {
        try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
    }
    func prepare() throws -> CompanionProfile {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 19, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed); return p
    }
    func view(_ p: CompanionProfile, id: String, version: Int64, epoch: Int64 = 1,
              state: String = "uploaded", shown: Bool = true, name: String = "Sample binder") throws {
        try p.store.write { t in
            try t.execute("INSERT OR IGNORE INTO phone_binders (binder, state) VALUES (?, ?)", .text(id), .text(shown ? "shown" : "removed"))
            try t.execute("INSERT INTO phone_views VALUES (?, ?, ?, ?, ?, ?)", .text(id), .integer(version), .integer(epoch),
                          .text(name), .text(state), .blob(Data("invented recorded envelope".utf8)))
        }
        _ = try secrets.insert(account: p.binderKeyAccount(id, epoch: epoch), bytes: Data(repeating: 23, count: 32))
    }
    func open(_ p: CompanionProfile, _ publication: CompanionIndexPublication) throws -> JSONValue {
        let account = try #require(try p.currentAccount()), owner = try #require(try CompanionOwnerVault(backend: secrets).load(relay))
        return try CompanionSealedObject.open(name: publication.name, epoch: publication.epoch, key: account.key,
            bytes: publication.bytes, owner: owner.signingKey.publicKey)
    }
}
private func binderID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }

@Test func indexIsRecordedBeforeUploadAndReopeningUsesExactlyTheSameCiphertextAndRevision() throws {
    let f = IndexFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), first = try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z")
    let restarted = try f.profile(), retry = try restarted.prepareIndex(generatedAt: "2026-10-15T12:01:00Z")
    #expect(first.revision == 1 && first.epoch == 1 && retry.bytes == first.bytes)
    #expect(try restarted.pendingIndex()?.bytes == first.bytes)
    #expect(try p.store.read { try $0.rows("SELECT index_reserved, index_published FROM profile") } == [[.integer(1), .integer(0)]])
    let opened = try f.open(p, first)
    #expect(CompanionWire.unsigned(opened["revision"]) == 1 && opened["binders"]?.arrayValue?.isEmpty == true)
    #expect(opened["generated_at"]?.stringValue == "2026-10-15T12:00:00Z")
    #expect(try p.completeIndex(first))
    #expect(try restarted.pendingIndex() == nil && restarted.completeIndex(first))
    #expect(try p.prepareIndex(generatedAt: "2026-10-15T12:02:00Z").revision == 2)
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM index_upload") } == [[.integer(1)]])
}

@Test func indexNamesOnlyUploadedShownViewsAtItsEpochAndRaisesTheirHighWaterMarksBeforeUpload() throws {
    let f = IndexFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), a = binderID(1), b = binderID(2), c = binderID(3)
    try f.view(p, id: a, version: 2, name: String(repeating: "🪴", count: 210))
    try f.view(p, id: a, version: 3, state: "uploading")
    try f.view(p, id: b, version: 99, epoch: 2)
    try f.view(p, id: c, version: 5, shown: false)
    let publication = try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z")
    let entries = try #require(try f.open(p, publication)["binders"]?.arrayValue)
    #expect(entries.count == 1 && entries[0]["id"]?.stringValue == a && CompanionWire.unsigned(entries[0]["view_version"]) == 2)
    let name = try #require(entries[0]["name"]?.stringValue)
    #expect(name.hasSuffix("…") && name.unicodeScalars.count <= 200 && JSONWriter.compact(.string(name)).utf8.count - 2 <= 800)
    #expect(try p.store.read { try $0.rows("SELECT highest_indexed FROM phone_binders WHERE binder = ?", .text(a)) } == [[.integer(2)]])
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM index_published_views") } == [[.integer(0)]])
    #expect(try p.completeIndex(publication))
    #expect(try p.store.read { try $0.rows("SELECT binder, version FROM index_published_views") } == [[.text(a), .integer(2)]])
}

@Test func aFailedIndexCommitOrMissingBinderKeyCannotAdvanceCountersOrReplaceKeys() throws {
    let f = IndexFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), id = binderID(4)
    try f.view(p, id: id, version: 7)
    #expect(throws: CompanionCredentialError.unavailable) {
        try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z", beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(try p.pendingIndex() == nil)
    #expect(try p.store.read { try $0.rows("SELECT highest_indexed FROM phone_binders") } == [[.integer(0)]])
    f.secrets.values.removeValue(forKey: p.binderKeyAccount(id, epoch: 1))
    let count = f.secrets.values.count
    #expect(throws: CompanionCredentialError.unavailable) { try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z") }
    #expect(f.secrets.values.count == count)
    #expect(try p.pendingIndex() == nil)
}

@Test func supersededRevisionsAreNeverReusedAndLateCompletionCannotLowerThePairingFloor() throws {
    let f = IndexFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), first = try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z")
    try p.supersedeIndex(first)
    let second = try f.profile().prepareIndex(generatedAt: "2026-10-15T12:01:00Z")
    #expect(second.revision == 2 && second.bytes != first.bytes)
    #expect(try p.completeIndex(first) == false)
    // Force a SQLite failure partway through completion. No published counter or membership may escape.
    try p.store.write { try $0.execute("CREATE TRIGGER fail_index BEFORE UPDATE OF index_published ON profile BEGIN SELECT RAISE(ABORT, 'invented failure'); END") }
    #expect(throws: (any Error).self) { try p.completeIndex(second) }
    #expect(try f.profile().pendingIndex()?.bytes == second.bytes)
    try p.store.write { try $0.execute("DROP TRIGGER fail_index") }
    #expect(try f.profile().completeIndex(second))
    #expect(try p.store.read { try $0.rows("SELECT index_reserved, index_published FROM profile") } == [[.integer(2), .integer(2)]])
    #expect(try p.completeIndex(first) == false)
}

@Test func publicationRefusesAnEpochStillHeldByARevokedRecipientAndCapsTheIndex() throws {
    let f = IndexFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), d = binderID(5)
    try p.store.write { t in
        try t.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, 'revoked', 0, 1, 0)", .text(d))
        try t.execute("INSERT INTO recipients VALUES (1, ?)", .text(d))
    }
    #expect(throws: CompanionPublicationError.unavailable) { try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z") }
    try p.store.write { try $0.execute("DELETE FROM recipients") }
    for byte in UInt8(0)...100 { try f.view(p, id: binderID(byte), version: 1) }
    #expect(throws: CompanionPublicationError.tooManyBinders) { try p.prepareIndex(generatedAt: "2026-10-15T12:00:00Z") }
    #expect(try p.pendingIndex() == nil)
    let escaped = CompanionProfile.phoneName(String(repeating: "\n", count: 200))
    #expect(escaped.unicodeScalars.count <= 200 && JSONWriter.compact(.string(escaped)).utf8.count - 2 <= 800)
}

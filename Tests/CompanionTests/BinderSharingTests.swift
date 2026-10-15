import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class SharingSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Data] = [:]
    var failInsert = false
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failInsert { throw CompanionCredentialError.unavailable }
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
}
private struct SharingFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-sharing-" + UUID().uuidString)
    let secrets = SharingSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    func profile() throws -> CompanionProfile {
        try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
    }
    func prepare() throws -> CompanionProfile {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 24, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); try p.recordClaimState(.claimed); return p
    }
}
private func localIdentity(_ byte: UInt8) throws -> CompanionLocalBinderIdentity {
    try CompanionLocalBinderIdentity(bytes: Data(repeating: byte, count: 16))
}

@Test func sharingStartsOffAndReopeningUsesTheSameIdentityWhileReEnablingMakesANewPhoneIdAndKey() throws {
    let f = SharingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), identity = try localIdentity(1)
    #expect(try p.binderSharing(identity) == nil)
    let first = try p.showBinder(identity), key = try #require(f.secrets.values[p.binderKeyAccount(first.id, epoch: 1)])
    #expect(first.state == .shown && first.keyEpoch == 1 && key.count == 32)
    #expect(try f.profile().showBinder(identity).id == first.id)
    try p.store.write { try $0.execute("UPDATE phone_binders SET highest_reserved = 27, highest_indexed = 26 WHERE binder = ?", .text(first.id)) }
    try p.hideBinder(identity)
    #expect(try p.binderSharing(identity) == nil)
    let second = try f.profile().showBinder(identity)
    #expect(second.id != first.id && f.secrets.values[p.binderKeyAccount(second.id, epoch: 1)] != key)
    #expect(f.secrets.values[p.binderKeyAccount(first.id, epoch: 1)] == key) // Kept until safe cleanup behind a new index.
    #expect(try p.store.read { try $0.rows("SELECT state, highest_reserved, highest_indexed FROM phone_binders WHERE binder = ?", .text(first.id)) } ==
            [[.text("removed"), .integer(27), .integer(26)]])
}

@Test func aReservedIdAndStagedKeySurviveFailedStorageAndCommitWithoutBeingRegenerated() throws {
    let f = SharingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), identity = try localIdentity(2)
    f.secrets.failInsert = true
    #expect(throws: CompanionCredentialError.unavailable) { try p.showBinder(identity) }
    let pending = try #require(try f.profile().binderSharing(identity))
    #expect(pending.state == .preparing)
    f.secrets.failInsert = false
    #expect(throws: CompanionCredentialError.unavailable) {
        try p.finishShowingBinder(id: pending.id, beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    let key = try #require(f.secrets.values[p.binderKeyAccount(pending.id, epoch: 1)])
    #expect(try f.profile().binderSharing(identity)?.state == .preparing)
    #expect(try f.profile().finishShowingBinder(id: pending.id).state == .shown)
    #expect(f.secrets.values[p.binderKeyAccount(pending.id, epoch: 1)] == key)
}

@Test func establishedMissingKeysAndMalformedStagedKeysFailWithoutReplacement() throws {
    let f = SharingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare(), identity = try localIdentity(3)
    let shown = try p.showBinder(identity), account = p.binderKeyAccount(shown.id, epoch: 1)
    f.secrets.values.removeValue(forKey: account)
    #expect(throws: CompanionCredentialError.unavailable) { try f.profile().showBinder(identity) }
    #expect(f.secrets.values[account] == nil)
    let other = try localIdentity(4)
    f.secrets.failInsert = true
    #expect(throws: CompanionCredentialError.unavailable) { try p.showBinder(other) }
    f.secrets.failInsert = false
    let pending = try #require(try p.binderSharing(other)), staged = p.binderKeyAccount(pending.id, epoch: 1)
    f.secrets.values[staged] = Data(repeating: 0, count: 31)
    #expect(throws: CompanionCredentialError.invalid) { try f.profile().showBinder(other) }
    #expect(f.secrets.values[staged]?.count == 31)
    #expect(throws: CompanionPublicationError.invalid) { try CompanionLocalBinderIdentity(bytes: Data(repeating: 1, count: 15)) }
}

@Test func theSharingCapCountsReservationsAndTurningOffStillWorksWhenClaimAdmissionIsSuspended() throws {
    let f = SharingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.prepare()
    f.secrets.failInsert = true
    for byte in UInt8(0)..<100 {
        #expect(throws: CompanionCredentialError.unavailable) { try p.showBinder(localIdentity(byte)) }
    }
    #expect(throws: CompanionPublicationError.tooManyBinders) { try p.showBinder(localIdentity(100)) }
    try p.recordClaimState(.needsReset)
    try p.hideBinder(localIdentity(0))
    #expect(try p.binderSharing(localIdentity(0)) == nil)
    #expect(throws: CompanionPublicationError.unavailable) { try p.showBinder(localIdentity(100)) }
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM phone_binders WHERE state = 'preparing'") } == [[.integer(99)]])
}

@Test func simultaneousShowsThroughSeparateConnectionsReserveOneIdAndOneImmutableKey() async throws {
    let f = SharingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    _ = try f.prepare()
    let identity = try localIdentity(5)
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<20 { group.addTask { try f.profile().showBinder(identity).id } }
        var result: [String] = []; for try await id in group { result.append(id) }; return result
    }
    #expect(Set(ids).count == 1 && f.secrets.values.count == 3) // Owner, account and binder key.
    let p = try f.profile()
    #expect(try p.store.read { try $0.rows("SELECT COUNT(*) FROM phone_binders") } == [[.integer(1)]])
}

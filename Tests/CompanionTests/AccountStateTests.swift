import CryptoKit
import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class AccountSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var entries: [String: Data] = [:]
    var failRead = false
    var failWrite = false
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failRead { throw CompanionCredentialError.unavailable }
        return entries[account]
    }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failWrite { throw CompanionCredentialError.unavailable }
        if entries[account] != nil { return false }
        entries[account] = bytes; return true
    }
}
private struct AccountFixture {
    let folder: URL
    let relay: CompanionRelayIdentity
    let secrets = AccountSecrets()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    init() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-companion-account-" + UUID().uuidString)
        relay = try CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    }
    func profile() throws -> CompanionProfile { try CompanionProfile(database: database, relay: relay, secrets: secrets) }
    func remove() throws { try FileManager.default.removeItem(at: folder) }
}
private func bytes(_ value: CompanionAccountEpoch) -> Data { value.key.withUnsafeBytes { Data($0) } }

@Test func accountEpochAndKeySurviveReopeningWithoutPuttingSecretBytesInSQLite() throws {
    let f = try AccountFixture(); defer { try? f.remove() }
    let profile = try f.profile()
    #expect(try profile.currentAccount() == nil)
    let initial = try profile.prepareAccount()
    let reopened = try #require(try f.profile().currentAccount())
    #expect(initial.number == 1 && reopened.number == 1)
    #expect(bytes(initial).count == 32 && bytes(initial) == bytes(reopened))
    #expect(f.secrets.entries.count == 1)
    let db = try StateStore.open(f.database, schema: CompanionProfile.schema)
    let rows = try db.read { try $0.rows("SELECT origin, instance, epoch FROM profile") }
    #expect(rows == [[.text(f.relay.origin), .text(f.relay.instance), .integer(1)]])
    let raw = try Data(contentsOf: f.database)
    #expect(raw.range(of: bytes(initial)) == nil)
    #expect(raw.range(of: Data(CompanionWire.base64(bytes(initial)).utf8)) == nil)
}

@Test func aFailedEpochCommitKeepsTheStagedKeyAndRetryReusesIt() throws {
    let f = try AccountFixture(); defer { try? f.remove() }
    let profile = try f.profile()
    #expect(throws: CompanionCredentialError.unavailable) {
        try profile.prepareAccount(beforeCommit: { throw CompanionCredentialError.unavailable })
    }
    #expect(try profile.currentAccount() == nil)
    let staged = try #require(f.secrets.entries.values.first)
    let retry = try f.profile().prepareAccount()
    #expect(bytes(retry) == staged && retry.number == 1)
    #expect(f.secrets.entries.count == 1)
}

@Test func aMissingEstablishedAccountKeyFailsWithoutGeneratingAReplacement() throws {
    let f = try AccountFixture(); defer { try? f.remove() }
    let profile = try f.profile()
    _ = try profile.prepareAccount()
    f.secrets.entries.removeAll()
    #expect(throws: CompanionCredentialError.unavailable) { try profile.currentAccount() }
    #expect(throws: CompanionCredentialError.unavailable) { try profile.prepareAccount() }
    #expect(f.secrets.entries.isEmpty)
    let db = try StateStore.open(f.database, schema: CompanionProfile.schema)
    #expect(try db.read { try $0.rows("SELECT epoch FROM profile") } == [[.integer(1)]])
}

@Test func lockedOrFailedSecretStorageCannotCommitAnEpoch() throws {
    let f = try AccountFixture(); defer { try? f.remove() }
    let profile = try f.profile()
    f.secrets.failRead = true
    #expect(throws: CompanionCredentialError.unavailable) { try profile.prepareAccount() }
    f.secrets.failRead = false; f.secrets.failWrite = true
    #expect(throws: CompanionCredentialError.unavailable) { try profile.prepareAccount() }
    #expect(try profile.currentAccount() == nil)
    #expect(f.secrets.entries.isEmpty)
}

@Test func malformedStagedAndEstablishedKeysFailClosed() throws {
    let f = try AccountFixture(); defer { try? f.remove() }
    let profile = try f.profile()
    #expect(throws: CompanionCredentialError.invalid) { try profile.prepareAccount(beforeCommit: { throw CompanionCredentialError.invalid }) }
    let account = try #require(f.secrets.entries.keys.first)
    f.secrets.entries[account] = Data(repeating: 0, count: 31)
    #expect(throws: CompanionCredentialError.invalid) { try profile.prepareAccount() }
    #expect(try profile.currentAccount() == nil)
    f.secrets.entries[account] = Data(repeating: 7, count: 32)
    _ = try profile.prepareAccount()
    f.secrets.entries[account] = Data()
    #expect(throws: CompanionCredentialError.invalid) { try profile.prepareAccount() }
    #expect(f.secrets.entries[account] == Data())
}

@Test func anExistingProfileCannotBeReboundToAnotherRelayOrInstance() throws {
    let f = try AccountFixture(); defer { try? f.remove() }
    _ = try f.profile().prepareAccount()
    f.secrets.failRead = true
    let otherOrigin = try CompanionRelayIdentity(origin: "https://other.example", instance: f.relay.instance)
    let otherInstance = try CompanionRelayIdentity(origin: f.relay.origin, instance: "fedcba9876543210fedcba9876543210")
    for identity in [otherOrigin, otherInstance] {
        #expect(throws: CompanionCredentialError.invalid) {
            try CompanionProfile(database: f.database, relay: identity, secrets: f.secrets)
        }
    }
    #expect(f.secrets.entries.count == 1)
}

@Test func simultaneousInitializationsThroughSeparateConnectionsChooseOneAccountKey() async throws {
    let f = try AccountFixture(); defer { try? f.remove() }
    let values = try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<20 { group.addTask { bytes(try f.profile().prepareAccount()) } }
        var values: [Data] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(Set(values).count == 1)
    #expect(f.secrets.entries.count == 1)
}

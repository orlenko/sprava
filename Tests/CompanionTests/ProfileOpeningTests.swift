import Foundation
import Testing
@testable import Companion
import SpravaKit

private enum OpeningFixtureError: Error { case unexpectedCredentialAccess }
private struct OpeningForbiddenSecrets: CompanionCredentialStorage {
    func read(account: String) throws -> Data? { throw OpeningFixtureError.unexpectedCredentialAccess }
    func insert(account: String, bytes: Data) throws -> Bool { throw OpeningFixtureError.unexpectedCredentialAccess }
    func remove(account: String) throws { throw OpeningFixtureError.unexpectedCredentialAccess }
}
private final class OpeningFixtureSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
private struct OpeningFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-profile-opening-" + UUID().uuidString)
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func prepare(origin: String = "https://relay.example") throws -> CompanionProfile {
        let p = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: origin, instance: "0123456789abcdef0123456789abcdef"),
            secrets: OpeningFixtureSecrets())
        _ = try p.prepareAccount(); try p.recordClaimState(.checkingRefusal)
        return p
    }
}

@Test func anUnconfiguredProfileOpensWithoutTouchingCredentials() throws {
    let f = OpeningFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    #expect(try CompanionProfile.openConfigured(database: f.database, secrets: OpeningForbiddenSecrets()) == nil)
    _ = try f.prepare()
    #expect(try CompanionProfile.openConfigured(database: f.database, secrets: OpeningForbiddenSecrets()) != nil)
}

@Test func reopeningUsesTheSavedRelayAndPreservesClaimAdmissionWithoutAccessingKeys() throws {
    for origin in ["https://relay.example", "http://localhost:9451"] {
        let f = OpeningFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        _ = try f.prepare(origin: origin)
        let reopened = try #require(try CompanionProfile.openConfigured(database: f.database, secrets: OpeningForbiddenSecrets()))
        #expect(reopened.relay.origin == origin && reopened.relay.instance == "0123456789abcdef0123456789abcdef")
        #expect(try reopened.ownerClaimState() == .checkingRefusal)
        // Credentials are deliberately unavailable: opening metadata cannot pretend the account has usable keys.
        #expect(throws: OpeningFixtureError.self) { try reopened.currentAccount() }
    }
}

@Test func corruptRelayMetadataIsRefusedWithoutOverwritingTheSavedBinding() throws {
    for (column, invalid) in [("origin", "http://relay.example"), ("instance", "not-an-instance")] {
        let f = OpeningFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; let p = try f.prepare()
        _ = try p.store.write { try $0.execute("UPDATE profile SET \(column) = ? WHERE slot = 1", .text(invalid)) }
        let before = try p.store.read { try $0.rows("SELECT origin, instance, epoch, claim_state FROM profile") }
        #expect(throws: CompanionCredentialError.invalid) {
            try CompanionProfile.openConfigured(database: f.database, secrets: OpeningForbiddenSecrets())
        }
        #expect(try p.store.read { try $0.rows("SELECT origin, instance, epoch, claim_state FROM profile") } == before)
    }
}

@Test func anUnreadableExistingProfileThrowsInsteadOfReturningAnUnconfiguredResult() throws {
    let f = OpeningFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    try FileManager.default.createDirectory(at: f.folder, withIntermediateDirectories: true)
    let bytes = Data("Invented invalid SQLite file".utf8)
    try bytes.write(to: f.database)
    #expect(throws: (any Error).self) {
        try CompanionProfile.openConfigured(database: f.database, secrets: OpeningForbiddenSecrets())
    }
    #expect(try Data(contentsOf: f.database) == bytes)
}

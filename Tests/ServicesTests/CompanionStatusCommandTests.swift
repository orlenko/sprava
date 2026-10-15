import BinderStore
import Companion
import Foundation
import SpravaKit
import Testing
@testable import Services

private final class StatusFixtureSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
private struct StatusFixture {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-companion-status-" + UUID().uuidString)
    var database: URL { support.appendingPathComponent("companion/state.sqlite") }
    func call(extra: [(String, JSONValue)] = []) throws -> JSONValue {
        let commands = Commands(support: support, deviceID: "invented-device")
        return try JSONParser.parse(commands.handle(JSONWriter.compact(.obj([("command", .str("companion_status"))] + extra)))).value
    }
    func prepare() throws {
        let profile = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: StatusFixtureSecrets())
        _ = try profile.prepareAccount()
    }
}

@Test func companionStatusIsRegisteredAndReturnsOnlyStableUnconfiguredAdmission() throws {
    let f = StatusFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    #expect(try f.call() == .obj([("ok", .bool(true)), ("state", .str("not-configured"))]))
}

@Test func companionStatusUsesOnlyRuntimeSupportAndReadsConfiguredMetadataWithoutCredentials() throws {
    let f = StatusFixture(); defer { try? FileManager.default.removeItem(at: f.support) }; try f.prepare()
    let hostile = f.support.appendingPathComponent("untrusted.sqlite")
    try Data("Invented unrelated file".utf8).write(to: hostile)
    let reply = try f.call(extra: [("database", .string(hostile.path)), ("support", .string(hostile.path)), ("binder", .string(hostile.path))])
    #expect(reply == .obj([("ok", .bool(true)), ("state", .str("pending"))]))
    #expect(try Data(contentsOf: hostile) == Data("Invented unrelated file".utf8))
}

@Test func companionStatusFailureIsOpaqueAndCannotReplaceBrokenSavedState() throws {
    let f = StatusFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    try FileManager.default.createDirectory(at: f.database.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bytes = Data("Invented broken profile".utf8); try bytes.write(to: f.database)
    let reply = try f.call()
    #expect(reply == .obj([("ok", .bool(false)), ("error", .str("Phone access state is unavailable."))]))
    #expect(try Data(contentsOf: f.database) == bytes)
}

import BinderStore
import Companion
import Foundation
import Shelf
import SpravaKit
import SQLite3
import Testing
@testable import Services

private final class SwitchSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
    func binderKeys() -> [Data] { lock.lock(); defer { lock.unlock() }; return values.filter { $0.key.contains(":binder-key-v0:") }.map(\.value) }
}

/// An invented support folder with one adopted binder on the Shelf that this Mac ("mac-a") owns.
private struct SwitchFixture {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-phone-switch-" + UUID().uuidString)
    let secrets = SwitchSecrets()
    var database: URL { support.appendingPathComponent("companion/state.sqlite") }
    var binder: URL { support.appendingPathComponent("Invented Garden", isDirectory: true) }

    func makeBinder(at folder: URL, owner: String = "mac-a", onShelf: Bool = true) throws {
        let state = folder.appendingPathComponent(".sprava", isDirectory: true)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        try Data("{}\n".utf8).write(to: state.appendingPathComponent("ops.ndjson"))
        try Data(#"{"device":"\#(owner)"}"#.utf8).write(to: state.appendingPathComponent("owner.json"))
        if onShelf { try ShelfStore(supportDirectory: support).add(folder) }
    }
    /// A prepared account whose relay claim succeeded; the claim itself is Companion's to test.
    func claim() throws {
        _ = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: secrets).prepareAccount()
        var db: OpaquePointer?
        #expect(sqlite3_open(database.path, &db) == SQLITE_OK)
        #expect(sqlite3_exec(db, "UPDATE profile SET claim_state = 'claimed' WHERE slot = 1", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
    }
    func requests() throws -> CompanionRuntimeRequests {
        try CompanionRuntimeRequests(database: database, secrets: secrets, watch: nil,
                                     binders: CompanionBinderSwitch(support: support, deviceID: "mac-a"))
    }
    func status(_ folder: URL? = nil) throws -> JSONValue {
        let request = JSONWriter.compact(.obj([("command", .str("companion_binder_status")), ("binder", .str((folder ?? binder).path))]))
        return try JSONParser.parse(Commands(support: support, deviceID: "mac-a").handle(request)).value
    }
    func sharing(_ folder: URL? = nil) throws -> CompanionBinderSharing? {
        guard let identity = try CompanionBinderIdentities(support: support).existing(for: folder ?? binder) else { return nil }
        return try CompanionProfile.openConfigured(database: database, secrets: secrets)?.binderSharing(identity)
    }
}

private func send(_ requests: CompanionRuntimeRequests, _ command: String, _ folder: URL) async throws -> JSONValue {
    let body = JSONWriter.compact(.obj([("command", .str(command)), ("binder", .str(folder.path))]))
    let answer = await withCheckedContinuation { continuation in
        requests.requests.submit(body) { answer, _, _ in continuation.resume(returning: answer) }
    }
    return try JSONParser.parse(answer).value
}

@Test func aBinderIdentityIsRandomStableAndBelongsToItsFolderOnly() throws {
    let f = SwitchFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    let identities = CompanionBinderIdentities(support: f.support)
    let other = f.support.appendingPathComponent("Invented Shed", isDirectory: true)
    try FileManager.default.createDirectory(at: f.binder, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    #expect(try identities.recorded(for: f.binder) == nil)
    _ = try identities.identity(for: f.binder)
    let first = try #require(try CompanionBinderIdentities(support: f.support).recorded(for: f.binder.appendingPathComponent(".")))
    #expect(first.count == 16 && first != Data(repeating: 0, count: 16))
    _ = try identities.identity(for: f.binder)
    #expect(try identities.recorded(for: f.binder) == first)
    _ = try identities.identity(for: other)
    #expect(try identities.recorded(for: other) != first)
}

@Test func showingHidingAndShowingAgainGivesTheBinderANewPhoneIdAndKey() async throws {
    let f = SwitchFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    try f.makeBinder(at: f.binder); try f.claim()
    let requests = try f.requests()
    #expect(try f.status() == .obj([("ok", .bool(true)), ("shown", .bool(false)), ("available", .bool(true))]))

    #expect(try await send(requests, "companion_binder_show", f.binder) == .obj([("ok", .bool(true)), ("shown", .bool(true))]))
    let first = try #require(try f.sharing())
    #expect(first.state == .shown && f.secrets.binderKeys().count == 1)
    #expect(try f.status()["shown"] == .bool(true))

    #expect(try await send(requests, "companion_binder_hide", f.binder) == .obj([("ok", .bool(true)), ("shown", .bool(false))]))
    #expect(try f.sharing() == nil)
    #expect(try f.status()["shown"] == .bool(false))

    #expect(try await send(requests, "companion_binder_show", f.binder)["shown"] == .bool(true))
    let second = try #require(try f.sharing())
    let keys = f.secrets.binderKeys()
    #expect(second.id != first.id && keys.count == 2 && keys[0] != keys[1])
}

@Test func onlyAnAdoptedShelfBinderThisMacOwnsCanBeShown() async throws {
    let f = SwitchFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    try f.claim()
    let elsewhere = f.support.appendingPathComponent("Invented Loft", isDirectory: true)
    let foreign = f.support.appendingPathComponent("Invented Barn", isDirectory: true)
    try f.makeBinder(at: elsewhere, onShelf: false)
    try f.makeBinder(at: foreign, owner: "mac-b")
    let requests = try f.requests()
    for folder in [elsewhere, foreign] {
        let answer = try await send(requests, "companion_binder_show", folder)
        #expect(answer["ok"] == .bool(false))
        #expect(answer["error"] == .string(CompanionPhoneActionError.notShowable.message))
        #expect(try CompanionBinderIdentities(support: f.support).existing(for: folder) == nil)
    }
    #expect(f.secrets.binderKeys().isEmpty)
}

@Test func theSwitchStaysOffUntilARelayIsClaimed() async throws {
    let f = SwitchFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    try f.makeBinder(at: f.binder)
    #expect(try f.status() == .obj([("ok", .bool(true)), ("shown", .bool(false)), ("available", .bool(false))]))
    let answer = try await send(try f.requests(), "companion_binder_show", f.binder)
    #expect(answer["error"] == .string(CompanionPhoneActionError.notSetUp.message))
    #expect(f.secrets.binderKeys().isEmpty)
}

@Test func anotherBinderPutWhereAShownOneWasStartsWithItsSwitchOff() async throws {
    let f = SwitchFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    try f.makeBinder(at: f.binder); try f.claim()
    let requests = try f.requests()
    #expect(try await send(requests, "companion_binder_show", f.binder)["shown"] == .bool(true))
    let old = try CompanionLocalBinderIdentity(bytes: try #require(try CompanionBinderIdentities(support: f.support).recorded(for: f.binder)))
    // While the runtime is stopped, the shown binder is moved away and another binder of this Mac takes its folder name.
    try FileManager.default.moveItem(at: f.binder, to: f.support.appendingPathComponent("Invented Garden Away", isDirectory: true))
    try f.makeBinder(at: f.binder, onShelf: false)
    #expect(try f.status()["shown"] == .bool(false))
    #expect(try f.sharing() == nil)
    // Showing the newcomer switches the old identity off and gives this folder a new one.
    #expect(try await send(requests, "companion_binder_show", f.binder)["shown"] == .bool(true))
    let profile = try #require(try CompanionProfile.openConfigured(database: f.database, secrets: f.secrets))
    #expect(try profile.binderSharing(old) == nil)
    #expect(try f.sharing()?.state == .shown)
}

@Test func aMovedBinderComesBackWithItsSwitchOff() async throws {
    let f = SwitchFixture(); defer { try? FileManager.default.removeItem(at: f.support) }
    try f.makeBinder(at: f.binder); try f.claim()
    #expect(try await send(try f.requests(), "companion_binder_show", f.binder)["shown"] == .bool(true))
    let moved = f.support.appendingPathComponent("Invented Garden Moved", isDirectory: true)
    try FileManager.default.moveItem(at: f.binder, to: moved)
    try ShelfStore(supportDirectory: f.support).add(moved)
    #expect(try f.status(moved)["shown"] == .bool(false))
    // Hiding a binder that was never shown answers "off" without touching the relay state.
    #expect(try await send(try f.requests(), "companion_binder_hide", moved) == .obj([("ok", .bool(true)), ("shown", .bool(false))]))
}

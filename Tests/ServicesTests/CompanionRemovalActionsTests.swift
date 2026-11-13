import Foundation
import SpravaKit
import Testing
@testable import Companion
@testable import Services

private final class RemovalActionSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[account] == nil else { return false }; entries[account] = bytes; return true
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: account) }
}
/// Scripted relay steps: the handler's loop, not the domain, is under test here.
private final class ScriptedSteps: @unchecked Sendable {
    private let lock = NSLock()
    var script: [CompanionRotationProgress] = []
    private(set) var calls = 0
    func next() throws -> CompanionRotationProgress {
        lock.lock(); defer { lock.unlock() }
        calls += 1
        return script.isEmpty ? .idle : script.removeFirst()
    }
}
private let removedPhone = Data(repeating: 5, count: 16).base64EncodedString()
    .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")

private struct RemovalActionFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-removal-actions-" + UUID().uuidString)
    let secrets = RemovalActionSecrets()
    let steps = ScriptedSteps()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func profile() throws -> CompanionProfile {
        let p = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"), secrets: secrets)
        _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        try p.store.write { t in
            try t.execute("INSERT OR IGNORE INTO devices (device, state, key_ready, creation_attempted, cleanup_pending) VALUES (?, 'active', 0, 1, 0)",
                          .text(removedPhone))
            try t.execute("INSERT OR IGNORE INTO pairings (device, pairing, expires, label) VALUES (?, ?, '2099-01-01T00:00:00Z', 'Invented phone')",
                          .text(removedPhone), .text(String(removedPhone.reversed())))
        }
        _ = try secrets.insert(account: p.deviceAccount(removedPhone), bytes: Data(repeating: 6, count: 32))
        return p
    }
    func run(_ command: String, _ fields: [(String, JSONValue)] = []) async throws -> JSONObject {
        let steps = self.steps
        let session = CompanionOwnerSession(database: database, secrets: secrets, recover: { _ in .claimed },
                                            rotation: { _ in { try steps.next() } })
        let handler = try #require(CompanionPhoneActions.handlers(session: session)[command])
        return try await handler(JSONObject([("command", .str(command))] + fields))
    }
}

@Test func removingAPhoneRevokesItAtOnceDeletesItsKeyAndMakesAtMostThreeRelayCalls() async throws {
    let f = RemovalActionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.profile()
    f.steps.script = [.rotated(epoch: 2), .deleted(deviceID: removedPhone), .uploaded(deviceID: "b"), .uploaded(deviceID: "c"),
                      .uploaded(deviceID: "d")]
    let reply = try await f.run("companion_device_remove", [("device_id", .string(removedPhone))])
    #expect(f.steps.calls == 4) // the local rotation, then three relay calls
    #expect(reply["state"] == .str("removed"))
    #expect(try p.deviceRecords().first?.state == .revoked)
    #expect(try f.secrets.read(account: p.deviceAccount(removedPhone)) == nil)
    // The scripted relay confirmed nothing, so the phone stays listed as removed here and the work as pending.
    #expect(reply["removed"] == .array([.obj([("device_id", .string(removedPhone)), ("label", .str("Invented phone"))])]))
    #expect(reply["relay_pending"] == .bool(true) && reply["relay_fault"] == .bool(false))
    // Retry: removing it again is the same removal, and continues the relay work.
    f.steps.script = [.idle]
    #expect(try await f.run("companion_device_remove", [("device_id", .string(removedPhone))])["state"] == .str("removed"))
    #expect(f.steps.calls == 5)
}

@Test func aRefusedKeysObjectStopsTheStepsAndOnlyThePersonsRetryRotatesAgain() async throws {
    let f = RemovalActionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.profile()
    f.steps.script = [.rotated(epoch: 2), .refused(deviceID: "b"), .uploaded(deviceID: "c")]
    _ = try await f.run("companion_device_remove", [("device_id", .string(removedPhone))])
    #expect(f.steps.calls == 2)
    try p.store.write { t in
        try t.execute("INSERT INTO devices (device, state, key_ready, creation_attempted, cleanup_pending) VALUES ('BwcHBwcHBwcHBwcHBwcHBw', 'abandoned', 0, 1, 0)")
        try t.execute("INSERT INTO rotation_keys VALUES (1, 'BwcHBwcHBwcHBwcHBwcHBw', 'refused', ?)", .blob(Data([1])))
        try t.execute("UPDATE rotation_state SET pending = 0") // as if that rotation had run and its upload was refused
    }
    #expect(try !p.rotationPending())
    #expect(try await f.run("companion_devices")["relay_fault"] == .bool(true))
    f.steps.script = [.idle]
    let retried = try await f.run("companion_relay_retry")
    #expect(retried["state"] == .str("checked"))
    #expect(try p.rotationPending())
}

@Test func removalRefusesAnUnknownPhoneAndOneWithAnActionBeingApplied() async throws {
    let f = RemovalActionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let p = try f.profile()
    await #expect(throws: CompanionPhoneActionError.deviceUnknown) {
        try await f.run("companion_device_remove", [("device_id", .str("BwcHBwcHBwcHBwcHBwcHBw"))])
    }
    try p.store.write { t in
        try t.execute("INSERT INTO request_decisions VALUES (?, 'invented-request', ?)", .text(removedPhone), .blob(Data([1])))
    }
    await #expect(throws: CompanionPhoneActionError.removalWaiting) {
        try await f.run("companion_device_remove", [("device_id", .string(removedPhone))])
    }
    #expect(try p.deviceRecords().first?.state == .active && f.steps.calls == 0)
    await #expect(throws: CompanionPhoneActionError.invalidRequest) { try await f.run("companion_device_remove") }
}

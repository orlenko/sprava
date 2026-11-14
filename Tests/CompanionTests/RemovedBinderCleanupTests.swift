import Foundation
import Testing
@testable import Companion
import SpravaKit

private final class CleanupSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var values: [String: Data] = [:]
    var failRemove = false
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }; values[account] = bytes; return true
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if failRemove { throw CompanionCredentialError.unavailable }
        values.removeValue(forKey: account)
    }
}
private actor CleanupTransport: OwnerPublicationTransport {
    var statuses: [Int]
    var calls: [String] = []
    init(_ statuses: [Int]) { self.statuses = statuses }
    func putObject(name: String, bytes: Data) async throws -> Int { calls.append("PUT " + name); return next() }
    func deleteObject(name: String) async throws -> Int { calls.append("DELETE " + name); return next() }
    private func next() -> Int { statuses.isEmpty ? 204 : statuses.removeFirst() }
    func script(_ more: [Int]) { statuses += more }
    func recorded() -> [String] { calls }
}
private struct CleanupFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-cleanup-" + UUID().uuidString)
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    let secrets = CleanupSecrets()
    let local = try! CompanionLocalBinderIdentity(bytes: Data(repeating: 61, count: 16))
    func prepare() throws -> (CompanionProfile, String) {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 23, count: 32).base64EncodedString())
        let p = try CompanionProfile(database: folder.appendingPathComponent("state.sqlite"), relay: relay, secrets: secrets)
        _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        return (p, try p.showBinder(local).id)
    }
    func reading() -> CompanionViewReading {
        CompanionViewReading(name: "Invented binder", today: "2026-11-13", generatedAt: "2026-11-13T09:00:00Z",
            openItems: [.object(JSONObject([("id", .string("a1")), ("title", .string("Water the invented plants"))]))])
    }
}

/// Two published versions of a shown binder, then the switch turned off.
private func publishTwiceThenHide(_ f: CleanupFixture, _ p: CompanionProfile, _ id: String, _ publisher: CompanionOwnerPublication) async throws {
    for _ in 0..<2 {
        _ = try p.prepareView(binderID: id, reading: f.reading())
        _ = try await publisher.uploadView(binderID: id)
    }
    _ = try await publisher.uploadIndex(generatedAt: "2026-11-13T09:00:00Z")
    try await publisher.hideBinder(f.local)
}

@Test func aSwitchedOffBinderLosesItsViewsAndKeyOnlyBehindAnIndexWithoutIt() async throws {
    let f = CleanupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), account = p.binderKeyAccount(id, epoch: 1)
    let transport = CleanupTransport([])
    let publisher = CompanionOwnerPublication(profile: p, transport: transport, now: { "2026-11-13T09:00:00Z" })
    try await publishTwiceThenHide(f, p, id, publisher)
    // The last published index still names the binder: nothing is deleted yet.
    #expect(try await publisher.cleanRemovedBinders(limit: 50) == 0)
    #expect(f.secrets.values[account] != nil)
    _ = try await publisher.uploadIndex(generatedAt: "2026-11-13T09:01:00Z")
    #expect(try await publisher.cleanRemovedBinders(limit: 50) == 2)
    #expect(await transport.recorded().suffix(2) == ["DELETE views/\(id)/1", "DELETE views/\(id)/2"])
    #expect(f.secrets.values[account] == nil)
    #expect(try await publisher.cleanRemovedBinders(limit: 50) == 0)
}

@Test func aFailedDeletionKeepsTheKeyAndTheNextRunResumesAtTheSameVersion() async throws {
    let f = CleanupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), account = p.binderKeyAccount(id, epoch: 1)
    let transport = CleanupTransport([])
    let publisher = CompanionOwnerPublication(profile: p, transport: transport, now: { "2026-11-13T09:00:00Z" })
    try await publishTwiceThenHide(f, p, id, publisher)
    _ = try await publisher.uploadIndex(generatedAt: "2026-11-13T09:01:00Z")
    await transport.script([204, 503])
    await #expect(throws: CompanionOwnerConnectionError.relayRejected(503)) { try await publisher.cleanRemovedBinders(limit: 50) }
    #expect(f.secrets.values[account] != nil)
    // A key that cannot be removed also keeps the cleanup scheduled.
    f.secrets.failRemove = true
    await #expect(throws: CompanionCredentialError.unavailable) { try await publisher.cleanRemovedBinders(limit: 50) }
    #expect(f.secrets.values[account] != nil)
    f.secrets.failRemove = false
    #expect(try await publisher.cleanRemovedBinders(limit: 50) == 0)
    #expect(await transport.recorded().filter { $0.hasPrefix("DELETE") } ==
            ["DELETE views/\(id)/1", "DELETE views/\(id)/2", "DELETE views/\(id)/2"])
    #expect(f.secrets.values[account] == nil)
}

@Test func cleanupSendsAtMostItsLimitPerRun() async throws {
    let f = CleanupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let (p, id) = try f.prepare(), account = p.binderKeyAccount(id, epoch: 1)
    let transport = CleanupTransport([])
    let publisher = CompanionOwnerPublication(profile: p, transport: transport, now: { "2026-11-13T09:00:00Z" })
    try await publishTwiceThenHide(f, p, id, publisher)
    _ = try await publisher.uploadIndex(generatedAt: "2026-11-13T09:01:00Z")
    #expect(try await publisher.cleanRemovedBinders(limit: 1) == 1)
    #expect(f.secrets.values[account] != nil)
    #expect(try await publisher.cleanRemovedBinders(limit: 1) == 1)
    #expect(f.secrets.values[account] == nil)
}

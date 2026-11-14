import BinderStore
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing
@testable import Companion
@testable import Services

private final class RotationSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}
/// Accepts every upload, as the relay does after a `204`, and records what was published.
private actor RotationTarget: CompanionPublishingTarget, CompanionOutcomesTarget {
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
    func cleanRemovedBinders(limit: Int) async throws -> Int { 0 }
    func uploadOutcomes(deviceID: String, generatedAt: String) async throws -> CompanionPublicationProgress { .idle }
    func taken() -> [String] { defer { calls = [] }; return calls }
}
/// The relay for keys objects and device deletions: answers every PUT with `status`.
private actor KeysRelay: OwnerRotationTransport {
    let status: Int
    var names: [String] = []
    init(status: Int) { self.status = status }
    func putObject(name: String, bytes: Data) async throws -> Int { names.append(name); return status }
    func deleteDevice(deviceID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        CompanionRelayReply(status: 204, value: nil, receivedBytes: 0)
    }
}
/// An empty mailbox: the drain finds nothing to decide.
private struct EmptyMailbox: RequestCollectionTransport {
    func listRequests(deviceID: String, after: Int64?, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestPage> {
        CompanionRelayReply(status: 200, value: CompanionRequestPage(requests: [], next: nil), receivedBytes: 10)
    }
    func fetchRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<CompanionRequestDownload> {
        CompanionRelayReply(status: 404, value: nil, receivedBytes: 0)
    }
    func deleteRequest(deviceID: String, requestID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        CompanionRelayReply(status: 204, value: nil, receivedBytes: 0)
    }
}

private let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
private let morning = Date(timeIntervalSince1970: 1_794_560_400) // 2026-11-13T09:00:00Z
private let mac = "019a2000-0000-7000-8000-0000000000b1"
private let phone = CompanionWire.base64(Data(repeating: 51, count: 16))

/// A claimed relay, one paired phone with its key, and one invented binder shown on it and published at epoch 1.
private struct RotationFixture {
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-rotation-job-" + UUID().uuidString)
    let secrets = RotationSecrets()
    let binder: URL
    let publishing: CompanionPublishing
    let draining: CompanionDraining

    init() async throws {
        binder = try makeTeka(fixture: "sprava-v0", folderName: "invented-rotation")
        try TekaStore(folder: binder).adopt(survey: JSONObject(), owner: JSONObject([("device", .string(mac))]), now: morning)
        try ShelfStore(supportDirectory: support).add(binder)
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 31, count: 32).base64EncodedString())
        publishing = CompanionPublishing(support: support, deviceID: mac)
        draining = CompanionDraining(support: support, deviceID: mac) { profile, locks in
            CompanionOwnerDeviceTurn(profile: profile, locks: locks, transport: EmptyMailbox())
        }
        let p = try profile()
        _ = try p.prepareAccount()
        try p.store.write { t in
            try t.execute("UPDATE profile SET claim_state = 'claimed' WHERE slot = 1")
            try t.execute("INSERT INTO devices (device, state, key_ready, creation_attempted, cleanup_pending, local_deadline) " +
                          "VALUES (?, 'active', 1, 1, 0, '2099-01-01T00:00:00Z')", .text(phone))
            try t.execute("INSERT INTO pairings (device, pairing, expires, label, paired_at, acknowledged, key_epoch, wrapped_key, device_keys) " +
                          "VALUES (?, ?, '2099-01-01T00:00:00Z', 'Invented phone', '2026-11-13T08:00:00Z', 1, 1, ?, ?)",
                          .text(phone), .text(CompanionWire.base64(Data(repeating: 52, count: 16))), .blob(Data([1])), .blob(Data([2])))
        }
        _ = try secrets.insert(account: p.deviceAccount(phone), bytes: Data(repeating: 53, count: 32))
        _ = try p.showBinder(try CompanionBinderIdentities(support: support).identity(for: binder))
        try await cycle(RotationTarget(p), rotation: { .idle })
    }
    func profile() throws -> CompanionProfile { try CompanionProfile(database: support.appendingPathComponent("companion/state.sqlite"), relay: relay, secrets: secrets) }
    func cycle(_ target: RotationTarget, rotation: @escaping @Sendable () async throws -> CompanionRotationProgress) async throws {
        try await CompanionJob.cycle(publishing: publishing, draining: draining, profile: profile(), locks: CompanionDeviceDecisionLocks(),
            target: target, rotation: rotation, rows: ShelfStore(supportDirectory: support).rowsForJobs(), timeZone: utc, clock: { morning })
    }
    func viewEpochs() throws -> [Int64] {
        try profile().store.read { try $0.rows("SELECT epoch FROM phone_views WHERE state = 'uploaded' ORDER BY version") }.compactMap { $0.first?.integer }
    }
    func remove() { try? FileManager.default.removeItem(at: support); try? FileManager.default.removeItem(at: binder.deletingLastPathComponent()) }
}

@Test func publicationWaitsForTheNewKeysAndThenGivesEachShownBinderAViewAtTheNewEpoch() async throws {
    let f = try await RotationFixture(); defer { f.remove() }
    #expect(try f.viewEpochs() == [1])
    let p = try f.profile(), target = RotationTarget(p)
    _ = await target.taken()
    // A removal asked for a rotation; nothing has stepped it yet, so nothing may be published at the old epoch.
    try p.requestRotation()
    try await f.cycle(target, rotation: { .idle })
    #expect(await target.taken().isEmpty)
    // The job steps the rotation until idle: new epoch, the phone's keys delivered, then the binder republished at it.
    let keys = KeysRelay(status: 204), worker = CompanionOwnerRotation(profile: p, transport: keys, now: { "2026-11-13T09:00:00Z" })
    try await f.cycle(target, rotation: { try await worker.step() })
    #expect(await keys.names == ["devices/\(phone)/keys/2"])
    #expect(try p.currentAccount()?.number == 2 && !(try p.rotationBlocksPublication()))
    #expect(try f.viewEpochs() == [1, 2])
    #expect(await target.taken() == ["view", "index"])
}

@Test func keysTheRelayRefusesHoldPublicationAndNameTheFaultOnHealth() async throws {
    let f = try await RotationFixture(); defer { f.remove() }
    let p = try f.profile(), target = RotationTarget(p)
    _ = await target.taken()
    try p.requestRotation()
    let worker = CompanionOwnerRotation(profile: p, transport: KeysRelay(status: 409), now: { "2026-11-13T09:00:00Z" })
    await #expect(throws: CompanionJobFault.rotationRefused) { try await f.cycle(target, rotation: { try await worker.step() }) }
    #expect(await target.taken().isEmpty)
    #expect(try f.viewEpochs() == [1])
    // The job turns the fault into the code Health shows, after its work: a fixed word, no label or title.
    let database = f.support.appendingPathComponent("companion/state.sqlite")
    let job = CompanionJob(session: CompanionOwnerSession(database: database, secrets: f.secrets, recover: { _ in .claimed })) { _ in
        throw CompanionJobFault.rotationRefused
    }
    #expect(await job.run() == .error(code: "companion_rotation_refused", culprit: nil))
    // Retry on the Phone page rotates again with keys the relay takes; the fault clears and the next run publishes.
    let accepting = CompanionOwnerRotation(profile: p, transport: KeysRelay(status: 204), now: { "2026-11-13T09:00:00Z" })
    let session = CompanionOwnerSession(database: database, secrets: f.secrets, recover: { _ in .claimed },
                                        rotation: { _ in { try await accepting.step() } })
    let retry = try #require(CompanionRemovalActions.handlers(session: session)["companion_relay_retry"])
    let reply = try await retry(JSONObject([("command", .str("companion_relay_retry"))]))
    #expect(reply["relay_fault"] == .bool(false) && reply["relay_pending"] == .bool(false))
    try await f.cycle(target, rotation: { try await accepting.step() })
    #expect(try p.currentAccount()?.number == 3)
    #expect(try f.viewEpochs() == [1, 3])
    #expect(await target.taken() == ["view", "index"])
}

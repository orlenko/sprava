import CryptoKit
import Foundation
import Testing
@testable import Companion

private final class ClaimSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if values[account] != nil { return false }
        values[account] = bytes; return true
    }
}
private let claimInstance = "0123456789abcdef0123456789abcdef"
private struct ClaimFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-claim-" + UUID().uuidString)
    let secrets = ClaimSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: claimInstance)
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func profile() throws -> CompanionProfile { try CompanionProfile(database: database, relay: relay, secrets: secrets) }
    func prepare() throws -> CompanionProfile {
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 17, count: 32).base64EncodedString())
        let p = try profile(); _ = try p.prepareAccount(); return p
    }
}
private actor ClaimRelay: OwnerClaimTransport {
    enum Step: Sendable {
        case health(Bool, String = claimInstance)
        case claim(Int)
        case failHealth
        case lostClaim
        case holdHealth
    }
    private var steps: [Step]
    private var calls: [String] = []
    private var bodies: [Data] = []
    private var held: CheckedContinuation<Void, Never>?
    init(_ steps: [Step]) { self.steps = steps }
    func snapshot() -> ([String], [Data]) { (calls, bodies) }
    func isHeld() -> Bool { held != nil }
    func release() { held?.resume(); held = nil }
    func health() async throws -> CompanionRelayReply<CompanionRelayHealth> {
        calls.append("health")
        guard !steps.isEmpty else { throw CompanionRelayError.invalid }
        switch steps.removeFirst() {
        case .health(let claimed, let instance):
            return CompanionRelayReply(status: 200, value: CompanionRelayHealth(instance: instance, claimed: claimed))
        case .holdHealth:
            await withCheckedContinuation { held = $0 }
            return CompanionRelayReply(status: 200, value: CompanionRelayHealth(instance: claimInstance, claimed: true))
        case .failHealth: throw CompanionRelayError.invalid
        default: Issue.record("Unexpected health request"); throw CompanionRelayError.invalid
        }
    }
    func claim(_ body: Data) async throws -> Int {
        calls.append("claim"); bodies.append(body)
        guard !steps.isEmpty else { throw CompanionRelayError.invalid }
        switch steps.removeFirst() {
        case .claim(let status): return status
        case .lostClaim: throw CompanionRelayError.invalid
        default: Issue.record("Unexpected claim request"); throw CompanionRelayError.invalid
        }
    }
}

@Test func aLostClaimResponseReusesTheRecordedBodyAfterRestart() async throws {
    let f = ClaimFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try f.prepare()
    let relay = ClaimRelay([.health(false), .lostClaim, .health(true), .claim(204), .health(true)])
    let first = try CompanionOwnerConnection(profile: profile, transport: relay)
    await #expect(throws: CompanionRelayError.invalid) { try await first.recoverClaim() }
    #expect(try profile.ownerClaimState() == .pending)
    let restarted = try CompanionOwnerConnection(profile: f.profile(), transport: relay)
    #expect(try await restarted.recoverClaim() == .claimed)
    let (calls, bodies) = await relay.snapshot()
    #expect(calls == ["health", "claim", "health", "claim", "health"])
    let stored = try #require(try CompanionOwnerVault(backend: f.secrets).load(f.relay))
    #expect(bodies == [stored.claimBody, stored.claimBody])
    #expect(try f.profile().ownerClaimState() == .claimed)
    // Neither the setup code nor the owner token is written into SQLite.
    let raw = try Data(contentsOf: f.database)
    #expect(raw.range(of: stored.claimBody) == nil && raw.range(of: Data(stored.ownerToken.utf8)) == nil)
}

@Test func claimRequiresBothAcknowledgmentAndHealthAndRetriesOncePerCall() async throws {
    let f = ClaimFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try f.prepare()
    let relay = ClaimRelay([.health(true), .claim(503), .health(false), .claim(204), .health(false),
                            .health(false), .claim(204), .health(true)])
    let connection = try CompanionOwnerConnection(profile: profile, transport: relay)
    await #expect(throws: CompanionOwnerConnectionError.relayRejected(503)) { try await connection.recoverClaim() }
    #expect(try profile.ownerClaimState() == .pending)
    #expect(try await connection.recoverClaim() == .pending)
    #expect(try await connection.recoverClaim() == .claimed)
    #expect(await relay.snapshot().1.count == 3)
}

@Test func refusedOwnerTokenWithUnclaimedHealthReplaysTheSameClaim() async throws {
    let f = ClaimFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try f.prepare(); try profile.recordClaimState(.claimed)
    let relay = ClaimRelay([.health(false), .claim(204), .health(true)])
    let connection = try CompanionOwnerConnection(profile: profile, transport: relay)
    #expect(try await connection.ownerTokenRefused() == .claimed)
    #expect(await relay.snapshot().0 == ["health", "claim", "health"])
}

@Test func aRefusedTokenIsDurableEvenIfTheHealthCheckFails() async throws {
    let f = ClaimFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try f.prepare(); try profile.recordClaimState(.claimed)
    let relay = ClaimRelay([.failHealth, .health(true), .health(false)])
    let first = try CompanionOwnerConnection(profile: profile, transport: relay)
    await #expect(throws: CompanionRelayError.invalid) { try await first.ownerTokenRefused() }
    #expect(try f.profile().ownerClaimState() == .checkingRefusal)
    let restarted = try CompanionOwnerConnection(profile: f.profile(), transport: relay)
    #expect(try await restarted.recoverClaim() == .needsReset)
    #expect(try await restarted.recoverClaim() == .needsReset)
    #expect(await relay.snapshot().0 == ["health", "health", "health"])
}

@Test func conflictingClaimAndChangedInstanceRetireTheProfileWithoutRebindingOrDeletingKeys() async throws {
    for changedInstance in [false, true] {
        let f = ClaimFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
        let profile = try f.prepare(), key = try #require(try profile.currentAccount()).key
        let relay = ClaimRelay(changedInstance ? [.health(false, "fedcba9876543210fedcba9876543210"), .health(false)] :
                               [.health(false), .claim(409), .health(false)])
        let first = try CompanionOwnerConnection(profile: profile, transport: relay)
        let expected: CompanionOwnerClaimState = changedInstance ? .instanceChanged : .needsReset
        #expect(try await first.recoverClaim() == expected)
        let reopened = try f.profile()
        let restarted = try CompanionOwnerConnection(profile: reopened, transport: relay)
        #expect(try await restarted.recoverClaim() == expected)
        #expect(try reopened.recordClaimState(.claimed) == expected)
        #expect(try reopened.currentAccount()?.key.withUnsafeBytes { Data($0) } == key.withUnsafeBytes { Data($0) })
        #expect(await relay.snapshot().1.count == (changedInstance ? 0 : 1))
    }
}

@Test func overlappingRecoveryIsRefusedAndALateSuccessCannotEraseARecordedRefusal() async throws {
    let f = ClaimFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try f.prepare()
    let relay = ClaimRelay([.health(false), .claim(204), .holdHealth, .health(true)])
    let connection = try CompanionOwnerConnection(profile: profile, transport: relay)
    let running = Task { try await connection.recoverClaim() }
    let end = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await relay.isHeld()), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(1)) }
    #expect(await relay.isHeld())
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await connection.recoverClaim() }
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await connection.ownerTokenRefused() }
    try f.profile().recordClaimState(.checkingRefusal)
    await relay.release()
    #expect(try await running.value == .checkingRefusal)
    #expect(try await connection.recoverClaim() == .needsReset)
}

@Test func ownerConnectionRequiresExistingCredentialsAndAccountWithoutCreatingOrReplacingThem() throws {
    let f = ClaimFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try f.profile()
    #expect(throws: CompanionCredentialError.unavailable) { try CompanionOwnerConnection(profile: profile) }
    #expect(try profile.currentAccount() == nil)
    _ = try profile.prepareAccount()
    #expect(throws: CompanionCredentialError.unavailable) { try CompanionOwnerConnection(profile: profile) }
    _ = try f.prepare()
    _ = try CompanionOwnerConnection(profile: profile)
}

import Companion
import Foundation
import Testing
@testable import Services

private enum OwnerSessionFixtureError: Error { case unexpectedCredentials, transport }
private struct OwnerSessionForbiddenSecrets: CompanionCredentialStorage {
    func read(account: String) throws -> Data? { throw OwnerSessionFixtureError.unexpectedCredentials }
    func insert(account: String, bytes: Data) throws -> Bool { throw OwnerSessionFixtureError.unexpectedCredentials }
}
private final class OwnerSessionFixtureSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
private struct OwnerSessionFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-owner-session-" + UUID().uuidString)
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func prepare() throws {
        let profile = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: OwnerSessionFixtureSecrets())
        _ = try profile.prepareAccount()
    }
}
private actor OwnerSessionCounter {
    private(set) var calls = 0
    func recover() throws -> CompanionOwnerClaimState {
        calls += 1
        if calls == 1 { throw OwnerSessionFixtureError.transport }
        return .claimed
    }
}
private actor OwnerSessionPause {
    private var entered = false, opened = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        if opened { return }
        await withCheckedContinuation { continuation in
            release = continuation; entered = true; observer?.resume(); observer = nil
        }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func open() { opened = true; release?.resume(); release = nil }
}

@Test func anUnconfiguredOwnerSessionDoesNoCredentialOrNetworkWork() async throws {
    let f = OwnerSessionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let session = CompanionOwnerSession(database: f.database, secrets: OwnerSessionForbiddenSecrets(), recover: { _ in
        Issue.record("Unconfigured session attempted recovery"); throw OwnerSessionFixtureError.transport
    })
    #expect(try await session.snapshot() == .notConfigured)
    #expect(try await session.recoverClaim() == .notConfigured)
}

@Test func theRunningOwnerSessionDiscoversLaterSetupAndItsStatusNeverNeedsCredentials() async throws {
    let f = OwnerSessionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let session = CompanionOwnerSession(database: f.database, secrets: OwnerSessionForbiddenSecrets(), recover: { profile async throws -> CompanionOwnerClaimState in
        #expect(try profile.ownerClaimState() == .pending)
        return .claimed
    })
    #expect(try await session.snapshot() == .notConfigured)
    try f.prepare()
    #expect(try await session.snapshot() == .claim(.pending))
    #expect(try await session.recoverClaim() == .claim(.claimed))
}

@Test func ownerRecoveryRefusesOverlapButKeepsKeylessStatusAvailableAndReleasesAfterCancellation() async throws {
    let f = OwnerSessionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let pause = OwnerSessionPause()
    let session = CompanionOwnerSession(database: f.database, secrets: OwnerSessionForbiddenSecrets(), recover: { _ in
        await pause.pause(); try Task.checkCancellation(); return .claimed
    })
    let pending = Task { try await session.recoverClaim() }
    await pause.waitForEntry()
    #expect(try await session.snapshot() == .claim(.pending))
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await session.recoverClaim() }
    pending.cancel(); await pause.open()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await session.recoverClaim() == .claim(.claimed))
}

@Test func aFailedOwnerRecoveryDoesNotSuppressTheNextAttempt() async throws {
    let f = OwnerSessionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let counter = OwnerSessionCounter()
    let session = CompanionOwnerSession(database: f.database, secrets: OwnerSessionForbiddenSecrets(), recover: { _ in
        try await counter.recover()
    })
    await #expect(throws: OwnerSessionFixtureError.transport) { try await session.recoverClaim() }
    #expect(try await session.recoverClaim() == .claim(.claimed))
    #expect(await counter.calls == 2)
}


@Test func anUnconfiguredOwnerActionDoesNoCredentialOrActionWorkAndFindsLaterSetup() async throws {
    let f = OwnerSessionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let session = CompanionOwnerSession(database: f.database, secrets: OwnerSessionForbiddenSecrets(), recover: { _ in .claimed })
    let absent: String? = try await session.withConfiguredProfile { _ in
        Issue.record("An unconfigured action was invoked"); return "unexpected"
    }
    #expect(absent == nil)
    try f.prepare()
    let state = try await session.withConfiguredProfile { profile in try profile.ownerClaimState().rawValue }
    #expect(state == "pending")
}

@Test func ownerActionsExcludeSetupAndRecoveryWhileStatusRemainsReadableAndCancellationReleasesAdmission() async throws {
    let f = OwnerSessionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let pause = OwnerSessionPause()
    let session = CompanionOwnerSession(database: f.database, secrets: OwnerSessionForbiddenSecrets(), recover: { _ in .claimed },
        prepare: { _, _, _ in Issue.record("Busy action reached setup"); throw OwnerSessionFixtureError.transport })
    let pending = Task { try await session.withConfiguredProfile { _ in await pause.pause(); return 42 } }
    await pause.waitForEntry()
    #expect(try await session.snapshot() == .claim(.pending))
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await session.recoverClaim() }
    await #expect(throws: CompanionOwnerConnectionError.busy) {
        try await session.configure(origin: "https://relay.example", setupCode: "invented", webOrigin: nil)
    }
    await #expect(throws: CompanionOwnerConnectionError.busy) {
        try await session.withConfiguredProfile { _ in Issue.record("Overlapping action was invoked"); return 0 }
    }
    pending.cancel(); await pause.open()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await session.withConfiguredProfile { _ in 7 } == 7)
    #expect(try await session.recoverClaim() == .claim(.claimed))
}

@Test func ownerRecoveryExcludesOtherOwnerActionsAndErrorsReleaseTheirAdmission() async throws {
    let f = OwnerSessionFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let pause = OwnerSessionPause()
    let session = CompanionOwnerSession(database: f.database, secrets: OwnerSessionForbiddenSecrets(), recover: { _ in
        await pause.pause(); return .claimed
    })
    let recovering = Task { try await session.recoverClaim() }
    await pause.waitForEntry()
    await #expect(throws: CompanionOwnerConnectionError.busy) {
        try await session.withConfiguredProfile { _ in Issue.record("Owner action overlapped recovery"); return 0 }
    }
    await pause.open(); _ = try await recovering.value
    await #expect(throws: OwnerSessionFixtureError.transport) {
        try await session.withConfiguredProfile { _ async throws -> Int in throw OwnerSessionFixtureError.transport }
    }
    #expect(try await session.withConfiguredProfile { _ in 9 } == 9)
}

import Companion
import Foundation
import Testing
@testable import Services

private enum CompanionJobFixtureError: Error { case forbiddenCredentials, privateDetails }
private final class CompanionJobSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
}
private struct CompanionJobForbiddenSecrets: CompanionCredentialStorage {
    func read(account: String) throws -> Data? { throw CompanionJobFixtureError.forbiddenCredentials }
    func insert(account: String, bytes: Data) throws -> Bool { throw CompanionJobFixtureError.forbiddenCredentials }
}
private struct CompanionJobFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-companion-job-" + UUID().uuidString)
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func prepare() throws {
        let profile = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: CompanionJobSecrets())
        _ = try profile.prepareAccount()
    }
    func session(_ state: CompanionOwnerClaimState) -> CompanionOwnerSession {
        CompanionOwnerSession(database: database, secrets: CompanionJobForbiddenSecrets(), recover: { _ in state })
    }
}
private actor CompanionJobCalls {
    private(set) var count = 0
    func record() { count += 1 }
}
private actor CompanionJobPause {
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

@Test func aCompanionJobDoesNotRunWorkWithoutAClaimedOwner() async throws {
    let f = CompanionJobFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let calls = CompanionJobCalls()
    let disabled = CompanionJob(session: f.session(.claimed)) { _ in await calls.record() }
    #expect(await disabled.run() == .idle)
    try f.prepare()
    let cases: [(CompanionOwnerClaimState, String)] = [
        (.pending, "companion_claim_pending"), (.checkingRefusal, "companion_owner_refused"),
        (.needsReset, "companion_needs_reset"), (.instanceChanged, "companion_instance_changed")
    ]
    for (state, code) in cases {
        let job = CompanionJob(session: f.session(state)) { _ in await calls.record() }
        #expect(await job.run() == .error(code: code, culprit: nil))
    }
    #expect(await calls.count == 0)
}

@Test func companionWorkUsesTheSessionsExistingDeviceLocks() async throws {
    let f = CompanionJobFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let session = f.session(.claimed), calls = CompanionJobCalls()
    let device = "AAAAAAAAAAAAAAAAAAAAAA"
    let job = CompanionJob(session: session) { locks in
        try await locks.withLock(deviceID: device) { await calls.record() }
    }
    let outcome = try await session.deviceDecisionLocks.withLock(deviceID: device) { await job.run() }
    #expect(outcome == .skipped)
    #expect(await calls.count == 0)
    #expect(await job.run() == .ok)
    #expect(await calls.count == 1)
}

@Test func overlappingCompanionJobsAreSkippedAndCancellationReleasesTheRunSlot() async throws {
    let f = CompanionJobFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let pause = CompanionJobPause(), calls = CompanionJobCalls()
    let job = CompanionJob(session: f.session(.claimed)) { _ in
        await pause.pause(); try Task.checkCancellation(); await calls.record()
    }
    let pending = Task { await job.run() }
    await pause.waitForEntry()
    #expect(await job.run() == .skipped)
    pending.cancel(); await pause.open()
    #expect(await pending.value == .skipped)
    #expect(await calls.count == 0)
    #expect(await job.run() == .ok)
    #expect(await calls.count == 1)
}

@Test func companionJobFailuresStayOpaqueAndDoNotSuppressTheNextRun() async throws {
    let f = CompanionJobFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let calls = CompanionJobCalls()
    let job = CompanionJob(session: f.session(.claimed)) { _ in
        await calls.record()
        if await calls.count == 1 { throw CompanionJobFixtureError.privateDetails }
    }
    #expect(await job.run() == .error(code: "companion_failed", culprit: nil))
    #expect(await job.run() == .ok)
    #expect(await calls.count == 2)
}

@Test func failedOrCancelledOwnerRecoveryCannotRunCompanionWork() async throws {
    let f = CompanionJobFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }; try f.prepare()
    let calls = CompanionJobCalls(), pause = CompanionJobPause()
    let session = CompanionOwnerSession(database: f.database, secrets: CompanionJobForbiddenSecrets(), recover: { _ in
        await pause.pause(); try Task.checkCancellation()
        throw CompanionJobFixtureError.privateDetails
    })
    let job = CompanionJob(session: session) { _ in await calls.record() }
    let pending = Task { await job.run() }
    await pause.waitForEntry(); pending.cancel(); await pause.open()
    #expect(await pending.value == .skipped)
    #expect(await job.run() == .error(code: "companion_failed", culprit: nil))
    #expect(await calls.count == 0)
}

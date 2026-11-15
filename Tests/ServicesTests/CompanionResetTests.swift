import Companion
import Foundation
import SpravaKit
import Testing
@testable import Services

private final class ResetActionSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return values[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values[account] == nil else { return false }; values[account] = bytes; return true
    }
    func remove(account: String) throws { lock.lock(); defer { lock.unlock() }; values[account] = nil }
}
private actor ResetEvents {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}
private struct ResetActionFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-reset-action-" + UUID().uuidString)
    let secrets = ResetActionSecrets()
    var database: URL { root.appendingPathComponent("companion/state.sqlite") }
    func prepare() throws {
        let relay = try CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 23, count: 32).base64EncodedString())
        _ = try CompanionProfile(database: database, relay: relay, secrets: secrets).prepareAccount()
    }
    func session(deadline: Duration = .seconds(35), events: ResetEvents? = nil) -> CompanionOwnerSession {
        CompanionOwnerSession(database: database, secrets: secrets, recover: { _ in .claimed }, refuse: { _, _ in
            await events?.add("refuse")
            var report = CompanionOwnerResetReport(); report.phonesRefused = 1; report.phonesNotReached = 2; return report
        }, resetDeadlines: (deadline, .seconds(50)))
    }
    func reset(_ session: CompanionOwnerSession) async throws -> JSONObject {
        let handler = try #require(CompanionPhoneActions.handlers(session: session)["companion_reset"])
        return try await handler(JSONObject([("command", .str("companion_reset"))]))
    }
}

@Test func theResetActionForgetsTheSetupAndSaysWhatItDid() async throws {
    let f = ResetActionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try f.prepare()
    #expect(f.secrets.count == 2)
    let session = f.session()
    let reply = try await f.reset(session)
    #expect(reply["state"] == .str("not-configured"))
    #expect(reply["phones_refused"] == .int(1) && reply["phones_not_reached"] == .int(2) && reply["binders_off"] == .int(0))
    #expect(f.secrets.count == 0)
    #expect(try await session.snapshot() == .notConfigured)
    #expect(await session.generation == 1)
    // Nothing set up: the relay is not asked and nothing is set aside again.
    let again = try await f.reset(session)
    #expect(again["state"] == .str("not-configured") && again["phones_refused"] == .int(0))
    let handler = try #require(CompanionPhoneActions.handlers(session: session)["companion_reset"])
    await #expect(throws: CompanionPhoneActionError.invalidRequest) {
        _ = try await handler(JSONObject([("command", .str("companion_reset")), ("device_id", .str("x"))]))
    }
}

@Test func aResetStopsTheJobsRunBeforeItForgetsAnything() async throws {
    let f = ResetActionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try f.prepare()
    let events = ResetEvents(), session = f.session(events: events)
    let job = CompanionJob(session: session) { _ in
        await events.add("run started")
        // A relay call that ends only when cancelled.
        do { try await Task.sleep(for: .seconds(600)) } catch { await events.add("run cancelled") }
        try Task.checkCancellation()
        await events.add("run went on")
    }
    let run = Task { await job.run() }
    while await events.events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    _ = try await f.reset(session)
    #expect(await run.value == .skipped)
    #expect(await events.events == ["run started", "run cancelled", "refuse"])
    #expect(await job.run() == .idle)
}

@Test func aRunThatNeverEndsMakesTheResetAnswerBusyWithNothingChanged() async throws {
    let f = ResetActionFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    try f.prepare()
    let events = ResetEvents(), session = f.session(deadline: .milliseconds(200), events: events)
    let job = CompanionJob(session: session) { _ in
        await events.add("run started")
        // Ignores cancellation and never returns, as a call stalled below the relay client's own timeout would.
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
    }
    Task { _ = await job.run() }
    while await events.events.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    await #expect(throws: CompanionPhoneActionError.busy) { _ = try await f.reset(session) }
    #expect(await events.events == ["run started"])
    #expect(f.secrets.count == 2)
    #expect(try await session.snapshot() != .notConfigured)
    #expect(await session.generation == 0)
    // The session is free again for the next action.
    #expect(try await session.recoverClaim() == .claim(.claimed))
}

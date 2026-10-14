import Companion
import Foundation
import SpravaKit
import Testing
@testable import Services

private final class RuntimePhoneSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var calls = 0
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }; calls += 1; return entries[account]
    }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; calls += 1
        guard entries[account] == nil else { return false }; entries[account] = bytes; return true
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return calls }
}
private struct RuntimePhoneFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-runtime-phone-" + UUID().uuidString)
    let secrets = RuntimePhoneSecrets()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func profile() throws -> CompanionProfile {
        let profile = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: secrets)
        _ = try profile.prepareAccount()
        return profile
    }
}
private actor RuntimePhonePause {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        await withCheckedContinuation { release = $0; entered = true; observer?.resume(); observer = nil }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func open() { release?.resume(); release = nil }
}

@Test func constructingRuntimePhoneRequestsDoesNotOpenStateOrAccessCredentials() throws {
    let f = RuntimePhoneFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let helper = try CompanionRuntimeRequests(database: f.database, secrets: f.secrets, watch: nil)
    #expect(f.secrets.count() == 0)
    #expect(!FileManager.default.fileExists(atPath: f.folder.path))
    #expect(helper.requests.handles("companion_configure"))
    #expect(helper.requests.handles("companion_claim"))
    #expect(!helper.requests.handles("approve"))
    #expect(!helper.requests.handles("companion_status"))
}

@Test func runtimePhoneRoutingUsesOneOwnerSessionAndLeavesTheBinderQueueResponsive() async throws {
    let f = RuntimePhoneFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let pause = RuntimePhonePause()
    let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { _ in .claimed },
        prepare: { _, _, _ in await pause.pause(); return try f.profile() })
    let helper = try CompanionRuntimeRequests(session: session, watch: nil)
    #expect(helper.session === session)
    let queues = RequestQueues(watch: nil)
    let pending = Task {
        await withCheckedContinuation { continuation in
            queues.submit(#"{"command":"companion_configure","relay_origin":"https://relay.example","setup_code":"invented"}"#,
                          handle: { _ in Issue.record("Phone action reached binder writer"); return "{}" },
                          companion: helper.requests) { answer, command, _ in
                #expect(command == "companion_configure"); continuation.resume(returning: answer)
            }
        }
    }
    await pause.waitForEntry()
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await helper.session.recoverClaim() }
    let ping = await withCheckedContinuation { continuation in
        queues.submit(#"{"command":"ping"}"#, handle: { _ in
            dispatchPrecondition(condition: .onQueue(queues.commands)); return #"{"ok":true}"#
        }, companion: helper.requests) { answer, _, _ in continuation.resume(returning: answer) }
    }
    #expect(ping == #"{"ok":true}"#)
    await pause.open()
    #expect(try JSONParser.parse(await pending.value).value == .obj([("ok", .bool(true)), ("state", .str("pending"))]))
}

@Test func aTypedPhoneFailureSurvivesRuntimeRoutingAsAFixedMessage() async throws {
    let f = RuntimePhoneFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { _ in .claimed },
        prepare: { _, _, _ in throw CompanionOwnerSetupError.alreadyClaimed })
    let helper = try CompanionRuntimeRequests(session: session, watch: nil)
    let answer = await withCheckedContinuation { continuation in
        helper.requests.submit(#"{"command":"companion_configure","relay_origin":"https://relay.example","setup_code":"invented"}"#) {
            answer, command, _ in #expect(command == "companion_configure"); continuation.resume(returning: answer)
        }
    }
    let value = try JSONParser.parse(answer).value
    #expect(value["ok"] == .bool(false))
    #expect(value["error"] == .string(CompanionPhoneActionError.alreadyClaimed.message))
    #expect(f.secrets.count() == 0)
}

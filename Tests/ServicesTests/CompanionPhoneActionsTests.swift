import Companion
import Foundation
import SpravaKit
import Testing
@testable import Services

private final class PhoneSetupSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[account] == nil else { return false }; entries[account] = bytes; return true
    }
}
private struct PhoneSetupFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-phone-actions-" + UUID().uuidString)
    let secrets = PhoneSetupSecrets()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    func profile() throws -> CompanionProfile {
        let profile = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: secrets)
        _ = try profile.prepareAccount()
        return profile
    }
    var request: JSONObject {
        JSONObject([("command", .str("companion_configure")), ("relay_origin", .str("https://relay.example")),
                    ("setup_code", .string(Data(repeating: 12, count: 32).base64EncodedString())),
                    ("web_origin", .str("https://phone.example"))])
    }
}
private actor PhoneSetupPause {
    private var entered = false, opened = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pause() async {
        if opened { return }
        await withCheckedContinuation { release = $0; entered = true; observer?.resume(); observer = nil }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func open() { opened = true; release?.resume(); release = nil }
}
private struct PhoneActionTransportError: Error, CustomStringConvertible {
    var description: String { "invented-credential-and-refusal-body" }
}

@Test func configureAndClaimActionsUseTheSharedSessionAndReturnOnlyTheStableStateContract() async throws {
    let f = PhoneSetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { profile async throws -> CompanionOwnerClaimState in
        #expect(try profile.ownerClaimState() == .pending)
        return .claimed
    }, prepare: { origin, code, web in
        #expect(origin == "https://relay.example")
        #expect(code == f.request["setup_code"]?.stringValue)
        #expect(web == "https://phone.example")
        return try f.profile()
    })
    let actions = CompanionPhoneActions.handlers(session: session)
    #expect(Set(actions.keys) == ["companion_configure", "companion_claim"])
    let configure = try #require(actions["companion_configure"])
    let claim = try #require(actions["companion_claim"])
    #expect(try await configure(f.request) == JSONObject([("state", .str("pending"))]))
    #expect(try await claim(JSONObject([("command", .str("companion_claim"))])) == JSONObject([("state", .str("claimed"))]))
}

@Test func configuringPhoneAccessExcludesBackgroundRecoveryButLeavesStatusReadableAndCancellationReleasesIt() async throws {
    let f = PhoneSetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let pause = PhoneSetupPause()
    let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { _ in .claimed },
        prepare: { _, _, _ in await pause.pause(); try Task.checkCancellation(); return try f.profile() })
    let pending = Task { try await session.configure(origin: "https://relay.example", setupCode: "invented", webOrigin: nil) }
    await pause.waitForEntry()
    #expect(try await session.snapshot() == .notConfigured)
    await #expect(throws: CompanionOwnerConnectionError.busy) { try await session.recoverClaim() }
    await #expect(throws: CompanionOwnerConnectionError.busy) {
        try await session.configure(origin: "https://relay.example", setupCode: "invented", webOrigin: nil)
    }
    pending.cancel(); await pause.open()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(try await session.configure(origin: "https://relay.example", setupCode: "invented", webOrigin: nil) == .claim(.pending))
    #expect(try await session.recoverClaim() == .claim(.claimed))
}

@Test func phoneActionShapeChecksRefuseUnexpectedFieldsAndTypesBeforeSetupOrClaimWork() async throws {
    let f = PhoneSetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { _ in
        Issue.record("Malformed action reached claim"); return .claimed
    }, prepare: { _, _, _ in Issue.record("Malformed action reached setup"); return try f.profile() })
    let actions = CompanionPhoneActions.handlers(session: session)
    let configure = try #require(actions["companion_configure"])
    let claim = try #require(actions["companion_claim"])
    var extra = f.request; extra.set("binder", .str("/invented/binder"))
    var wrongType = f.request; wrongType.set("web_origin", .bool(true))
    for request in [extra, wrongType, JSONObject([("command", .str("companion_configure"))])] {
        await #expect(throws: CompanionPhoneActionError.invalidSetup) { try await configure(request) }
    }
    await #expect(throws: CompanionPhoneActionError.invalidSetup) {
        try await claim(JSONObject([("command", .str("companion_claim")), ("setup_code", .str("invented"))]))
    }
}

@Test func setupFailuresBecomeFixedPhoneErrorsAndClaimBeforeConfigurationDoesNoRecoveryWork() async throws {
    let f = PhoneSetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    for (failure, expected) in [(CompanionOwnerSetupError.invalid, CompanionPhoneActionError.invalidSetup),
                                (.alreadyClaimed, .alreadyClaimed), (.reconfigurationRequired, .resetRequired),
                                (.relayUnavailable, .unavailable)] {
        let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { _ in
            Issue.record("Unconfigured action attempted recovery"); return .claimed
        }, prepare: { _, _, _ in throw failure })
        let actions = CompanionPhoneActions.handlers(session: session)
        let configure = try #require(actions["companion_configure"])
        let claim = try #require(actions["companion_claim"])
        await #expect(throws: expected) { try await configure(f.request) }
        #expect(try await claim(JSONObject([("command", .str("companion_claim"))])) == JSONObject([("state", .str("not-configured"))]))
    }
    let session = CompanionOwnerSession(database: f.database, secrets: f.secrets, recover: { _ in .claimed },
        prepare: { _, _, _ in throw PhoneActionTransportError() })
    let configure = try #require(CompanionPhoneActions.handlers(session: session)["companion_configure"])
    await #expect(throws: CompanionPhoneActionError.unavailable) { try await configure(f.request) }
    #expect(!CompanionPhoneActionError.unavailable.message.contains(PhoneActionTransportError().description))
}

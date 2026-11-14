import Foundation
import SpravaKit
import Testing
@testable import Companion
@testable import Services

private final class PairingActionSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard entries[account] == nil else { return false }; entries[account] = bytes; return true
    }
}
private let phoneID = Data(repeating: 7, count: 16).base64URL, pairingID = Data(repeating: 8, count: 16).base64URL
private let pairingSecret = Data(repeating: 9, count: 16).base64URL
private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Records which steps ran; each step's answer is set per test. Invented values only.
private final class FakePairing: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    var pollAnswer: CompanionPairingPoll = .waiting(retryAt: "2026-11-13T10:00:02Z")
    var recorded: CompanionPairingApproval?
    var delivery: CompanionPairingDeliveryProgress = .waiting(retryAt: "2026-11-13T10:00:04Z")
    var failure: (any Error)?
    func note(_ step: String) throws {
        lock.lock(); log.append(step); lock.unlock()
        if let failure { throw failure }
    }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return log }
    var steps: CompanionPairingSteps {
        CompanionPairingSteps(start: {
            try self.note("start")
            return CompanionPairingStart(deviceID: phoneID, ownerPublicKey: Data(repeating: 3, count: 32),
                created: CompanionCreatedPairing(id: pairingID, secret: pairingSecret, expiresAt: "2026-11-13T10:10:00Z"),
                deadline: "2026-11-13T10:10:00Z")
        }, poll: { try self.note("poll " + $0); return self.pollAnswer },
        approval: { try self.note("approval " + $0); return self.recorded },
        confirm: { try self.note("confirm " + $0.deviceID) },
        deliver: { try self.note("deliver " + $0); return self.delivery })
    }
}
private func approval(code: String = "123456") -> CompanionPairingApproval {
    CompanionPairingApproval(deviceID: phoneID, pairingID: pairingID, label: "Invented phone", confirmation: code, digest: "unused")
}
private struct PairingFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-pairing-actions-" + UUID().uuidString)
    let secrets = PairingActionSecrets()
    let fake = FakePairing()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    @discardableResult
    func profile(web: String? = "https://phone.example", claim: CompanionOwnerClaimState = .claimed) throws -> CompanionProfile {
        let profile = try CompanionProfile(database: database,
            relay: CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef"),
            secrets: secrets)
        _ = try profile.prepareAccount(beforeCommit: {}, webOrigin: web)
        try profile.recordClaimState(claim)
        return profile
    }
    func actions() -> [String: CompanionPhoneActions.Handler] {
        let fake = self.fake
        let session = CompanionOwnerSession(database: database, secrets: secrets, recover: { _ in .claimed },
                                            pairing: { _ in fake.steps })
        return CompanionPhoneActions.handlers(session: session)
    }
    func run(_ command: String, _ fields: [(String, JSONValue)] = []) async throws -> JSONObject {
        let handler = try #require(actions()[command])
        return try await handler(JSONObject([("command", .str(command))] + fields))
    }
}

@Test func phoneActionsRegisterPairingAndDevicesButNotRemovalOrReset() throws {
    let f = PairingFixture()
    #expect(Set(f.actions().keys) == ["companion_configure", "companion_claim", "companion_pairing_start",
                                      "companion_pairing_poll", "companion_pairing_confirm", "companion_devices"])
    #expect(CompanionRequestQueue.actionNames.isSuperset(of: f.actions().keys))
}

@Test func startingAPairingReturnsTheQRLinkForTheConfiguredWebApp() async throws {
    let f = PairingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    try f.profile()
    let reply = try await f.run("companion_pairing_start")
    #expect(reply["state"] == .str("waiting"))
    #expect(reply["device_id"] == .string(phoneID))
    #expect(reply["expires_at"] == .str("2026-11-13T10:10:00Z"))
    let link = try #require(reply["link"]?.stringValue)
    #expect(link.hasPrefix("https://phone.example/#pair=v0."))
    #expect(link.hasSuffix("." + phoneID) && link.contains(pairingSecret))
}

@Test func pairingRefusesBeforeAnyRelayWorkWithoutAWebAddressOrAClaim() async throws {
    let unconfigured = PairingFixture(); defer { try? FileManager.default.removeItem(at: unconfigured.folder) }
    await #expect(throws: CompanionPhoneActionError.notClaimed) { try await unconfigured.run("companion_pairing_start") }
    let noWeb = PairingFixture(); defer { try? FileManager.default.removeItem(at: noWeb.folder) }
    try noWeb.profile(web: nil)
    await #expect(throws: CompanionPhoneActionError.webOriginMissing) { try await noWeb.run("companion_pairing_start") }
    #expect(unconfigured.fake.calls.isEmpty && noWeb.fake.calls.isEmpty)
    let pending = PairingFixture(); defer { try? FileManager.default.removeItem(at: pending.folder) }
    try pending.profile(claim: .pending)
    pending.fake.failure = CompanionPairingFlowError.ownerUnavailable(.pending)
    await #expect(throws: CompanionPhoneActionError.notClaimed) { try await pending.run("companion_pairing_start") }
}

@Test func pollingWaitsThenShowsTheCodeAndARecordedCodeIsRestoredWithoutAnotherRelayCall() async throws {
    let f = PairingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    try f.profile()
    let device: [(String, JSONValue)] = [("device_id", .string(phoneID))]
    #expect(try await f.run("companion_pairing_poll", device) ==
            JSONObject([("state", .str("waiting")), ("retry_at", .str("2026-11-13T10:00:02Z"))]))
    f.fake.pollAnswer = .confirmation(approval())
    let shown = JSONObject([("state", .str("confirm")), ("label", .str("Invented phone")), ("confirmation", .str("123456"))])
    #expect(try await f.run("companion_pairing_poll", device) == shown)
    f.fake.recorded = approval()
    #expect(try await f.run("companion_pairing_poll", device) == shown)
    #expect(f.fake.calls == ["approval \(phoneID)", "poll \(phoneID)", "approval \(phoneID)", "poll \(phoneID)", "approval \(phoneID)"])
}

@Test func confirmingNeedsTheCodeThePersonSawAndThenDeliveryIsPolled() async throws {
    let f = PairingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try f.profile()
    f.fake.recorded = approval()
    await #expect(throws: CompanionPhoneActionError.pairingInvalid) {
        try await f.run("companion_pairing_confirm", [("device_id", .string(phoneID)), ("confirmation", .str("654321"))])
    }
    #expect(!f.fake.calls.contains { $0.hasPrefix("confirm") })
    #expect(try await f.run("companion_pairing_confirm", [("device_id", .string(phoneID)), ("confirmation", .str("123456"))]) ==
            JSONObject([("state", .str("delivering"))]))
    #expect(f.fake.calls.last == "confirm \(phoneID)")
    // Once the device is active locally, polling steps the key delivery instead of the pairing.
    try activate(profile, acknowledged: false)
    let device: [(String, JSONValue)] = [("device_id", .string(phoneID))]
    #expect(try await f.run("companion_pairing_poll", device) ==
            JSONObject([("state", .str("delivering")), ("retry_at", .str("2026-11-13T10:00:04Z"))]))
    f.fake.delivery = .acknowledged
    #expect(try await f.run("companion_pairing_poll", device) == JSONObject([("state", .str("paired"))]))
    f.fake.delivery = .notConfirmed
    #expect(try await f.run("companion_pairing_poll", device) == JSONObject([("state", .str("not-confirmed"))]))
}

@Test func pairingFailuresBecomeFixedSentencesWithoutRelayDetail() async throws {
    let f = PairingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    try f.profile()
    let device: [(String, JSONValue)] = [("device_id", .string(phoneID))]
    for (failure, expected) in [(CompanionPairingFlowError.relayRejected(401) as any Error, CompanionPhoneActionError.ownerRefused),
                                (CompanionPairingFlowError.relayRejected(503), .unavailable),
                                (CompanionPairingFlowError.busy, .busy),
                                (CompanionOwnerPairingError.expired, .pairingExpired),
                                (CompanionOwnerPairingError.invalid, .pairingInvalid),
                                (CompanionPairingDeliveryError.conflict(409), .pairingInvalid),
                                (CompanionRelayError.invalid, .unavailable)] {
        f.fake.failure = failure
        await #expect(throws: expected) { try await f.run("companion_pairing_poll", device) }
    }
}

@Test func pairingRequestShapesAreExact() async throws {
    let f = PairingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    try f.profile()
    let bad: [(String, [(String, JSONValue)])] = [
        ("companion_pairing_start", [("device_id", .string(phoneID))]),
        ("companion_pairing_poll", []),
        ("companion_pairing_poll", [("device_id", .bool(true))]),
        ("companion_pairing_poll", [("device_id", .string(phoneID)), ("binder", .str("/invented/binder"))]),
        ("companion_pairing_confirm", [("device_id", .string(phoneID))]),
        ("companion_devices", [("after", .number(JSONNumber(text: "1")))]),
    ]
    for (command, fields) in bad {
        await #expect(throws: CompanionPhoneActionError.invalidRequest) { try await f.run(command, fields) }
    }
    #expect(f.fake.calls.isEmpty)
}

@Test func theDeviceListIsLocalAndShowsLabelsAndConfirmationStates() async throws {
    let f = PairingFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    #expect(try await f.run("companion_devices") == JSONObject([("devices", .array([]))]))
    let profile = try f.profile(claim: .checkingRefusal)
    try activate(profile, acknowledged: true)
    let reply = try await f.run("companion_devices")
    #expect(reply == JSONObject([("devices", .array([.obj([("device_id", .string(phoneID)), ("label", .str("Invented phone")),
        ("paired_at", .str("2026-11-13T10:00:00Z")), ("confirmation", .str("acknowledged"))])]))]))
    #expect(f.fake.calls.isEmpty)
}

/// Stands in for a confirmed pairing; the domain tests cover how a real one gets here.
private func activate(_ profile: CompanionProfile, acknowledged: Bool) throws {
    try profile.store.write { t in
        try t.execute("INSERT OR IGNORE INTO devices (device, state, key_ready, creation_attempted, cleanup_pending, local_deadline) " +
                      "VALUES (?, 'active', 0, 1, 0, '2099-01-01T00:00:00Z')", .text(phoneID))
        try t.execute("INSERT OR REPLACE INTO pairings (device, pairing, expires, label, paired_at, acknowledged, key_epoch, " +
                      "wrapped_key, device_keys) VALUES (?, ?, '2099-01-01T00:00:00Z', 'Invented phone', '2026-11-13T10:00:00Z', ?, 1, ?, ?)",
                      .text(phoneID), .text(pairingID), .integer(acknowledged ? 1 : 0), .blob(Data([1])), .blob(Data([2])))
    }
}

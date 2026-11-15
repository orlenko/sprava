import Foundation
import Testing
@testable import Companion
import SpravaKit

private func resetID(_ byte: UInt8) -> String { CompanionWire.base64(Data(repeating: byte, count: 16)) }
private final class ResetSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private(set) var removed: [String] = []
    /// Removals that succeed before every further one fails, as a Keychain that locks partway.
    var removalsBeforeFailure: Int?
    var accounts: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(entries.keys) }
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }; if entries[account] != nil { return false }; entries[account] = bytes; return true
    }
    func remove(account: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let n = removalsBeforeFailure { guard n > 0 else { throw CompanionCredentialError.unavailable }; removalsBeforeFailure = n - 1 }
        removed.append(account); entries.removeValue(forKey: account)
    }
}
private actor ResetTransport: OwnerResetTransport {
    private(set) var deleted: [String] = []
    let status: Int, fails: Bool
    init(status: Int = 204, fails: Bool = false) { self.status = status; self.fails = fails }
    func deleteDevice(deviceID: String, downloadLimit: Int) async throws -> CompanionRelayReply<Data> {
        deleted.append(deviceID)
        if fails { throw URLError(.cannotConnectToHost) }
        return CompanionRelayReply(status: status, value: nil, receivedBytes: 0)
    }
}
private struct ResetFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-owner-reset-" + UUID().uuidString)
    let secrets = ResetSecrets()
    let relay = try! CompanionRelayIdentity(origin: "https://relay.example", instance: "0123456789abcdef0123456789abcdef")
    var database: URL { root.appendingPathComponent("companion/state.sqlite") }
    /// A claimed profile at epoch 2 (epoch 1 awaiting discard), one shown and one hidden binder, an active, a pairing
    /// and a removed phone the relay confirmed deleting.
    func prepare() throws -> CompanionProfile {
        let p = try CompanionProfile(database: database, relay: relay, secrets: secrets)
        _ = try CompanionOwnerVault(backend: secrets).prepare(relay, setupCode: Data(repeating: 23, count: 32).base64EncodedString())
        _ = try p.prepareAccount(); try p.recordClaimState(.claimed)
        _ = try secrets.insert(account: p.keyAccount(2), bytes: Data(repeating: 1, count: 32))
        try p.store.write { t in
            try t.execute("UPDATE profile SET epoch = 2 WHERE slot = 1")
            try t.execute("INSERT INTO discard_epochs VALUES (1)")
            for (byte, state) in [(70, "active"), (71, "pairing"), (72, "revoked")] {
                try t.execute("INSERT INTO devices (device,state,key_ready,creation_attempted,cleanup_pending) VALUES (?, ?, 1, 1, 0)",
                              .text(resetID(UInt8(byte))), .text(state))
            }
            try t.execute("INSERT INTO device_removals VALUES (?, 0, 0)", .text(resetID(72)))
            try t.execute("INSERT INTO phone_binders (binder, state, local_identity, key_epoch) VALUES (?, 'shown', ?, 2)",
                          .text(resetID(80)), .blob(Data(repeating: 80, count: 16)))
            try t.execute("INSERT INTO phone_binders (binder, state, local_identity, key_epoch) VALUES (?, 'removed', ?, 1)",
                          .text(resetID(81)), .blob(Data(repeating: 81, count: 16)))
        }
        for e: Int64 in [1, 2] { _ = try secrets.insert(account: p.binderKeyAccount(resetID(80), epoch: e), bytes: Data(repeating: 2, count: 32)) }
        _ = try secrets.insert(account: p.binderKeyAccount(resetID(81), epoch: 1), bytes: Data(repeating: 3, count: 32))
        // A key staged for epoch 3 by a rotation whose commit failed.
        _ = try secrets.insert(account: p.keyAccount(3), bytes: Data(repeating: 4, count: 32))
        _ = try secrets.insert(account: p.deviceAccount(resetID(70)), bytes: Data(repeating: 5, count: 32))
        _ = try secrets.insert(account: p.pairingAccount(resetID(71)), bytes: Data(repeating: 6, count: 32))
        _ = try secrets.insert(account: p.createdAccount(resetID(71)), bytes: Data(repeating: 7, count: 32))
        return p
    }
    func setAside() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("companion-reset-") }.sorted()
    }
}

@Test func resetForgetsEveryCredentialOwnerFirstAndSetsTheStateAside() throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try f.prepare()
    #expect(f.secrets.accounts.count == 10)
    let at = try Date("2026-11-15T10:15:30Z", strategy: .iso8601)
    #expect(try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets, now: at) == 1)
    #expect(f.secrets.accounts.isEmpty)
    #expect(f.secrets.removed.first == f.relay.account)
    #expect(try f.setAside() == ["companion-reset-2026-11-15T101530Z"])
    // The state set aside is whole: its WAL moved with it.
    let aside = try CompanionProfile(database: f.root.appendingPathComponent("companion-reset-2026-11-15T101530Z/state.sqlite"),
                                     relay: f.relay, secrets: f.secrets)
    #expect(try aside.ownerClaimState() == .claimed)
    #expect(!FileManager.default.fileExists(atPath: f.database.path))
    #expect(try CompanionProfile.openConfigured(database: f.database, secrets: f.secrets) == nil)
    // Nothing left to reset; a second reset at the same second never replaces what was set aside.
    #expect(try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets, now: at) == nil)
    _ = try f.prepare()
    #expect(try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets, now: at) == 1)
    #expect(try f.setAside() == ["companion-reset-2026-11-15T101530Z", "companion-reset-2026-11-15T101530Z-2"])
}

@Test func anInterruptedResetLeavesTheStateForASecondResetToFinish() throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    _ = try f.prepare()
    f.secrets.removalsBeforeFailure = 3
    #expect(throws: CompanionCredentialError.unavailable) { try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets) }
    // The owner token and signing key went first: the old setup can make no further relay call.
    #expect(try CompanionOwnerVault(backend: f.secrets).load(f.relay) == nil)
    #expect(try f.setAside().isEmpty)
    let left = try #require(try CompanionProfile.openConfigured(database: f.database, secrets: f.secrets))
    #expect(try left.ownerClaimState() == .claimed)
    f.secrets.removalsBeforeFailure = nil
    #expect(try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets) == 1)
    #expect(f.secrets.accounts.isEmpty)
    #expect(try f.setAside().count == 1)
}

@Test func resetAsksAClaimedRelayToRefuseEachPhoneItMayKnow() async throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let p = try f.prepare(), relay = ResetTransport()
    let report = await CompanionOwnerReset.refusePhones(p, transport: relay, admit: { true })
    // The removed phone the relay confirmed deleting is not asked about again.
    #expect(await relay.deleted == [resetID(70), resetID(71)].sorted())
    #expect(report.phonesRefused == 2 && report.phonesNotReached == 0)
}

@Test func aRelayThatIsDownOrRefusesStopsTheBestEffortStepWithoutBlockingIt() async throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let p = try f.prepare()
    for relay in [ResetTransport(fails: true), ResetTransport(status: 401)] {
        let report = await CompanionOwnerReset.refusePhones(p, transport: relay, admit: { true })
        #expect(await relay.deleted.count == 1)
        #expect(report.phonesRefused == 0 && report.phonesNotReached == 2)
    }
    let late = ResetTransport()
    #expect(await CompanionOwnerReset.refusePhones(p, transport: late, admit: { false }).phonesNotReached == 2)
    #expect(await late.deleted.isEmpty)
    #expect(await CompanionOwnerReset.refusePhones(p, transport: nil, admit: { true }).phonesNotReached == 2)
    // A relay that needs a reset is never called.
    try p.recordClaimState(.needsReset)
    let retired = ResetTransport()
    #expect(await CompanionOwnerReset.refusePhones(p, transport: retired, admit: { true }).phonesNotReached == 2)
    #expect(await retired.deleted.isEmpty)
}

@Test func aRelayStartedOverHasNoPhoneLeftToRefuse() async throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let p = try f.prepare(), relay = ResetTransport()
    try p.store.write { try $0.execute("UPDATE profile SET claim_state = 'instance-changed'") }
    #expect(await CompanionOwnerReset.refusePhones(p, transport: relay, admit: { true }) == CompanionOwnerResetReport())
    #expect(await relay.deleted.isEmpty)
}

@Test func afterAResetSetupTakesAnotherRelayAndTheSameRelayStartedOver() async throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let code = Data(repeating: 31, count: 32).base64EncodedString(), other = "http://localhost:8788"
    _ = try f.prepare()
    await #expect(throws: CompanionOwnerSetupError.reconfigurationRequired) {
        _ = try await CompanionOwnerSetup.prepare(database: f.database, origin: other, setupCode: code, secrets: f.secrets,
                                                  discover: { _ in CompanionRelayHealth(instance: String(repeating: "b", count: 32), claimed: false) })
    }
    _ = try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets)
    let next = try await CompanionOwnerSetup.prepare(database: f.database, origin: other, setupCode: code, secrets: f.secrets,
                                                     discover: { _ in CompanionRelayHealth(instance: String(repeating: "b", count: 32), claimed: false) })
    #expect(next.relayIdentity.origin == other)
    #expect(try next.ownerClaimState() == .pending)
    #expect(try next.binderSharing(CompanionLocalBinderIdentity(bytes: Data(repeating: 80, count: 16))) == nil)
    // The first relay claimed by this Mac before the reset: its credentials are gone, so it cannot be taken back.
    _ = try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets)
    await #expect(throws: CompanionOwnerSetupError.alreadyClaimed) {
        _ = try await CompanionOwnerSetup.prepare(database: f.database, origin: f.relay.origin, setupCode: code, secrets: f.secrets,
                                                  discover: { _ in CompanionRelayHealth(instance: f.relay.instance, claimed: true) })
    }
}

@Test func aPhoneDecisionNotFinishedRefusesTheLocalResetBeforeAnythingChanges() throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let p = try f.prepare()
    try p.store.write { try $0.execute("INSERT INTO request_decisions VALUES (?, 'r', x'00')", .text(resetID(70))) }
    #expect(try p.devicesWithPendingDecisions() == [resetID(70)])
    #expect(throws: CompanionOwnerResetError.decisionPending) { try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets) }
    #expect(f.secrets.accounts.count == 10 && f.secrets.removed.isEmpty)
    #expect(try f.setAside().isEmpty)
}

@Test func aBinderSwitchedOffKeepsItsOwnEpochsKeyUntilTheResetForgetsIt() throws {
    let f = ResetFixture(); defer { try? FileManager.default.removeItem(at: f.root) }
    let p = try f.prepare()
    // Epoch 1 was discarded behind a published index; the binder switched off at epoch 1 still awaits its cleanup.
    try p.store.write { try $0.execute("DELETE FROM discard_epochs") }
    try f.secrets.remove(account: p.keyAccount(1)); try f.secrets.remove(account: p.binderKeyAccount(resetID(80), epoch: 1))
    #expect(try CompanionOwnerReset.forget(database: f.database, secrets: f.secrets) == 1)
    #expect(f.secrets.accounts.isEmpty)
}

import Foundation
import SpravaKit
import Testing
@testable import Companion

private final class SetupFixtureSecrets: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]
    private var nextInsert: (@Sendable () throws -> Void)?
    func beforeNextInsert(_ action: @escaping @Sendable () throws -> Void) {
        lock.lock(); defer { lock.unlock() }; nextInsert = action
    }
    func read(account: String) throws -> Data? { lock.lock(); defer { lock.unlock() }; return entries[account] }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); let action = nextInsert; nextInsert = nil; lock.unlock()
        try action?()
        lock.lock(); defer { lock.unlock() }
        guard entries[account] == nil else { return false }; entries[account] = bytes; return true
    }
    func remove(account: String) throws { lock.lock(); entries[account] = nil; lock.unlock() }
    func snapshot() -> [String: Data] { lock.lock(); defer { lock.unlock() }; return entries }
}
private struct SetupFixture {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-owner-setup-" + UUID().uuidString)
    let secrets = SetupFixtureSecrets()
    let origin = "https://relay.example"
    let instance = "0123456789abcdef0123456789abcdef"
    let code = Data(repeating: 11, count: 32).base64EncodedString()
    var database: URL { folder.appendingPathComponent("state.sqlite") }
    var identity: CompanionRelayIdentity { get throws { try CompanionRelayIdentity(origin: origin, instance: instance) } }
    func prepare(claimed: Bool = false, webOrigin: String? = nil) async throws -> CompanionProfile {
        try await CompanionOwnerSetup.prepare(database: database, origin: origin, setupCode: code,
                                              webOrigin: webOrigin, secrets: secrets, discover: { _ in
            CompanionRelayHealth(instance: instance, claimed: claimed)
        })
    }
}
private actor SetupDiscoveryPause {
    private var entered = false
    private var observer: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { release = $0; entered = true; observer?.resume(); observer = nil }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { observer = $0 } } }
    func open() { release?.resume(); release = nil }
}

@Test func initialSetupPersistsTheClaimAndAccountIdentitiesAndRetriesKeepTheirExactBytes() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let first = try await f.prepare()
    #expect(try first.ownerClaimState() == .pending)
    #expect(try first.webOrigin() == nil)
    let saved = f.secrets.snapshot()
    #expect(saved.count == 2)
    let selected = try await f.prepare(webOrigin: "https://phone.example")
    #expect(try selected.webOrigin() == "https://phone.example")
    #expect(f.secrets.snapshot() == saved)
    let retry = try await f.prepare(claimed: true)
    #expect(f.secrets.snapshot() == saved)
    #expect(try retry.webOrigin() == "https://phone.example")
    #expect(try retry.ownerClaimState() == .pending) // public health does not prove owner admission
    let rows = try retry.store.read { try $0.rows("SELECT origin, instance, epoch, web_origin FROM profile") }
    #expect(rows == [[.text(f.origin), .text(f.instance), .integer(1), .text("https://phone.example")]])
    let raw = try Data(contentsOf: f.database)
    #expect(raw.range(of: Data(f.code.utf8)) == nil)
    for bytes in saved.values { #expect(raw.range(of: bytes) == nil) }
}

@Test func anAlreadyClaimedRelayWithoutOurStoredIdentityCannotCreateAnAccount() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    await #expect(throws: CompanionOwnerSetupError.alreadyClaimed) { try await f.prepare(claimed: true) }
    #expect(f.secrets.snapshot().isEmpty)
    #expect(try CompanionProfile.openConfigured(database: f.database, secrets: f.secrets) == nil)
}

@Test func setupReusesAnInterruptedPreparedClaimButNeverReplacesMissingEstablishedCredentials() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let owner = try CompanionOwnerVault(backend: f.secrets).prepare(f.identity, setupCode: f.code)
    let profile = try await f.prepare(claimed: true)
    #expect(try CompanionOwnerVault(backend: f.secrets).load(f.identity)?.claimBody == owner.claimBody)
    #expect(try profile.currentAccount()?.number == 1)
    try f.secrets.remove(account: f.identity.account)
    let afterLoss = f.secrets.snapshot()
    await #expect(throws: CompanionCredentialError.unavailable) { try await f.prepare() }
    #expect(f.secrets.snapshot() == afterLoss)
}

@Test func setupValidatesAllInputBeforeDiscoveryOrCreatingState() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    for (origin, code, web) in [("https://relay.example/path", f.code, nil),
                                 (f.origin, "invalid", nil),
                                 (f.origin, f.code, "https://phone.example/#fragment")] {
        await #expect(throws: CompanionOwnerSetupError.invalid) {
            try await CompanionOwnerSetup.prepare(database: f.database, origin: origin, setupCode: code,
                                                  webOrigin: web, secrets: f.secrets, discover: { _ in
                Issue.record("Invalid setup performed discovery")
                return CompanionRelayHealth(instance: f.instance, claimed: false)
            })
        }
    }
    #expect(!FileManager.default.fileExists(atPath: f.database.path))
    #expect(f.secrets.snapshot().isEmpty)
}

@Test func setupDoesNotRebindARelayOrWebOriginAndRecordsAnInstanceChangeWithoutNewKeys() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let profile = try await f.prepare(webOrigin: "https://phone.example")
    let saved = f.secrets.snapshot()
    for (origin, web) in [("https://different.example", "https://phone.example"),
                         (f.origin, "https://different.example")] {
        await #expect(throws: CompanionOwnerSetupError.reconfigurationRequired) {
            try await CompanionOwnerSetup.prepare(database: f.database, origin: origin, setupCode: f.code,
                                                  webOrigin: web, secrets: f.secrets, discover: { _ in
                Issue.record("A requested rebind performed discovery")
                return CompanionRelayHealth(instance: f.instance, claimed: false)
            })
        }
    }
    await #expect(throws: CompanionOwnerSetupError.reconfigurationRequired) {
        try await CompanionOwnerSetup.prepare(database: f.database, origin: f.origin, setupCode: f.code,
                                              secrets: f.secrets, discover: { _ in
            CompanionRelayHealth(instance: "fedcba9876543210fedcba9876543210", claimed: false)
        })
    }
    #expect(f.secrets.snapshot() == saved)
    #expect(try profile.ownerClaimState() == .instanceChanged)
    #expect(try profile.webOrigin() == "https://phone.example")
}

@Test func cancellationDuringDiscoveryDoesNotPrepareCredentialsOrCommitAnAccount() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let pause = SetupDiscoveryPause()
    let pending = Task {
        try await CompanionOwnerSetup.prepare(database: f.database, origin: f.origin, setupCode: f.code,
                                              secrets: f.secrets, discover: { _ in
            await pause.wait(); return CompanionRelayHealth(instance: f.instance, claimed: false)
        })
    }
    await pause.waitForEntry(); pending.cancel(); await pause.open()
    await #expect(throws: CancellationError.self) { try await pending.value }
    #expect(f.secrets.snapshot().isEmpty)
    #expect(try CompanionProfile.openConfigured(database: f.database, secrets: f.secrets) == nil)
}

@Test func editingTheSetupCodeCannotSilentlyReuseTheOldClaimAndReportSuccess() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    _ = try await f.prepare()
    let saved = f.secrets.snapshot()
    await #expect(throws: CompanionOwnerSetupError.reconfigurationRequired) {
        try await CompanionOwnerSetup.prepare(database: f.database, origin: f.origin,
            setupCode: Data(repeating: 13, count: 32).base64EncodedString(), secrets: f.secrets, discover: { _ in
                CompanionRelayHealth(instance: f.instance, claimed: false)
            })
    }
    #expect(f.secrets.snapshot() == saved)
}

@Test func setupChecksTheWinningImmutableClaimBeforePreparingTheAccount() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    // Install the other caller's claim after both initial reads saw no credential, before this insertion.
    f.secrets.beforeNextInsert {
        _ = try CompanionOwnerVault(backend: f.secrets).prepare(f.identity, setupCode: f.code)
    }
    await #expect(throws: CompanionOwnerSetupError.reconfigurationRequired) {
        try await CompanionOwnerSetup.prepare(database: f.database, origin: f.origin,
            setupCode: Data(repeating: 13, count: 32).base64EncodedString(), secrets: f.secrets, discover: { _ in
                CompanionRelayHealth(instance: f.instance, claimed: false)
            })
    }
    let stored = try #require(try CompanionOwnerVault(backend: f.secrets).load(f.identity))
    #expect(try CompanionWire.parse(stored.claimBody, limit: 4096)["setup_code"]?.stringValue == f.code)
    #expect(try CompanionProfile.openConfigured(database: f.database, secrets: f.secrets) == nil)
    #expect(f.secrets.snapshot().count == 1)
}

@Test func setupRejectsAWebOriginCommittedWhileDiscoveryWasInFlight() async throws {
    let f = SetupFixture(); defer { try? FileManager.default.removeItem(at: f.folder) }
    let pause = SetupDiscoveryPause()
    let pending = Task {
        try await CompanionOwnerSetup.prepare(database: f.database, origin: f.origin, setupCode: f.code,
            webOrigin: "https://different.example", secrets: f.secrets, discover: { _ in
                await pause.wait(); return CompanionRelayHealth(instance: f.instance, claimed: false)
            })
    }
    await pause.waitForEntry()
    let first = try await f.prepare(webOrigin: "https://phone.example")
    let saved = f.secrets.snapshot()
    await pause.open()
    await #expect(throws: CompanionOwnerSetupError.reconfigurationRequired) { try await pending.value }
    #expect(try first.webOrigin() == "https://phone.example")
    #expect(f.secrets.snapshot() == saved)
}

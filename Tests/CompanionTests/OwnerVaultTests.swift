import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing
@testable import Companion
import SpravaKit

private final class MemoryCredentials: CompanionCredentialStorage, @unchecked Sendable {
    private let lock = NSLock()
    var entries: [String: Data] = [:]
    var failRead = false
    var failWrite = false
    func read(account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        if failRead { throw CompanionCredentialError.unavailable }
        return entries[account]
    }
    func insert(account: String, bytes: Data) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        if failWrite { throw CompanionCredentialError.unavailable }
        if entries[account] != nil { return false }
        entries[account] = bytes; return true
    }
}
private let inventedInstance = "0123456789abcdef0123456789abcdef"
private let inventedSetup = Data(repeating: 17, count: 32).base64EncodedString()
private func relay(_ origin: String = "https://relay.example") throws -> CompanionRelayIdentity {
    try CompanionRelayIdentity(origin: origin, instance: inventedInstance)
}

@Test func claimCredentialsSurviveRestartAndEveryRetryUsesTheSameIdentity() throws {
    let backend = MemoryCredentials(), identity = try relay()
    let first = try CompanionOwnerVault(backend: backend).prepare(identity, setupCode: inventedSetup)
    let second = try #require(try CompanionOwnerVault(backend: backend).load(identity))
    let retry = try CompanionOwnerVault(backend: backend).prepare(identity, setupCode: Data(repeating: 19, count: 32).base64EncodedString())
    #expect(first.ownerToken == second.ownerToken && second.ownerToken == retry.ownerToken)
    #expect(first.signingKey.rawRepresentation == second.signingKey.rawRepresentation)
    #expect(first.claimBody == second.claimBody && second.claimBody == retry.claimBody)
    let body = try CompanionWire.parse(first.claimBody, limit: 1024)
    let hash = SHA256.hash(data: Data(first.ownerToken.utf8)).map { String(format: "%02x", $0) }.joined()
    #expect(body["setup_code"]?.stringValue == inventedSetup)
    #expect(body["owner_token_sha256"]?.stringValue == hash)
    #expect(first.claimBody == Data("{\"setup_code\":\"\(inventedSetup)\",\"owner_token_sha256\":\"\(hash)\"}".utf8))
    #expect(try CompanionWire.decode(first.ownerToken).count == 32)
    #expect(backend.entries.count == 1)
}

@Test func competingCreatorsCannotReplaceAnInstalledClaim() async throws {
    let backend = MemoryCredentials(), identity = try relay(), vault = CompanionOwnerVault(backend: backend)
    let tokens = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<20 { group.addTask { try vault.prepare(identity, setupCode: inventedSetup).ownerToken } }
        var values: [String] = []
        for try await value in group { values.append(value) }
        return values
    }
    #expect(Set(tokens).count == 1)
    #expect(backend.entries.count == 1)
}

@Test func credentialFailuresNeverReturnNewCredentialsOrOverwriteOldBytes() throws {
    let backend = MemoryCredentials(), vault = CompanionOwnerVault(backend: backend), identity = try relay()
    backend.failWrite = true
    #expect(throws: CompanionCredentialError.unavailable) { try vault.prepare(identity, setupCode: inventedSetup) }
    #expect(backend.entries.isEmpty)
    backend.failWrite = false
    _ = try vault.prepare(identity, setupCode: inventedSetup)
    let saved = backend.entries
    backend.failRead = true
    #expect(throws: CompanionCredentialError.unavailable) { try vault.prepare(identity, setupCode: inventedSetup) }
    #expect(backend.entries == saved)
}

@Test func storedCredentialsAreBoundToTheOriginAndInstanceAndFailClosedIfMalformed() throws {
    let backend = MemoryCredentials(), vault = CompanionOwnerVault(backend: backend), identity = try relay()
    #expect(try vault.load(identity) == nil)
    _ = try vault.prepare(identity, setupCode: inventedSetup)
    let saved = try #require(backend.entries[identity.account])
    let other = try relay("https://other.example")
    #expect(other.account != identity.account)
    backend.entries[other.account] = saved
    #expect(throws: CompanionCredentialError.invalid) { try vault.load(other) }
    for bytes in [Data("{}".utf8), Data("{\"v\":0,\"v\":0}".utf8), Data(repeating: 32, count: 4097)] {
        backend.entries[identity.account] = bytes
        #expect(throws: CompanionCredentialError.invalid) { try vault.prepare(identity, setupCode: inventedSetup) }
        #expect(backend.entries[identity.account] == bytes)
    }
    #expect(!identity.account.contains(identity.origin))
    var object = try #require(try CompanionWire.parse(saved, limit: 4096).objectValue)
    object.entries = object.entries.filter { $0.key != "claim" }
    object.entries.append(("claim", .string(CompanionWire.base64(Data("{}".utf8)))))
    backend.entries[identity.account] = Data(JSONWriter.compact(.object(object)).utf8)
    #expect(throws: CompanionCredentialError.invalid) { try vault.load(identity) }
}

@Test func relayIdentityAndSetupCodeRefuseAmbiguousOrUnsafeInputs() throws {
    for origin in ["https://relay.example", "https://relay.example:8443", "http://localhost:5173"] {
        _ = try relay(origin)
    }
    for origin in ["http://relay.example", "http://127.0.0.1", "https://user@relay.example", "https://relay.example/",
                   "https://relay.example?x", "https://relay.example#x", "HTTPS://relay.example", "https://RELAY.example",
                   "https://relay.example:443", "http://localhost:80", "https://relay.example:08443",
                   "https://relay.example:65536", "https://relay%2eexample", "https://relay.example\\other", "\nhttps://relay.example",
                   "https://relay.example:" + String(repeating: "9", count: 50)] {
        #expect(throws: CompanionCredentialError.invalid) { try relay(origin) }
    }
    #expect(throws: CompanionCredentialError.invalid) { try CompanionRelayIdentity(origin: "https://relay.example", instance: "../x") }
    for setup in ["", inventedSetup.dropLast().description, inventedSetup + "\n", Data(repeating: 0, count: 31).base64EncodedString()] {
        #expect(!CompanionOwnerVault.validSetupCode(setup))
    }
}

@Test func keychainUsesLocalProtectedImmutableItemsAndDoesNotTreatReadFailureAsAbsence() throws {
    let keychain = CompanionKeychain(calls: .init(read: { query in
        let q = query as! [String: Any]
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect((q[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        return (errSecInteractionNotAllowed, nil)
    }, add: { query in
        let q = query as! [String: Any]
        #expect(q[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(q[kSecUseDataProtectionKeychain as String] as? Bool == true)
        #expect((q[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true)
        #expect(q[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        return errSecDuplicateItem
    }))
    #expect(throws: CompanionCredentialError.unavailable) { try keychain.read(account: "invented") }
    #expect(try keychain.insert(account: "invented", bytes: Data([1])) == false)
    let missing = CompanionKeychain(calls: .init(read: { _ in (errSecItemNotFound, nil) }, add: { _ in errSecNotAvailable }))
    #expect(try missing.read(account: "invented") == nil)
    #expect(throws: CompanionCredentialError.unavailable) { try missing.insert(account: "invented", bytes: Data([1])) }
    let wrong = CompanionKeychain(calls: .init(read: { _ in (errSecSuccess, nil) }, add: { _ in errSecSuccess }))
    #expect(throws: CompanionCredentialError.unavailable) { try wrong.read(account: "invented") }
}

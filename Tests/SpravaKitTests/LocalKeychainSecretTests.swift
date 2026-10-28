import Foundation
import LocalAuthentication
import Security
@testable import SpravaKit
import Testing

@Suite struct LocalKeychainSecretTests {
    final class Keychain: @unchecked Sendable {
        let lock = NSLock()
        var protectedStatus = errSecSuccess
        var legacyStatus = errSecSuccess
        var values: [String: Data] = [:]
        var calls: [(protected: Bool, interactive: Bool, account: String)] = []
        var duplicateOnAdd = false

        private func status(_ query: [String: Any]) -> OSStatus {
            let protected = query[kSecUseDataProtectionKeychain as String] as? Bool == true
            let account = query[kSecAttrAccount as String] as? String ?? ""
            calls.append((protected, (query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == false, account))
            #expect(query[kSecAttrService as String] as? String == "org.example.invented-credentials")
            #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(query[kSecAttrAccess as String] == nil)
            if !protected { #expect(query[kSecAttrAccessible as String] == nil) }
            return protected ? protectedStatus : legacyStatus
        }
        var operations: LocalKeychainSecret.Operations {
            .init(read: { query in
                self.lock.withLock {
                    let status = self.status(query)
                    guard status == errSecSuccess else { return (status, nil) }
                    #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
                    let key = query[kSecAttrAccount as String] as! String
                    return self.values[key].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
                }
            }, update: { query, changes in
                self.lock.withLock {
                    let status = self.status(query)
                    guard status == errSecSuccess else { return status }
                    let key = query[kSecAttrAccount as String] as! String
                    guard self.values[key] != nil else { return errSecItemNotFound }
                    self.values[key] = changes[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            }, add: { query in
                self.lock.withLock {
                    let status = self.status(query)
                    guard status == errSecSuccess else { return status }
                    let key = query[kSecAttrAccount as String] as! String
                    if self.duplicateOnAdd { self.values[key] = Data("other invented writer".utf8); return errSecDuplicateItem }
                    self.values[key] = query[kSecValueData as String] as? Data
                    return errSecSuccess
                }
            }, remove: { query in
                self.lock.withLock {
                    let status = self.status(query)
                    guard status == errSecSuccess else { return status }
                    let key = query[kSecAttrAccount as String] as! String
                    return self.values.removeValue(forKey: key) == nil ? errSecItemNotFound : errSecSuccess
                }
            })
        }
        func storage() -> LocalKeychainSecret {
            LocalKeychainSecret(service: "org.example.invented-credentials", label: "Invented credential", operations: operations)
        }
    }

    @Test func anAdHocAppKeepsItsCredentialThroughRestartWithoutAFileFallback() {
        let keychain = Keychain(); keychain.protectedStatus = errSecMissingEntitlement
        let original = Data("invented-token".utf8)
        #expect(keychain.storage().write(original, account: "account") == errSecSuccess)
        #expect(keychain.storage().read(account: "account").1 == original)
        #expect(keychain.storage().read(account: "another-account").0 == errSecItemNotFound)
        #expect(keychain.storage().write(nil, account: "account") == errSecSuccess)
        #expect(keychain.storage().read(account: "account").0 == errSecItemNotFound)
        #expect(keychain.calls.contains { !$0.protected })
        #expect(keychain.calls.allSatisfy { !$0.interactive })
    }

    @Test func aProvisionedAppStaysInTheDataProtectionKeychain() {
        let keychain = Keychain()
        #expect(keychain.storage().write(Data("invented-password".utf8), account: "account") == errSecSuccess)
        #expect(keychain.storage().read(account: "account").0 == errSecSuccess)
        #expect(keychain.storage().write(nil, account: "account") == errSecSuccess)
        #expect(keychain.calls.allSatisfy { $0.protected })
    }

    @Test(arguments: [errSecInteractionNotAllowed, errSecDecode, errSecAuthFailed])
    func aLockedOrDamagedKeychainNeverFallsBack(_ refusal: OSStatus) {
        let keychain = Keychain(); keychain.protectedStatus = refusal
        #expect(keychain.storage().read(account: "account").0 == refusal)
        #expect(keychain.storage().write(Data("invented".utf8), account: "account") == refusal)
        #expect(keychain.storage().write(nil, account: "account") == refusal)
        #expect(keychain.calls.allSatisfy { $0.protected })
        keychain.protectedStatus = errSecMissingEntitlement; keychain.legacyStatus = refusal
        #expect(keychain.storage().read(account: "account").0 == refusal)
        #expect(keychain.storage().write(Data("invented".utf8), account: "account") == refusal)
    }

    @Test func onlyAnExplicitSaveMayAskForAuthorization() {
        let keychain = Keychain(); keychain.protectedStatus = errSecMissingEntitlement
        #expect(keychain.storage().write(Data("invented".utf8), account: "account", allowInteraction: true) == errSecSuccess)
        #expect(keychain.calls.allSatisfy { $0.interactive })
        keychain.calls = []
        #expect(keychain.storage().read(account: "account").0 == errSecSuccess)
        #expect(keychain.storage().write(nil, account: "account") == errSecSuccess)
        #expect(keychain.calls.allSatisfy { !$0.interactive })
    }

    @Test func aConcurrentInsertStillStoresThePersonsChosenValue() {
        let keychain = Keychain(); keychain.duplicateOnAdd = true
        let chosen = Data("invented-chosen-password".utf8)
        #expect(keychain.storage().write(chosen, account: "account") == errSecSuccess)
        #expect(keychain.storage().read(account: "account").1 == chosen)
    }

    @Test func anEmptyAccountNeverBecomesAWildcard() {
        let keychain = Keychain()
        #expect(keychain.storage().read(account: "").0 == errSecParam)
        #expect(keychain.storage().write(nil, account: "") == errSecParam)
        #expect(keychain.calls.isEmpty)
    }
}

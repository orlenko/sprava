import Foundation
import LocalAuthentication
import Security

/// Explicit production backend; constructing it performs no Keychain access. companion-v0 §9.1.
public struct CompanionKeychain: CompanionCredentialStorage {
    struct Calls: Sendable {
        let read: @Sendable (CFDictionary) -> (OSStatus, Data?)
        let add: @Sendable (CFDictionary) -> OSStatus
        var remove: @Sendable (CFDictionary) -> OSStatus = { _ in errSecNotAvailable }
        static let system = Calls(read: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query, &result)
            return (status, result as? Data)
        }, add: { SecItemAdd($0, nil) }, remove: { SecItemDelete($0) })
    }
    private let calls: Calls
    public init() { calls = .system }
    init(calls: Calls) { self.calls = calls }

    static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.sprava.companion",
         kSecAttrAccount as String: account, kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    public func read(account: String) throws -> Data? {
        var q = Self.query(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        // A background task fails closed while locked, rather than hanging on a Keychain prompt.
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let (status, bytes) = calls.read(q as CFDictionary)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes, bytes.count <= 4096 else { throw CompanionCredentialError.unavailable }
        return bytes
    }
    public func insert(account: String, bytes: Data) throws -> Bool {
        guard bytes.count <= 4096 else { throw CompanionCredentialError.invalid }
        var q = Self.query(account)
        q[kSecValueData as String] = bytes
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrLabel as String] = "Sprava companion credentials"
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = calls.add(q as CFDictionary)
        if status == errSecDuplicateItem { return false }
        guard status == errSecSuccess else { throw CompanionCredentialError.unavailable }
        return true
    }
    public func remove(account: String) throws {
        var q = Self.query(account)
        let context = LAContext(); context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = calls.remove(q as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CompanionCredentialError.unavailable }
    }
}

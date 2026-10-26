import Foundation
import LocalAuthentication
import Security

/// IMAP account passwords: one item per account in the non-synchronized data-protection Keychain service
/// `org.sprava.imap` (integrations.md 2.1). An ad-hoc development runtime has no Keychain access group (Apple
/// TN3137); only that precise refusal keeps the password in this runtime's memory instead, so the binder asks for
/// it again after a restart. Never a file. Locked or damaged Keychains fail closed.
public final class IMAPPasswords: @unchecked Sendable {
    public enum Refused: Error { case unavailable }
    public struct Backend: Sendable {
        let load: @Sendable (String) -> (OSStatus, Data?)
        let save: @Sendable (String, Data?) -> OSStatus
        public init(load: @escaping @Sendable (String) -> (OSStatus, Data?), save: @escaping @Sendable (String, Data?) -> OSStatus) {
            self.load = load; self.save = save
        }
    }
    private let lock = NSLock()
    private let backend: Backend
    private var memory: [String: String] = [:]

    public init(backend: Backend = .keychain) { self.backend = backend }

    public func read(_ account: IMAPAccount) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let value = memory[account.key] { return value }
        let (status, data) = backend.load(account.key)
        if status == errSecItemNotFound || status == errSecMissingEntitlement { return nil }
        guard status == errSecSuccess, let data, data.count <= 1_024, let value = String(data: data, encoding: .utf8), !value.isEmpty else {
            throw Refused.unavailable
        }
        memory[account.key] = value
        return value
    }

    public func store(_ password: String, for account: IMAPAccount) throws {
        guard !password.isEmpty, password.utf8.count <= 1_024 else { throw Refused.unavailable }
        lock.lock(); defer { lock.unlock() }
        let status = backend.save(account.key, Data(password.utf8))
        guard status == errSecSuccess || status == errSecMissingEntitlement else { throw Refused.unavailable }
        memory[account.key] = password
    }

    public func remove(_ account: IMAPAccount) {
        lock.lock(); defer { lock.unlock() }
        memory[account.key] = nil
        _ = backend.save(account.key, nil)
    }
}

extension IMAPPasswords.Backend {
    public static let keychain = IMAPPasswords.Backend(load: { key in
        var query = base(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }, save: { key, data in
        let query = base(key)
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        insert[kSecAttrLabel as String] = "Sprava email intake"
        return SecItemAdd(insert as CFDictionary, nil)
    })

    private static func base(_ key: String) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.sprava.imap",
                kSecAttrAccount as String: key, kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
    }
}

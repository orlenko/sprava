import Foundation
import LocalAuthentication
import Security

/// The application's own subscription item only. Constructing the backend performs no credential read;
/// only an authenticated app action can enable the account. Tests inject an invented memory store.
enum ClaudeSubscriptionSecrets {
    enum Refused: Error { case unavailable }
    private static let storage = ClaudeCredentialStorage(load: {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }, save: { value in
        let query = base
        if let value {
            let data = Data(value.utf8)
            guard !data.isEmpty, data.count <= 16_384 else { throw Refused.unavailable }
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var insert = query
                insert[kSecValueData as String] = data
                insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                insert[kSecAttrLabel as String] = "Sprava Claude subscription"
                return SecItemAdd(insert as CFDictionary, nil)
            }
            return status
        } else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecItemNotFound ? errSecSuccess : status
        }
    })
    static let keychain = ClaudeConversationRuntime.Secrets(read: { try storage.read() }, replace: { try storage.replace($0) }, persistent: { storage.persistent })
    private static var base: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "org.sprava.claude.subscription",
                kSecAttrAccount as String: "app-account", kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
    }
}

/// An ad-hoc development runtime has no provisioned Keychain access group (Apple TN3137).
/// Only that precise refusal gets an in-memory fallback; locked/damaged Keychains still fail closed.
/// No plaintext fallback file or personal Claude store is ever read or written.
final class ClaudeCredentialStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let load: @Sendable () -> (OSStatus, Data?)
    private let save: @Sendable (String?) throws -> OSStatus
    private var credential: String?
    private var remembered = false
    init(load: @escaping @Sendable () -> (OSStatus, Data?), save: @escaping @Sendable (String?) throws -> OSStatus) {
        self.load = load; self.save = save
    }
    var persistent: Bool { lock.lock(); defer { lock.unlock() }; return remembered }
    func read() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        if let credential { return credential }
        let (status, data) = load()
        if status == errSecMissingEntitlement || status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data, data.count <= 16_384,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw ClaudeSubscriptionSecrets.Refused.unavailable }
        credential = value; remembered = true; return value
    }
    func replace(_ value: String?) throws {
        lock.lock(); defer { lock.unlock() }
        let status = try save(value)
        guard status == errSecSuccess || status == errSecMissingEntitlement else { throw ClaudeSubscriptionSecrets.Refused.unavailable }
        credential = value; remembered = status == errSecSuccess
    }
}

import Foundation
import LocalAuthentication
import Security

/// The application's own subscription item only. Constructing the backend performs no credential read;
/// only an authenticated app action can enable the account. Tests inject an invented memory store.
enum ClaudeSubscriptionSecrets {
    enum Refused: Error { case unavailable }
    static let keychain = ClaudeConversationRuntime.Secrets(read: {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, data.count <= 16_384,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { throw Refused.unavailable }
        return value
    }, replace: { value in
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
                guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw Refused.unavailable }
            } else if status != errSecSuccess { throw Refused.unavailable }
        } else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw Refused.unavailable }
        }
    })
    private static var base: [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = true
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "org.sprava.claude.subscription",
                kSecAttrAccount as String: "app-account", kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: true, kSecUseAuthenticationContext as String: context]
    }
}

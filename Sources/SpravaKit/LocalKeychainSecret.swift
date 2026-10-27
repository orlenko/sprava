import Foundation
import LocalAuthentication
import Security

/// Local credentials only. Provisioned apps use the data-protection Keychain; an ad-hoc app uses
/// the Mac login Keychain only when the former reports a missing entitlement (Apple TN3137).
/// The login Keychain's default ACL trusts the creating app, never every application.
package struct LocalKeychainSecret: Sendable {
    private let service: String
    private let label: String
    private let operations: Operations

    package init(service: String, label: String) {
        self.init(service: service, label: label, operations: .system)
    }

    init(service: String, label: String, operations: Operations) {
        self.service = service; self.label = label; self.operations = operations
    }

    package func read(account: String) -> (OSStatus, Data?) {
        guard !service.isEmpty, !account.isEmpty else { return (errSecParam, nil) }
        func read(protected: Bool) -> (OSStatus, Data?) {
            var query = query(account: account, protected: protected, allowInteraction: false)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return operations.read(query)
        }
        let result = read(protected: true)
        return result.0 == errSecMissingEntitlement ? read(protected: false) : result
    }

    /// Only an explicit credential-save action may allow macOS to ask for Keychain authorization.
    /// Reads and background cleanup never open an authorization dialog.
    package func write(_ data: Data?, account: String, allowInteraction: Bool = false) -> OSStatus {
        guard !service.isEmpty, !account.isEmpty else { return errSecParam }
        func write(protected: Bool) -> OSStatus {
            let query = query(account: account, protected: protected, allowInteraction: allowInteraction)
            guard let data else {
                let status = operations.remove(query)
                return status == errSecItemNotFound ? errSecSuccess : status
            }
            let changes = [kSecValueData as String: data]
            let status = operations.update(query, changes)
            guard status == errSecItemNotFound else { return status }
            var insert = query
            insert[kSecValueData as String] = data
            insert[kSecAttrLabel as String] = label
            if protected { insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly }
            // With no custom SecAccess, the Mac Keychain creates its normal app-only ACL.
            let added = operations.add(insert)
            return added == errSecDuplicateItem ? operations.update(query, changes) : added
        }
        let status = write(protected: true)
        return status == errSecMissingEntitlement ? write(protected: false) : status
    }

    private func query(account: String, protected: Bool, allowInteraction: Bool) -> [String: Any] {
        let context = LAContext(); context.interactionNotAllowed = !allowInteraction
        return [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account,
                kSecAttrSynchronizable as String: false, kSecUseDataProtectionKeychain as String: protected,
                kSecUseAuthenticationContext as String: context]
    }

    struct Operations: Sendable {
        let read: @Sendable ([String: Any]) -> (OSStatus, Data?)
        let update: @Sendable ([String: Any], [String: Any]) -> OSStatus
        let add: @Sendable ([String: Any]) -> OSStatus
        let remove: @Sendable ([String: Any]) -> OSStatus

        static let system = Operations(read: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
           add: { SecItemAdd($0 as CFDictionary, nil) }, remove: { SecItemDelete($0 as CFDictionary) })
    }
}

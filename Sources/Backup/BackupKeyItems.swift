import Foundation
import LocalAuthentication
import Security
import SpravaKit

/// Where the runtime keeps the backup key's items (decisions.md A20). A provisioned runtime uses the data-protection
/// Keychain, where local items are `ThisDeviceOnly`. An ad-hoc runtime is refused there for the missing entitlement
/// (Apple TN3137), and only that refusal moves its local items to the Mac login Keychain: never synchronized, and read
/// without asking only by the program that made them, but not bound to this device the way `ThisDeviceOnly` is (a
/// login Keychain moved to another Mac carries them). Synchronized items exist only in the data-protection Keychain, so
/// an ad-hoc runtime can neither read, list nor remove them.
extension BackupKey {
    /// The calls on Keychain items, by query; tests pass their own, so no test touches a real item.
    struct Calls {
        var copy: (_ query: [String: Any]) -> (OSStatus, Data?)
        var update: (_ query: [String: Any], _ changes: [String: Any]) -> OSStatus
        var add: (_ attributes: [String: Any]) -> OSStatus
        var delete: (_ query: [String: Any]) -> OSStatus
        /// The attributes of every item a query matches.
        var list: (_ query: [String: Any]) -> (OSStatus, [[String: Any]]?)

        static var system: Calls {
            Calls(copy: { query in
                var out: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &out)
                return (status, out as? Data)
            }, update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
               add: { SecItemAdd($0 as CFDictionary, nil) }, delete: { SecItemDelete($0 as CFDictionary) },
               list: { query in
                var out: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &out)
                return (status, out as? [[String: Any]])
            })
        }
    }

    /// A local item in the login Keychain. `interactive` is true only while the person saves the key, the one time
    /// macOS may ask to let a rebuilt runtime use it; reads and background work never ask.
    static func loginQuery(account: String, interactive: Bool) -> [String: Any] {
        let context = LAContext()
        context.interactionNotAllowed = !interactive
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false,
                kSecUseDataProtectionKeychain as String: false, kSecUseAuthenticationContext as String: context]
    }

    static func read(_ acct: String, synchronizable: Bool, interactive: Bool, calls: Calls) -> (OSStatus, String?) {
        func copy(_ base: [String: Any]) -> (OSStatus, String?) {
            var query = base
            query[kSecReturnData as String] = true
            let (status, data) = calls.copy(query)
            guard status == errSecSuccess else { return (status, nil) }
            guard let data else { return (errSecDecode, nil) }
            return (status, String(decoding: data, as: UTF8.self))
        }
        let protected = copy(query(account: acct, synchronizable: synchronizable))
        guard protected.0 == errSecMissingEntitlement, !synchronizable else { return protected }
        return copy(loginQuery(account: acct, interactive: interactive))
    }

    /// Stores `key` under `acct`, changed in place when it is there (never deleted first), as `put` does.
    static func write(_ key: String, account acct: String, synchronizable: Bool, interactive: Bool, calls: Calls) throws {
        let items = Items(update: { calls.update($0 as? [String: Any] ?? [:], $1 as? [String: Any] ?? [:]) },
                          add: { calls.add($0 as? [String: Any] ?? [:]) })
        do {
            try put(key, account: acct, synchronizable: synchronizable, items: items)
            return
        } catch let failure as Failure where failure.status == errSecMissingEntitlement && !synchronizable {}
        let query = loginQuery(account: acct, interactive: interactive)
        let changes: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = calls.update(query, changes)
        if status == errSecItemNotFound {
            status = calls.add(query.merging([kSecValueData as String: Data(key.utf8), kSecAttrLabel as String: "Sprava backup key"]) { $1 })
            if status == errSecDuplicateItem { status = calls.update(query, changes) }
        }
        guard status == errSecSuccess else {
            throw Failure(message: "the Keychain refused the backup key (\(status))", status: status)
        }
    }

    static func remove(_ acct: String, synchronizable: Bool, interactive: Bool, calls: Calls) -> OSStatus {
        let status = calls.delete(query(account: acct, synchronizable: synchronizable))
        guard status == errSecMissingEntitlement, !synchronizable else { return status }
        return calls.delete(loginQuery(account: acct, interactive: interactive))
    }
}

extension BackupKey.Keychain {
    /// The Keychain the runtime uses. `interactive` only for the person's own save of a key (setup and its pending
    /// step); every read that runs unattended uses the default.
    static func system(calls: BackupKey.Calls = .system, interactive: Bool = false) -> BackupKey.Keychain {
        var keychain = BackupKey.Keychain(put: { try BackupKey.write($0, account: $1, synchronizable: $2, interactive: interactive, calls: calls) },
                                          delete: { BackupKey.remove($0, synchronizable: $1, interactive: interactive, calls: calls) },
                                          read: { BackupKey.read($0, synchronizable: $1, interactive: interactive, calls: calls) })
        // The Keychain namespace is per user, regardless of a development support-folder override. Every
        // production caller must therefore lock the same canonical path; mocked Keychains retain test injection.
        keychain.lockURL = SpravaPaths.supportDirectory(environment: [:]).appendingPathComponent("backup/keychain.lock")
        keychain.accounts = { BackupKey.synchronizedAccounts(calls: calls) }
        return keychain
    }
}

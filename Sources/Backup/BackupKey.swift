import Foundation
import Security
import SpravaKit

/// The backup key (docs/backup.md §4). The runtime keeps a this-device-only copy in the Keychain so backups run
/// unattended; the person keeps their own copy, or asks Sprava to keep one in iCloud Keychain.
/// `SPRAVA_BACKUP_KEY_FILE` replaces the Keychain in tests and development runs.
public enum BackupKey {
    static let service = "ca.orlenko.sprava.backup"
    static let account = "repository-key"
    static let syncedAccount = "repository-key-icloud"
    static let rollbackAccount = "repository-key-rollback"

    struct StoredKeys: Codable, Equatable {
        var local: String?
        var synchronized: String?
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// A new key: 30 characters of base32 in groups of five, about 150 bits, easy to type back. The bytes come from
    /// `arc4random_buf`, which cannot fail: a source whose failure went unnoticed would leave every byte zero, and the
    /// key would be "AAAAA-AAAAA-AAAAA-AAAAA-AAAAA-AAAAA" on every Mac.
    public static func generate() -> String {
        var bytes = [UInt8](repeating: 0, count: 30)
        arc4random_buf(&bytes, bytes.count)
        return format(bytes)
    }

    /// The key for 30 bytes. 256 is a multiple of the alphabet's 32 letters, so every letter is as likely.
    static func format(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 30)
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // no 0/O, 1/I
        let chars = bytes.map { alphabet[Int($0) % alphabet.count] }
        return stride(from: 0, to: 30, by: 5).map { String(chars[$0..<($0 + 5)]) }.joined(separator: "-")
    }

    /// Typed keys are compared without case, spaces or dashes.
    public static func normalize(_ typed: String) -> String {
        typed.uppercased().filter { $0.isLetter || $0.isNumber }
    }

    static var fileOverride: URL? {
        ProcessInfo.processInfo.environment["SPRAVA_BACKUP_KEY_FILE"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
    }

    static func readSystem(_ acct: String, synchronizable: Bool) -> (OSStatus, String?) {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: acct, kSecReturnData as String: true]
        if synchronizable { query[kSecAttrSynchronizable as String] = true }
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return (status, nil) }
        return (status, String(decoding: data, as: UTF8.self))
    }

    public static func load() -> String? {
        if let file = fileOverride { return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return load(keychain: .system)
    }

    static func load(keychain: Keychain) -> String? {
        // This item is the transaction journal for a key change. Until it is deleted, the old key remains the only
        // committed one even if a crash has already changed either ordinary Keychain item.
        let (rollbackStatus, rollbackText) = keychain.read(rollbackAccount, false)
        if rollbackStatus == errSecSuccess {
            guard let rollbackText, let data = rollbackText.data(using: .utf8),
                  let keys = try? JSONDecoder().decode(StoredKeys.self, from: data) else { return nil }
            return keys.local ?? keys.synchronized
        }
        guard rollbackStatus == errSecItemNotFound else { return nil }
        for acct in [account, syncedAccount] {
            let (status, value) = keychain.read(acct, acct == syncedAccount)
            if status == errSecSuccess, let value { return value }
        }
        return nil
    }

    static let pendingAccount = "repository-key-pending"

    /// A key shown to the person and not yet typed back. Kept on this device only, until confirmed.
    public static func storePending(_ key: String) throws {
        if let file = fileOverride { try AtomicFile.write(Data(key.utf8), to: file.appendingPathExtension("pending")); return }
        try put(key, account: pendingAccount, synchronizable: false)
    }

    public static func loadPending() -> String? {
        if let file = fileOverride { return try? String(contentsOf: file.appendingPathExtension("pending"), encoding: .utf8) }
        var out: CFTypeRef?
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: pendingAccount, kSecReturnData as String: true]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public static func clearPending() {
        if let file = fileOverride { try? FileManager.default.removeItem(at: file.appendingPathExtension("pending")); return }
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: pendingAccount] as CFDictionary)
    }

    /// The Keychain calls `store` makes; tests pass their own, so no test touches the person's Keychain.
    struct Keychain {
        var put: (_ key: String, _ account: String, _ synchronizable: Bool) throws -> Void
        var delete: (_ account: String, _ synchronizable: Bool) -> OSStatus
        var read: (_ account: String, _ synchronizable: Bool) -> (OSStatus, String?)
        init(put: @escaping (_ key: String, _ account: String, _ synchronizable: Bool) throws -> Void,
             delete: @escaping (_ account: String, _ synchronizable: Bool) -> OSStatus,
             read: @escaping (_ account: String, _ synchronizable: Bool) -> (OSStatus, String?) = { _, _ in (errSecItemNotFound, nil) }) {
            self.put = put
            self.delete = delete
            self.read = read
        }
        static var system: Keychain {
            Keychain(put: { try BackupKey.put($0, account: $1, synchronizable: $2) }, delete: { acct, synchronizable in
                var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                            kSecAttrAccount as String: acct]
                if synchronizable { query[kSecAttrSynchronizable as String] = true }
                return SecItemDelete(query as CFDictionary)
            }, read: { acct, synchronizable in
                readSystem(acct, synchronizable: synchronizable)
            })
        }
    }

    /// Stores the key on this device, and in iCloud Keychain when the person chose that.
    public static func store(_ key: String, inICloudKeychain: Bool) throws {
        if let file = fileOverride {
            try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
            try AtomicFile.write(Data(key.utf8), to: file)
            return
        }
        try store(key, inICloudKeychain: inICloudKeychain, keychain: .system)
    }

    /// Choosing not to keep the key in iCloud Keychain takes an earlier copy out of it, or says it could not:
    /// a copy left there would stay as reachable as the person chose it not to be, and `load()` would still use it.
    static func store(_ key: String, inICloudKeychain: Bool, keychain: Keychain) throws {
        func read(_ acct: String, _ synchronized: Bool) throws -> String? {
            let (status, value) = keychain.read(acct, synchronized)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure(message: "the existing backup key could not be read (\(status)); nothing was changed")
            }
            return value
        }

        func remove(_ acct: String, _ synchronized: Bool) throws {
            let status = keychain.delete(acct, synchronized)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw Failure(message: "a backup key could not be removed from the Keychain (\(status))")
            }
        }

        func restore(_ previous: StoredKeys) throws {
            if let local = previous.local { try keychain.put(local, account, false) }
            else { try remove(account, false) }
            if let synchronized = previous.synchronized { try keychain.put(synchronized, syncedAccount, true) }
            else { try remove(syncedAccount, true) }
            try remove(rollbackAccount, false)
        }

        // Finish rolling back an interrupted earlier change before starting another. `load()` also reads this journal
        // first, so every crash point keeps returning the old committed key.
        if let journal = try read(rollbackAccount, false) {
            guard let data = journal.data(using: .utf8), let previous = try? JSONDecoder().decode(StoredKeys.self, from: data) else {
                throw Failure(message: "the saved backup-key rollback record is unreadable; nothing was changed")
            }
            try restore(previous)
        }

        let previous = StoredKeys(local: try read(account, false), synchronized: try read(syncedAccount, true))
        let data = try JSONEncoder().encode(previous)
        guard let journal = String(data: data, encoding: .utf8) else {
            throw Failure(message: "the backup-key rollback record could not be made; nothing was changed")
        }
        try keychain.put(journal, rollbackAccount, false)

        do {
            if inICloudKeychain {
                try keychain.put(key, syncedAccount, true)
            } else {
                let status = keychain.delete(syncedAccount, true)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw Failure(message: "the backup key could not be taken out of iCloud Keychain (\(status)); remove it there, or keep it there")
                }
            }
            try keychain.put(key, account, false)
            try remove(rollbackAccount, false)
        } catch {
            do {
                try restore(previous)
            } catch {
                throw Failure(message: "the key change failed and its earlier Keychain values could not be restored (\(error))")
            }
            throw error
        }
    }

    /// The Keychain's item calls, which `put` makes; tests pass their own.
    struct Items {
        var update: (_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
        var add: (_ attributes: CFDictionary) -> OSStatus
        static var system: Items { Items(update: { SecItemUpdate($0, $1) }, add: { SecItemAdd($0, nil) }) }
    }

    /// Stores the key under `acct`. An item already there is changed in place, never deleted first: a change the
    /// Keychain refuses leaves the key that works, so unattended backups go on.
    static func put(_ key: String, account acct: String, synchronizable: Bool, items: Items = .system) throws {
        var base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: acct]
        if synchronizable { base[kSecAttrSynchronizable as String] = true }
        let values: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Sprava backup key",
        ]
        var status = items.update(base as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound { status = items.add(base.merging(values) { $1 } as CFDictionary) }
        guard status == errSecSuccess else { throw Failure(message: "the Keychain refused the backup key (\(status))") }
    }
}

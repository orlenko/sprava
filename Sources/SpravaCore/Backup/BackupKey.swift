import Foundation
import Security

/// The backup key (docs/backup.md §4). The runtime keeps a this-device-only copy in the Keychain so backups run
/// unattended; the person keeps their own copy, or asks Sprava to keep one in iCloud Keychain.
/// `SPRAVA_BACKUP_KEY_FILE` replaces the Keychain in tests and development runs.
public enum BackupKey {
    static let service = "ca.orlenko.sprava.backup"
    static let account = "repository-key"
    static let syncedAccount = "repository-key-icloud"

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// A new key: 30 characters of base32 in groups of five, about 150 bits, easy to type back.
    public static func generate() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")   // no 0/O, 1/I
        var bytes = [UInt8](repeating: 0, count: 30)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
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

    public static func load() -> String? {
        if let file = fileOverride { return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
        for acct in [account, syncedAccount] {
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                        kSecAttrAccount as String: acct, kSecReturnData as String: true]
            if acct == syncedAccount { query[kSecAttrSynchronizable as String] = true }
            var out: CFTypeRef?
            if SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data {
                return String(decoding: data, as: UTF8.self)
            }
        }
        return nil
    }

    /// Stores the key on this device, and in iCloud Keychain when the person chose that.
    public static func store(_ key: String, inICloudKeychain: Bool) throws {
        if let file = fileOverride {
            try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
            try AtomicFile.write(Data(key.utf8), to: file)
            return
        }
        try put(key, account: account, synchronizable: false)
        if inICloudKeychain { try put(key, account: syncedAccount, synchronizable: true) }
    }

    static func put(_ key: String, account acct: String, synchronizable: Bool) throws {
        var base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: acct]
        if synchronizable { base[kSecAttrSynchronizable as String] = true }
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(key.utf8)
        add[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        add[kSecAttrLabel as String] = "Sprava backup key"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(message: "the Keychain refused the backup key (\(status))") }
    }
}

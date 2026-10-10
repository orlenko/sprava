import CryptoKit
import Foundation
import Security

extension BackupKey {
    static let recoveryPrefix = "repository-key-recovery-"

    static func recoveryAccount(_ key: String) -> String {
        recoveryPrefix + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func archive(_ key: String, in keychain: Keychain) throws {
        let name = recoveryAccount(key)
        let (status, existing) = keychain.read(name, true)
        if status == errSecSuccess {
            guard existing == key else { throw Failure(message: "a cloud recovery key is damaged; nothing was changed") }
            return
        }
        guard status == errSecItemNotFound else { throw Failure(message: "a cloud recovery key could not be read (\(status))") }
        try keychain.put(key, name, true)
    }

    static let historyAccount = "repository-key-history"

    /// Earlier keys this Mac keeps on the device only after the person opts out of iCloud Keychain, so taking the
    /// cloud copies away never loses the only key to an older repository or snapshot.
    static func localHistory(_ keychain: Keychain) throws -> [String] {
        let (status, text) = keychain.read(historyAccount, false)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let text, let data = text.data(using: .utf8),
              let keys = try? JSONDecoder().decode([String].self, from: data) else {
            throw Failure(message: "the earlier backup keys kept on this Mac could not be read (\(status))")
        }
        return keys
    }

    static func keepLocally(_ values: [String?], in keychain: Keychain) throws {
        var keys = try localHistory(keychain)
        let before = keys.count
        for case let value? in values where !keys.contains(value) { keys.append(value) }
        guard keys.count != before else { return }
        guard let text = String(data: try JSONEncoder().encode(keys), encoding: .utf8) else {
            throw Failure(message: "the earlier backup keys could not be kept on this Mac")
        }
        try keychain.put(text, historyAccount, false)
    }

    /// Password data must be fetched individually: SecItemCopyMatching forbids ReturnData with MatchLimitAll.
    static func synchronizedAccounts() -> (OSStatus, [String]) {
        var q = query(account: syncedAccount, synchronizable: true)
        q[kSecAttrAccount as String] = nil
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { return (status, []) }
        guard let records = result as? [[String: Any]] else { return (errSecDecode, []) }
        var names: [String] = []
        for record in records {
            guard let name = record[kSecAttrAccount as String] as? String else { return (errSecDecode, []) }
            if name.hasPrefix(recoveryPrefix) { names.append(name) }
        }
        return (status, names)
    }

    static func recoveryRecords(_ keychain: Keychain) throws -> [String: String] {
        let (status, names) = keychain.accounts()
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(message: "the cloud recovery keys could not be listed (\(status)); nothing was changed")
        }
        var records: [String: String] = [:]
        for name in names where name.hasPrefix(recoveryPrefix) {
            let (status, value) = keychain.read(name, true)
            guard status == errSecSuccess, let value, recoveryAccount(value) == name else {
                throw Failure(message: "a cloud recovery key is unavailable or damaged; nothing was changed")
            }
            records[name] = value
        }
        return records
    }

    /// Try these keys against the selected repository during recovery. Earlier opted-in keys remain available
    /// after replacement, including when a different Mac sees only the synchronized items from an interrupted run.
    public static func recoveryKeys() throws -> [String] {
        try recoveryKeys(environment: ProcessInfo.processInfo.environment, keychain: .system)
    }

    static func recoveryKeys(environment: [String: String], keychain: Keychain) throws -> [String] {
        if let file = try fileOverride(environment: environment) {
            return (try? String(contentsOf: file, encoding: .utf8)).map {
                [$0.trimmingCharacters(in: .whitespacesAndNewlines)]
            } ?? []
        }
        return try keychain.withLock {
            var keys: [String] = []
            func append(_ value: String?) {
                if let value, !keys.contains(value) { keys.append(value) }
            }

            if let committed = try rollbackRecord(keychain) {
                append(committed.local)
                append(committed.synchronized)
                for value in (committed.recovery ?? [:]).sorted(by: { $0.key < $1.key }).map(\.value) {
                    append(value)
                }
            } else {
                let (localStatus, local) = keychain.read(account, false)
                guard localStatus == errSecSuccess || localStatus == errSecItemNotFound else {
                    throw Failure(message: "the local backup key could not be read (\(localStatus))")
                }
                append(local)
                let (cloudStatus, cloud) = keychain.read(syncedAccount, true)
                guard cloudStatus == errSecSuccess || cloudStatus == errSecItemNotFound else {
                    throw Failure(message: "the cloud recovery key could not be read (\(cloudStatus))")
                }
                append(cloud)
            }
            for value in try localHistory(keychain) { append(value) }
            for value in try recoveryRecords(keychain).sorted(by: { $0.key < $1.key }).map(\.value) where !keys.contains(value) {
                keys.append(value)
            }
            return keys
        }
    }
}

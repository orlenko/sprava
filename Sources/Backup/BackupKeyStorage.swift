import Foundation
import Security
import SpravaKit

/// The backup key (docs/backup.md §4). The runtime keeps a local copy in the Keychain so backups run unattended; the
/// person keeps their own copy, or asks Sprava to keep one in iCloud Keychain. A provisioned runtime, with the
/// `keychain-access-groups` entitlement `$(TeamIdentifierPrefix)ca.orlenko.sprava`, keeps it in the data-protection
/// Keychain, this device only; an ad-hoc one keeps it in the login Keychain and cannot use iCloud Keychain
/// (`BackupKeyItems.swift`). `SPRAVA_BACKUP_KEY_FILE` replaces the Keychain in tests and development runs.
extension BackupKey {
    static let service = "ca.orlenko.sprava.backup"
    /// The access group both hosts share. It must match the signed entitlement exactly, team prefix included, so it
    /// is derived from this process's signature rather than written down; without a team it is left out.
    static let accessGroup: String? = accessGroup(team: signingTeam())

    static func accessGroup(team: String?) -> String? {
        guard let team, !team.isEmpty else { return nil }
        return team + ".ca.orlenko.sprava"
    }

    static func signingTeam() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return nil }
        return info[kSecCodeInfoTeamIdentifier as String] as? String
    }
    static let account = "repository-key"
    static let syncedAccount = "repository-key-icloud"
    static let rollbackAccount = "repository-key-rollback"

    struct StoredKeys: Codable, Equatable {
        var local: String?
        var synchronized: String?
        var recovery: [String: String]? = nil
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        /// The Keychain's status, when the Keychain refused.
        var status: OSStatus? = nil
        public var description: String { message }
        init(message: String, status: OSStatus? = nil) { self.message = message; self.status = status }
    }

    static func fileOverride(environment: [String: String]) throws -> URL? {
        guard let path = environment["SPRAVA_BACKUP_KEY_FILE"] else { return nil }
        guard path.hasPrefix("/"), !path.contains("\0") else {
            throw Failure(message: "SPRAVA_BACKUP_KEY_FILE must be an absolute file path; the Keychain was not accessed")
        }
        return URL(fileURLWithPath: path)
    }

    /// macOS needs the data-protection Keychain to enforce ThisDeviceOnly accessibility. Use the same namespace
    /// for every read, write and deletion, and explicitly distinguish local items from synchronized ones.
    static func query(account: String, synchronizable: Bool) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecAttrSynchronizable as String: synchronizable,
                                    kSecUseDataProtectionKeychain as String: true]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public static func load() -> String? {
        load(environment: ProcessInfo.processInfo.environment, keychain: .system)
    }

    static func load(environment: [String: String], keychain: Keychain) -> String? {
        do {
            if let file = try fileOverride(environment: environment) {
                return (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch { return nil }
        return load(keychain: keychain)
    }

    static func load(keychain: Keychain) -> String? {
        try? keychain.withLock { loadUnlocked(keychain: keychain) }
    }

    static func loadUnlocked(keychain: Keychain) -> String? {
        do {
            // Until this journal is deleted, its values are the committed ones even if a crash changed the live items.
            if let keys = try rollbackRecord(keychain) { return keys.local ?? keys.synchronized }
            let (localStatus, local) = keychain.read(account, false)
            if localStatus == errSecSuccess { return local }
            // The synchronized slot deliberately retains an older recovery key after replacement. Use it only when
            // this Mac truly has no local item, never when the current item is merely unreadable.
            guard localStatus == errSecItemNotFound else { return nil }
            let (cloudStatus, cloud) = keychain.read(syncedAccount, true)
            guard cloudStatus == errSecSuccess || cloudStatus == errSecItemNotFound else { return nil }
            return cloud
        } catch {
            return nil
        }
    }

    static func rollbackRecord(_ keychain: Keychain) throws -> StoredKeys? {
        let (status, text) = keychain.read(rollbackAccount, false)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(message: "the saved backup-key rollback record could not be read (\(status))")
        }
        guard status == errSecSuccess else { return nil }
        guard let text, let data = text.data(using: .utf8),
              let keys = try? JSONDecoder().decode(StoredKeys.self, from: data) else {
            throw Failure(message: "the saved backup-key rollback record is unreadable")
        }
        return keys
    }

    static let pendingAccount = "repository-key-pending"

    /// A key shown to the person and not yet typed back. Kept on this device only, until confirmed.
    public static func storePending(_ key: String) throws {
        try storePending(key, environment: ProcessInfo.processInfo.environment, keychain: .system(interactive: true))
    }

    static func storePending(_ key: String, environment: [String: String], keychain: Keychain) throws {
        if let file = try fileOverride(environment: environment) {
            try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
            try AtomicFile.write(Data(key.utf8), to: file.appendingPathExtension("pending"))
            return
        }
        try keychain.put(key, pendingAccount, false)
    }

    public static func loadPending() -> String? {
        loadPending(environment: ProcessInfo.processInfo.environment, keychain: .system)
    }

    static func loadPending(environment: [String: String], keychain: Keychain) -> String? {
        do {
            if let file = try fileOverride(environment: environment) {
                return try? String(contentsOf: file.appendingPathExtension("pending"), encoding: .utf8)
            }
        } catch { return nil }
        let (status, value) = keychain.read(pendingAccount, false)
        return status == errSecSuccess ? value : nil
    }

    public static func clearPending() throws {
        try clearPending(environment: ProcessInfo.processInfo.environment, keychain: .system(interactive: true))
    }

    static func clearPending(environment: [String: String], keychain: Keychain) throws {
        if let file = try fileOverride(environment: environment) {
            do { try FileManager.default.removeItem(at: file.appendingPathExtension("pending")) }
            catch CocoaError.fileNoSuchFile { return }
            catch { throw Failure(message: "the pending backup key could not be removed (\(error))") }
            return
        }
        let status = keychain.delete(pendingAccount, false)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure(message: "the pending backup key could not be removed from the Keychain (\(status))")
        }
    }

    /// The Keychain calls `store` makes; tests pass their own, so no test touches the person's Keychain.
    struct Keychain {
        var lockURL = SpravaPaths.supportDirectory().appendingPathComponent("backup/keychain.lock")
        var accounts: () -> (OSStatus, [String]) = { (errSecSuccess, []) }
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
        /// The runtime's Keychain for unattended reads (`system(calls:interactive:)`).
        static var system: Keychain { system() }
    }

    /// What a store did with iCloud Keychain.
    public struct Stored: Sendable, Equatable {
        /// False when iCloud Keychain was out of reach, so an earlier copy there could be neither found nor removed;
        /// the caller keeps saying so (`Backup.recordICloudKeychainChecked`). Never a claim that the cloud is empty.
        public let cloudChecked: Bool
    }

    /// Stores the key on this device, and in iCloud Keychain when the person chose that.
    @discardableResult
    public static func store(_ key: String, inICloudKeychain: Bool) throws -> Stored {
        try store(key, inICloudKeychain: inICloudKeychain, environment: ProcessInfo.processInfo.environment,
                  keychain: .system(interactive: true))
    }

    @discardableResult
    static func store(_ key: String, inICloudKeychain: Bool, environment: [String: String], keychain: Keychain) throws -> Stored {
        if let file = try fileOverride(environment: environment) {
            try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
            try AtomicFile.write(Data(key.utf8), to: file)
            // A development key file has no iCloud Keychain beside it to check.
            return Stored(cloudChecked: true)
        }
        return try store(key, inICloudKeychain: inICloudKeychain, keychain: keychain)
    }

    /// Choosing not to keep the key in iCloud Keychain takes an earlier copy out of it, or says it could not:
    /// a copy left there would stay as reachable as the person chose it not to be, and `load()` would still use it.
    @discardableResult
    static func store(_ key: String, inICloudKeychain: Bool, keychain: Keychain) throws -> Stored {
        try keychain.withLock { try storeUnlocked(key, inICloudKeychain: inICloudKeychain, keychain: keychain) }
    }

    private static func storeUnlocked(_ key: String, inICloudKeychain: Bool, keychain: Keychain) throws -> Stored {
        // A runtime without the entitlement cannot reach iCloud Keychain at all (`BackupKeyItems.swift`). Opting in
        // there is refused before anything changes. Opting out keeps the key on this Mac and reports the cloud as not
        // checked: an earlier copy there can be neither found nor removed from here.
        let cloudReachable = keychain.read(syncedAccount, true).0 != errSecMissingEntitlement
        if !cloudReachable, inICloudKeychain {
            throw Failure(message: "iCloud Keychain is unavailable in this development build; the backup key can be kept on this Mac only. Nothing was changed.",
                          status: errSecMissingEntitlement)
        }
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
            // This journal is local, while synchronized items can change independently on another Mac. Roll back
            // only this Mac's item. Cloud operations are monotonic: opt-in adds archives and opt-out removes them,
            // so replaying saved cloud state here could undo another Mac's completed choice.
            if let local = previous.local { try keychain.put(local, account, false) }
            else { try remove(account, false) }
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

        // Out of reach, the cloud's part of the journal stays unknown (nil), never read as empty: the journal only ever
        // restores this Mac's item.
        let previous = StoredKeys(local: try read(account, false), synchronized: cloudReachable ? try read(syncedAccount, true) : nil,
                                  recovery: cloudReachable ? try recoveryRecords(keychain) : nil)
        func journal(_ keys: StoredKeys) throws -> String {
            let data = try JSONEncoder().encode(keys)
            guard let text = String(data: data, encoding: .utf8) else {
                throw Failure(message: "the backup-key rollback record could not be made; nothing was changed")
            }
            return text
        }
        let rollback = try journal(previous)
        guard !rollback.isEmpty else {
            throw Failure(message: "the backup-key rollback record could not be made; nothing was changed")
        }
        try keychain.put(rollback, rollbackAccount, false)

        var localCommitted = false
        do {
            // The key being replaced may be the only one that opens an earlier repository; keep it on this Mac
            // before the local slot and the journal move on.
            if let replaced = previous.local, replaced != key { try keepLocally([replaced], in: keychain) }
            if inICloudKeychain {
                // Preserve the existing synchronized slot: its older key may already be on another Mac while
                // a newly added item still waits for sync. Each recovery key has an independent, immutable name.
                // Keys kept on this Mac only, after an earlier opt-out or replacement, go back too, so a new Mac
                // can still open an older repository without typing.
                if let previous = previous.synchronized { try archive(previous, in: keychain) }
                for earlier in try localHistory(keychain) { try archive(earlier, in: keychain) }
                try archive(key, in: keychain)
            }
            try keychain.put(key, account, false)
            var committed = previous
            committed.local = key
            // Advance the journal before any destructive cloud cleanup. If cleanup or deleting the journal fails,
            // both persisted local records still name the usable key and the next call can safely retry.
            try keychain.put(try journal(committed), rollbackAccount, false)
            localCommitted = true
            if !inICloudKeychain, cloudReachable {
                // Keep every cloud copy on this Mac before it leaves iCloud: an older key may be the only one
                // that opens an earlier repository.
                try keepLocally([try read(syncedAccount, true)] + (previous.recovery ?? [:]).values.sorted(), in: keychain)
                let status = keychain.delete(syncedAccount, true)
                guard status == errSecSuccess || status == errSecItemNotFound else {
                    throw Failure(message: "the backup key could not be taken out of iCloud Keychain (\(status)); remove it there, or keep it there")
                }
                // Re-list until two consecutive reads are empty, so a record that synchronizes while cleanup runs is
                // caught instead of being missed by the transaction's initial snapshot. Records that keep coming back
                // fail the opt-out rather than loop forever. A record another Mac adds after this returns is outside
                // any one Mac's reach; the journal stays committed, so the next store sweeps again.
                var emptyPasses = 0, passes = 0
                while emptyPasses < 2 {
                    passes += 1
                    guard passes <= 8 else {
                        throw Failure(message: "older backup keys keep reappearing in iCloud Keychain; remove them there, or keep the key there")
                    }
                    let records = try recoveryRecords(keychain)
                    if records.isEmpty { emptyPasses += 1; continue }
                    emptyPasses = 0
                    try keepLocally(records.sorted { $0.key < $1.key }.map(\.value), in: keychain)
                    for name in records.keys.sorted() { try remove(name, true) }
                }
            }
            try remove(rollbackAccount, false)
            return Stored(cloudChecked: cloudReachable)
        } catch {
            if localCommitted { throw error }
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
        let base = query(account: acct, synchronizable: synchronizable)
        let values: [String: Any] = [
            kSecValueData as String: Data(key.utf8),
            kSecAttrAccessible as String: synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "Sprava backup key",
        ]
        var status = items.update(base as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            status = items.add(base.merging(values) { $1 } as CFDictionary)
            // Two writers can add the same immutable recovery item through different Macs' local locks.
            if status == errSecDuplicateItem { status = items.update(base as CFDictionary, values as CFDictionary) }
        }
        guard status == errSecSuccess else { throw Failure(message: "the Keychain refused the backup key (\(status))", status: status) }
    }
}

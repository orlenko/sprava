@testable import Backup
import Foundation
import Security
import Testing

/// Invented keys and an in-memory Keychain: these tests never access the person's Keychain.
@Suite struct BackupKeyTests {
    final class FakeKeychain: @unchecked Sendable {
        var calls: [String] = []
        var deleteStatus: OSStatus = errSecSuccess
        var values: [String: String] = [:]
        var keychain: BackupKey.Keychain {
            var keychain = BackupKey.Keychain(put: { key, acct, sync in
                self.calls.append("put \(acct) \(sync)")
                self.values[acct] = key
            }, delete: { acct, sync in
                self.calls.append("delete \(acct) \(sync)")
                if acct == BackupKey.syncedAccount, self.deleteStatus != errSecSuccess { return self.deleteStatus }
                return self.values.removeValue(forKey: acct) == nil ? errSecItemNotFound : errSecSuccess
            }, read: { acct, _ in
                self.values[acct].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            })
            keychain.accounts = { (errSecSuccess, self.values.keys.filter { $0.hasPrefix(BackupKey.recoveryPrefix) }) }
            return keychain
        }
    }

    @Test func optingOutOfICloudKeychainDeletesTheSynchronizedKey() throws {
        let fake = FakeKeychain()
        try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: true, keychain: fake.keychain)
        #expect(fake.values[BackupKey.account] == "INVNT-KEYAA-BBBBB")
        #expect(fake.values[BackupKey.syncedAccount] == nil)
        #expect(fake.values[BackupKey.recoveryAccount("INVNT-KEYAA-BBBBB")] == "INVNT-KEYAA-BBBBB")
        #expect(fake.values[BackupKey.rollbackAccount] == nil)

        fake.calls = []
        try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: false, keychain: fake.keychain)
        #expect(fake.values[BackupKey.account] == "INVNT-KEYAA-BBBBB")
        #expect(fake.values[BackupKey.syncedAccount] == nil)
        #expect(!fake.values.keys.contains { $0.hasPrefix(BackupKey.recoveryPrefix) })

        // Nothing there to delete is fine; a deletion the Keychain refuses is reported.
        fake.deleteStatus = errSecItemNotFound
        try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: false, keychain: fake.keychain)
        fake.deleteStatus = errSecInteractionNotAllowed
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store("INVNT-KEYAA-BBBBB", inICloudKeychain: false, keychain: fake.keychain) }
    }
    @Test func aKeyChangeTheKeychainRefusesKeepsTheKeyThatWorks() throws {
        // A refused change throws, and nothing was deleted before it: `Items` has no delete to call.
        var calls: [String] = []
        let refusing = BackupKey.Items(update: { _, _ in calls.append("update"); return errSecInteractionNotAllowed },
                                       add: { _ in calls.append("add"); return errSecSuccess })
        #expect(throws: BackupKey.Failure.self) { try BackupKey.put("INVNT-NEWKY", account: "repository-key", synchronizable: false, items: refusing) }
        #expect(calls == ["update"])
        // An item already there is updated in place; one not there yet is added.
        calls = []
        let updating = BackupKey.Items(update: { _, _ in calls.append("update"); return errSecSuccess }, add: { _ in calls.append("add"); return errSecSuccess })
        try BackupKey.put("INVNT-NEWKY", account: "repository-key", synchronizable: false, items: updating)
        #expect(calls == ["update"])
        calls = []
        let adding = BackupKey.Items(update: { _, _ in calls.append("update"); return errSecItemNotFound }, add: { _ in calls.append("add"); return errSecSuccess })
        try BackupKey.put("INVNT-NEWKY", account: "repository-key", synchronizable: false, items: adding)
        #expect(calls == ["update", "add"])
    }
    @Test func aFailedSynchronizedKeyChangeLeavesTheLocalKeyUntouched() {
        var values = [BackupKey.account: "INVNT-OLDKY-AAAAA", BackupKey.syncedAccount: "INVNT-OLDKY-AAAAA"]
        var calls: [String] = []
        var refuseSynchronizedPut = true
        var refuseSynchronizedDelete = false
        let keychain = BackupKey.Keychain(put: { key, account, _ in
            calls.append("put \(account)")
            if account == BackupKey.recoveryAccount("INVNT-NEWKY-BBBBB"), refuseSynchronizedPut {
                throw BackupKey.Failure(message: "invented refusal")
            }
            values[account] = key
        }, delete: { account, _ in
            calls.append("delete \(account)")
            if account == BackupKey.syncedAccount, refuseSynchronizedDelete { return errSecInteractionNotAllowed }
            return values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }, read: { account, _ in
            values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        })
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: true, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(calls.first == "put \(BackupKey.rollbackAccount)")
        #expect(calls.last == "delete \(BackupKey.rollbackAccount)")
        calls = []
        refuseSynchronizedPut = false
        refuseSynchronizedDelete = true
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: false, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-NEWKY-BBBBB")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] != nil)
        #expect(BackupKey.load(keychain: keychain) == "INVNT-NEWKY-BBBBB")
    }

    @Test func aFailedLocalKeyChangeRestoresTheCloudRecoveryKey() {
        var values = [BackupKey.account: "INVNT-OLDKY-AAAAA", BackupKey.syncedAccount: "INVNT-OLDKY-AAAAA"]
        var calls: [String] = []
        let keychain = BackupKey.Keychain(put: { key, account, _ in
            calls.append("put \(account)")
            if account == BackupKey.account, key == "INVNT-NEWKY-BBBBB" { throw BackupKey.Failure(message: "invented local refusal") }
            values[account] = key
        }, delete: { account, _ in
            calls.append("delete \(account)")
            return values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }, read: { account, _ in
            values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        })
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: true, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(calls.first == "put \(BackupKey.rollbackAccount)")
        #expect(calls.last == "delete \(BackupKey.rollbackAccount)")
        calls = []
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKY-BBBBB", inICloudKeychain: false, keychain: keychain)
        }
        #expect(values[BackupKey.account] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.syncedAccount] == "INVNT-OLDKY-AAAAA")
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(calls.first == "put \(BackupKey.rollbackAccount)")
        #expect(calls.last == "delete \(BackupKey.rollbackAccount)")
    }

    @Test func anInterruptedKeyChangeKeepsLoadingAndCanRecoverTheCommittedKey() throws {
        let previous = BackupKey.StoredKeys(local: nil, synchronized: "INVNT-OLDKY-AAAAA")
        let journal = try #require(String(data: JSONEncoder().encode(previous), encoding: .utf8))
        var values = [BackupKey.rollbackAccount: journal, BackupKey.syncedAccount: "INVNT-NEWKY-BBBBB"]
        let keychain = BackupKey.Keychain(put: { key, account, _ in values[account] = key }, delete: { account, _ in
            values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
        }, read: { account, _ in
            values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
        })
        #expect(BackupKey.load(keychain: keychain) == "INVNT-OLDKY-AAAAA")
        try BackupKey.store("INVNT-NEXTK-CCCCC", inICloudKeychain: true, keychain: keychain)
        #expect(values[BackupKey.rollbackAccount] == nil)
        #expect(BackupKey.load(keychain: keychain) == "INVNT-NEXTK-CCCCC")
    }



    @Test func invalidFileOverridesNeverAccessTheKeychain() {
        var calls = 0
        let keychain = BackupKey.Keychain(put: { _, _, _ in calls += 1 },
                                         delete: { _, _ in calls += 1; return errSecSuccess },
                                         read: { _, _ in calls += 1; return (errSecSuccess, "invented") })
        for path in ["", "./backup-key", "relative", "/invalid\0path"] {
            let environment = ["SPRAVA_BACKUP_KEY_FILE": path]
            #expect(throws: BackupKey.Failure.self) { try BackupKey.recoveryKeys(environment: environment, keychain: keychain) }
            #expect(BackupKey.load(environment: environment, keychain: keychain) == nil)
            #expect(BackupKey.loadPending(environment: environment, keychain: keychain) == nil)
            BackupKey.clearPending(environment: environment, keychain: keychain)
            #expect(throws: BackupKey.Failure.self) {
                try BackupKey.store("INVNT-KEYAA", inICloudKeychain: false, environment: environment, keychain: keychain)
            }
            #expect(throws: BackupKey.Failure.self) {
                try BackupKey.storePending("INVNT-KEYAA", environment: environment, keychain: keychain)
            }
        }
        #expect(calls == 0)
    }

    @Test func pendingFileOverrideCreatesItsParentAndKeepsTheCommittedKey() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-key-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fresh/key")
        let environment = ["SPRAVA_BACKUP_KEY_FILE": file.path]
        let fake = FakeKeychain()
        try BackupKey.storePending("INVNT-PENDG", environment: environment, keychain: fake.keychain)
        #expect(BackupKey.loadPending(environment: environment, keychain: fake.keychain) == "INVNT-PENDG")
        #expect(BackupKey.load(environment: environment, keychain: fake.keychain) == nil)
        try BackupKey.store("INVNT-COMMT", inICloudKeychain: false, environment: environment, keychain: fake.keychain)
        BackupKey.clearPending(environment: environment, keychain: fake.keychain)
        #expect(BackupKey.loadPending(environment: environment, keychain: fake.keychain) == nil)
        #expect(BackupKey.load(environment: environment, keychain: fake.keychain) == "INVNT-COMMT")
        #expect(fake.calls.isEmpty && fake.values.isEmpty)
    }

    @Test func itemQueriesEnforceTheChosenKeychainAndAccessibility() throws {
        for (account, synchronized) in [(BackupKey.account, false), (BackupKey.pendingAccount, false),
                                         (BackupKey.rollbackAccount, false), (BackupKey.syncedAccount, true)] {
            let expected = BackupKey.query(account: account, synchronizable: synchronized)
            #expect(expected[kSecUseDataProtectionKeychain as String] as? Bool == true)
            #expect(expected[kSecAttrSynchronizable as String] as? Bool == synchronized)
            #expect(expected[kSecAttrAccount as String] as? String == account)
            let items = BackupKey.Items(update: { query, attributes in
                #expect(NSDictionary(dictionary: expected).isEqual(query as NSDictionary))
                let values = attributes as NSDictionary
                #expect(values[kSecAttrAccessible] as? String == (synchronized
                    ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly) as String)
                return errSecSuccess
            }, add: { _ in Issue.record("an existing item should be updated"); return errSecSuccess })
            try BackupKey.put("INVNT-KEYAA", account: account, synchronizable: synchronized, items: items)
        }
    }
}

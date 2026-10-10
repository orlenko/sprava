@testable import Backup
import Foundation
import Security
import Testing

/// An in-memory synchronized replica, never the person's Keychain.
@Suite struct BackupKeyRecoveryTests {
    final class Replica {
        var values: [String: String]
        var afterPut: ((String, String) throws -> Void)?
        var refuseDelete: ((String) -> OSStatus?)?
        var listStatus: OSStatus = errSecSuccess
        var writes = 0
        init(_ values: [String: String] = [:]) { self.values = values }
        var cloud: [String: String] {
            values.filter { $0.key == BackupKey.syncedAccount || $0.key.hasPrefix(BackupKey.recoveryPrefix) }
        }
        var keychain: BackupKey.Keychain {
            var keychain = BackupKey.Keychain(put: { key, account, _ in
                self.writes += 1
                self.values[account] = key
                try self.afterPut?(account, key)
            }, delete: { account, _ in
                if let refused = self.refuseDelete?(account) { return refused }
                self.writes += 1
                return self.values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
            }, read: { account, _ in
                self.values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            })
            keychain.accounts = { (self.listStatus, self.cloud.keys.filter { $0.hasPrefix(BackupKey.recoveryPrefix) }) }
            return keychain
        }
    }

    @Test func replacementsKeepEarlierOptedInKeysOnANewMac() throws {
        let old = "INVNT-OLDKY", new = "INVNT-NEWKY", latest = "INVNT-LATER"
        let device = Replica([BackupKey.account: old, BackupKey.syncedAccount: old])
        try BackupKey.store(new, inICloudKeychain: true, keychain: device.keychain)
        try BackupKey.store(latest, inICloudKeychain: true, keychain: device.keychain)
        #expect(device.values[BackupKey.account] == latest)
        #expect(device.values[BackupKey.syncedAccount] == old)
        let recovered = Replica(device.cloud)
        #expect(Set(try BackupKey.recoveryKeys(environment: [:], keychain: recovered.keychain)) == Set([old, new, latest]))
        #expect(recovered.values[BackupKey.account] == nil)
    }

    @Test func anInterruptedReplacementNeverOverwritesTheOnlyExistingCloudKey() throws {
        let old = "INVNT-OLDKY", new = "INVNT-NEWKY"
        let device = Replica([BackupKey.account: old, BackupKey.syncedAccount: old])
        var interrupted: [String: String]?
        device.afterPut = { account, _ in
            if account == BackupKey.recoveryAccount(new) {
                interrupted = device.cloud
                throw BackupKey.Failure(message: "invented interruption after cloud write")
            }
        }
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store(new, inICloudKeychain: true, keychain: device.keychain) }
        let recovered = Replica(try #require(interrupted))
        #expect(recovered.values[BackupKey.syncedAccount] == old)
        #expect(Set(try BackupKey.recoveryKeys(environment: [:], keychain: recovered.keychain)) == Set([old, new]))
        #expect(BackupKey.load(keychain: device.keychain) == old)
        #expect(device.cloud[BackupKey.syncedAccount] == old)
    }

    @Test func rollbackNeverDeletesARecoveryKeyThatArrivedFromAnotherMac() throws {
        let old = "INVNT-OLDKY", new = "INVNT-NEWKY", foreign = "INVNT-OTHER"
        let device = Replica([BackupKey.account: old, BackupKey.syncedAccount: old])
        device.afterPut = { account, value in
            if account == BackupKey.account, value == new {
                device.values[BackupKey.recoveryAccount(foreign)] = foreign
                throw BackupKey.Failure(message: "invented local commit failure")
            }
        }
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store(new, inICloudKeychain: true, keychain: device.keychain) }
        #expect(device.values[BackupKey.account] == old)
        #expect(device.values[BackupKey.syncedAccount] == old)
        #expect(device.values[BackupKey.recoveryAccount(foreign)] == foreign)
        #expect(device.values[BackupKey.rollbackAccount] == nil)
    }

    @Test func rollbackNeverRepublishesKeysAnotherMacRemoved() throws {
        let old = "INVNT-OLDKY", new = "INVNT-NEWKY"
        let oldArchive = BackupKey.recoveryAccount(old)
        let device = Replica([BackupKey.account: old, BackupKey.syncedAccount: old, oldArchive: old])
        device.afterPut = { account, value in
            if account == BackupKey.account, value == new {
                for name in Array(device.cloud.keys) { device.values.removeValue(forKey: name) }
                throw BackupKey.Failure(message: "invented failure after another Mac opted out")
            }
        }
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store(new, inICloudKeychain: true, keychain: device.keychain) }
        #expect(device.values[BackupKey.account] == old)
        #expect(device.cloud.isEmpty)
        #expect(device.values[BackupKey.rollbackAccount] == nil)
    }

    @Test func interruptedOptOutStillOffersEveryCommittedRecoveryKey() throws {
        let old = "INVNT-FIRST", current = "INVNT-SECOND"
        let previous = BackupKey.StoredKeys(local: current, synchronized: old,
                                            recovery: [BackupKey.recoveryAccount(old): old,
                                                       BackupKey.recoveryAccount(current): current])
        let journal = String(decoding: try JSONEncoder().encode(previous), as: UTF8.self)
        let device = Replica([BackupKey.account: current, BackupKey.rollbackAccount: journal])
        #expect(Set(try BackupKey.recoveryKeys(environment: [:], keychain: device.keychain)) == Set([old, current]))
    }

    @Test func unreadableCurrentLocalKeyNeverFallsBackToAnOlderCloudKey() {
        var keychain = Replica().keychain
        keychain.read = { account, _ in
            if account == BackupKey.rollbackAccount { return (errSecItemNotFound, nil) }
            if account == BackupKey.account { return (errSecInteractionNotAllowed, nil) }
            if account == BackupKey.syncedAccount { return (errSecSuccess, "INVNT-OLDER") }
            return (errSecItemNotFound, nil)
        }
        #expect(BackupKey.load(keychain: keychain) == nil)
    }

    @Test func optingOutRemovesAllKnownRecoveryCopies() throws {
        let device = Replica()
        try BackupKey.store("INVNT-FIRST", inICloudKeychain: true, keychain: device.keychain)
        try BackupKey.store("INVNT-SECOND", inICloudKeychain: true, keychain: device.keychain)
        try BackupKey.store("INVNT-SECOND", inICloudKeychain: false, keychain: device.keychain)
        #expect(device.cloud.isEmpty)
        #expect(BackupKey.load(keychain: device.keychain) == "INVNT-SECOND")
    }

    @Test func aFailedOptOutDoesNotRepublishCopiesAlreadyRemoved() throws {
        let old = "INVNT-FIRST", current = "INVNT-SECOND"
        let device = Replica()
        try BackupKey.store(old, inICloudKeychain: true, keychain: device.keychain)
        try BackupKey.store(current, inICloudKeychain: true, keychain: device.keychain)
        let ordered = device.cloud.keys.sorted()
        device.refuseDelete = { $0 == ordered.last ? errSecInteractionNotAllowed : nil }
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store(current, inICloudKeychain: false, keychain: device.keychain) }
        #expect(BackupKey.load(keychain: device.keychain) == current)
        #expect(device.values[try #require(ordered.first)] == nil)
        #expect(device.values[try #require(ordered.last)] != nil)
    }

    @Test func failedJournalCleanupCannotLoseANewMacsOnlyKey() throws {
        let key = "INVNT-RECOV"
        let archive = BackupKey.recoveryAccount(key)
        let device = Replica([archive: key])
        var refused = false
        device.refuseDelete = { account in
            if account == BackupKey.rollbackAccount, !refused {
                refused = true
                return errSecInteractionNotAllowed
            }
            return nil
        }
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store(key, inICloudKeychain: false, keychain: device.keychain) }
        #expect(device.cloud.isEmpty)
        #expect(device.values[BackupKey.account] == key)
        #expect(device.values[BackupKey.rollbackAccount] != nil)
        #expect(BackupKey.load(keychain: device.keychain) == key)
        #expect(Set(try BackupKey.recoveryKeys(environment: [:], keychain: device.keychain)) == [key])
    }

    @Test func unreadableAndDamagedRecoveryRecordsStopBeforeMutation() throws {
        for damaged in [false, true] {
            let old = "INVNT-FIRST"
            let device = Replica([BackupKey.account: old, BackupKey.syncedAccount: old])
            if damaged { device.values[BackupKey.recoveryAccount(old)] = "INVNT-UNRELATED" }
            else { device.listStatus = errSecInteractionNotAllowed }
            let before = device.values
            #expect(throws: BackupKey.Failure.self) { try BackupKey.store("INVNT-NEWKY", inICloudKeychain: true, keychain: device.keychain) }
            #expect(throws: BackupKey.Failure.self) { try BackupKey.recoveryKeys(environment: [:], keychain: device.keychain) }
            #expect(device.values == before && device.writes == 0)
        }
    }

    @Test func anAddRaceRetriesUpdatingTheSameItem() throws {
        var calls = 0
        let items = BackupKey.Items(update: { _, _ in
            calls += 1
            return calls == 1 ? errSecItemNotFound : errSecSuccess
        }, add: { _ in errSecDuplicateItem })
        try BackupKey.put("INVNT-KEYAA", account: BackupKey.recoveryAccount("INVNT-KEYAA"), synchronizable: true, items: items)
        #expect(calls == 2)
    }
}

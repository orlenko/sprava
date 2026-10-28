@testable import Backup
import Foundation
import LocalAuthentication
import Security
import SpravaKit
import Testing

/// Where the runtime keeps the backup key when it is ad-hoc signed (decisions.md A20): the login Keychain for local
/// items, only after the data-protection Keychain refuses for the missing entitlement; never iCloud Keychain. Every
/// call goes to an in-memory stand-in and the lock to a temporary folder: no test touches a real Keychain item.
@Suite struct BackupKeyLocalStorageTests {
    /// Both Keychains in memory. The data-protection one refuses everything without the entitlement; the login one can
    /// be locked to unattended access (as for a rebuilt runtime or a locked Keychain) or refuse writes.
    final class StandIn: @unchecked Sendable {
        var entitled: Bool
        var protected: [String: Data] = [:]
        var login: [String: Data] = [:]
        var loginNeedsInteraction = false
        var loginWriteStatus: OSStatus?
        var loginQueries: [[String: Any]] = []
        var protectedAdds: [[String: Any]] = []

        init(entitled: Bool) { self.entitled = entitled }

        static func key(_ q: [String: Any]) -> String {
            "\(q[kSecAttrAccount as String] as? String ?? "")|\(q[kSecAttrSynchronizable as String] as? Bool ?? false)"
        }

        /// The store a query reaches, or the status that refuses it.
        func store(_ q: [String: Any], writing: Bool) -> (OSStatus, ReferenceWritableKeyPath<StandIn, [String: Data]>?) {
            if q[kSecUseDataProtectionKeychain as String] as? Bool == true {
                return entitled ? (errSecSuccess, \.protected) : (errSecMissingEntitlement, nil)
            }
            loginQueries.append(q)
            let context = q[kSecUseAuthenticationContext as String] as? LAContext
            if loginNeedsInteraction, context?.interactionNotAllowed != false { return (errSecInteractionNotAllowed, nil) }
            if writing, let refused = loginWriteStatus { return (refused, nil) }
            return (errSecSuccess, \.login)
        }

        var calls: BackupKey.Calls {
            BackupKey.Calls(copy: { [self] q in
                let (status, path) = store(q, writing: false)
                guard let path else { return (status, nil) }
                guard let data = self[keyPath: path][Self.key(q)] else { return (errSecItemNotFound, nil) }
                return (errSecSuccess, data)
            }, update: { [self] q, changes in
                let (status, path) = store(q, writing: true)
                guard let path else { return status }
                guard self[keyPath: path][Self.key(q)] != nil else { return errSecItemNotFound }
                self[keyPath: path][Self.key(q)] = changes[kSecValueData as String] as? Data
                return errSecSuccess
            }, add: { [self] q in
                let (status, path) = store(q, writing: true)
                guard let path else { return status }
                if path == \StandIn.protected { protectedAdds.append(q) }
                guard self[keyPath: path][Self.key(q)] == nil else { return errSecDuplicateItem }
                self[keyPath: path][Self.key(q)] = q[kSecValueData as String] as? Data
                return errSecSuccess
            }, delete: { [self] q in
                let (status, path) = store(q, writing: true)
                guard let path else { return status }
                return self[keyPath: path].removeValue(forKey: Self.key(q)) == nil ? errSecItemNotFound : errSecSuccess
            }, list: { [self] q in
                let (status, path) = store(q, writing: false)
                guard let path else { return (status, nil) }
                let names = self[keyPath: path].keys.filter { $0.hasSuffix("|true") }.map { $0.components(separatedBy: "|")[0] }
                return names.isEmpty ? (errSecItemNotFound, nil) : (errSecSuccess, names.map { [kSecAttrAccount as String: $0] })
            })
        }

        /// The runtime's Keychain over this stand-in, as a fresh process would make it, locking a temporary file.
        func keychain(interactive: Bool = false, lock: URL) -> BackupKey.Keychain {
            var keychain = BackupKey.Keychain.system(calls: calls, interactive: interactive)
            keychain.lockURL = lock
            return keychain
        }
    }

    let lock = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-key-\(UUID().uuidString)/keychain.lock")

    @Test func anAdHocRuntimeKeepsItsLocalKeyInTheLoginKeychainAcrossARestart() throws {
        let keychain = StandIn(entitled: false)
        try BackupKey.storePending("INVNT-PENDING", environment: [:], keychain: keychain.keychain(interactive: true, lock: lock))
        // A restart: a new process, a new Keychain value, the same items.
        #expect(BackupKey.loadPending(environment: [:], keychain: keychain.keychain(lock: lock)) == "INVNT-PENDING")
        try keychain.keychain(interactive: true, lock: lock).put("INVNT-LOCAL", BackupKey.account, false)
        #expect(BackupKey.load(keychain: keychain.keychain(lock: lock)) == "INVNT-LOCAL")
        #expect(keychain.protected.isEmpty)
        // Never synchronized, and with no ThisDeviceOnly attribute, which the login Keychain does not enforce.
        for q in keychain.loginQueries {
            #expect(q[kSecAttrSynchronizable as String] as? Bool == false)
            #expect(q[kSecAttrAccessible as String] == nil)
            #expect(q[kSecAttrAccessGroup as String] == nil)
        }
        try BackupKey.clearPending(environment: [:], keychain: keychain.keychain(interactive: true, lock: lock))
        #expect(BackupKey.loadPending(environment: [:], keychain: keychain.keychain(lock: lock)) == nil)
    }

    @Test func aProvisionedRuntimeStaysInTheDataProtectionKeychainThisDeviceOnly() throws {
        let keychain = StandIn(entitled: true)
        try keychain.keychain(interactive: true, lock: lock).put("INVNT-LOCAL", BackupKey.account, false)
        #expect(BackupKey.load(keychain: keychain.keychain(lock: lock)) == "INVNT-LOCAL")
        #expect(keychain.login.isEmpty && keychain.loginQueries.isEmpty)
        let added = try #require(keychain.protectedAdds.first)
        #expect(added[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    /// Unattended reads never ask: a login Keychain that would need the person's authorization (a locked Keychain, or a
    /// rebuilt runtime it does not trust yet) gives no key, and nothing else is used in its place.
    @Test func unattendedReadsNeverAskAndFindNoKeyWhereAuthorizationIsNeeded() throws {
        let keychain = StandIn(entitled: false)
        try keychain.keychain(interactive: true, lock: lock).put("INVNT-LOCAL", BackupKey.account, false)
        keychain.loginNeedsInteraction = true
        keychain.loginQueries = []
        #expect(BackupKey.load(keychain: keychain.keychain(lock: lock)) == nil)
        #expect(BackupKey.loadPending(environment: [:], keychain: keychain.keychain(lock: lock)) == nil)
        #expect(!keychain.loginQueries.isEmpty)
        #expect(keychain.loginQueries.allSatisfy { ($0[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true })
        // The person's own save may let macOS ask, and then the key is readable again.
        try keychain.keychain(interactive: true, lock: lock).put("INVNT-LOCAL", BackupKey.account, false)
        keychain.loginNeedsInteraction = false
        #expect(BackupKey.load(keychain: keychain.keychain(lock: lock)) == "INVNT-LOCAL")
    }

    @Test func aWriteTheLoginKeychainRefusesFailsAndKeepsNothingInMemory() throws {
        let keychain = StandIn(entitled: false)
        keychain.loginWriteStatus = errSecNotAvailable
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.storePending("INVNT-PENDING", environment: [:], keychain: keychain.keychain(interactive: true, lock: lock))
        }
        keychain.loginWriteStatus = nil
        #expect(BackupKey.loadPending(environment: [:], keychain: keychain.keychain(lock: lock)) == nil)
        #expect(keychain.login.isEmpty)
    }

    /// The runtime's real calls go through the login Keychain's dialog switch: an unattended read runs with it off.
    @Test func theRuntimesLoginCallsRunWithTheDialogSwitchFromTheirContext() throws {
        final class Switch: @unchecked Sendable { var on = true }
        let state = Switch()
        let interaction = LegacyKeychainInteraction.Switch(get: { state.on }, set: { state.on = $0 })
        let keychain = StandIn(entitled: false)
        var seen: [Bool] = []
        var base = keychain.calls
        let copy = base.copy
        base.copy = { q in
            if q[kSecUseDataProtectionKeychain as String] as? Bool == false { seen.append(state.on) }
            return copy(q)
        }
        let calls = base.guarded(by: interaction)
        _ = BackupKey.read(BackupKey.account, synchronizable: false, interactive: false, calls: calls)
        _ = BackupKey.read(BackupKey.account, synchronizable: false, interactive: true, calls: calls)
        #expect(seen == [false, true])
        #expect(state.on)
    }

    /// Only the missing entitlement selects the login Keychain: any other refusal of a provisioned runtime fails.
    @Test func anotherDataProtectionRefusalNeverFallsBackToTheLoginKeychain() {
        let keychain = StandIn(entitled: true)
        var calls = keychain.calls
        calls.add = { _ in errSecInteractionNotAllowed }
        calls.update = { _, _ in errSecItemNotFound }
        #expect(throws: BackupKey.Failure.self) {
            try BackupKey.write("INVNT-LOCAL", account: BackupKey.account, synchronizable: false, interactive: true, calls: calls)
        }
        #expect(keychain.loginQueries.isEmpty)
    }

    @Test func iCloudKeychainIsReportedUnavailableOnlyWithoutTheEntitlement() {
        #expect(!BackupKey.iCloudKeychainAvailable(keychain: StandIn(entitled: false).keychain(lock: lock)))
        #expect(BackupKey.iCloudKeychainAvailable(keychain: StandIn(entitled: true).keychain(lock: lock)))
    }

    /// iCloud Keychain is out of an ad-hoc runtime's reach. Opting in is refused before anything changes.
    @Test func optingIntoICloudKeychainIsRefusedOnAnAdHocRuntimeWithNothingChanged() throws {
        let keychain = StandIn(entitled: false)
        try keychain.keychain(interactive: true, lock: lock).put("INVNT-EARLIER", BackupKey.account, false)
        let before = keychain.login
        let refusal = #expect(throws: BackupKey.Failure.self) {
            try BackupKey.store("INVNT-NEWKEY", inICloudKeychain: true, keychain: keychain.keychain(interactive: true, lock: lock))
        }
        #expect(refusal?.message == "iCloud Keychain is unavailable in this development build; the backup key can be kept on this Mac only. Nothing was changed.")
        #expect(keychain.login == before && keychain.protected.isEmpty)
        #expect(BackupKey.load(keychain: keychain.keychain(lock: lock)) == "INVNT-EARLIER")
    }

    /// Opting out keeps the new key on this Mac, keeps the replaced one in this Mac's history (it may open older
    /// snapshots), and says the cloud was not checked: nothing there is listed, read as empty or removed.
    @Test func optingOutOnAnAdHocRuntimeKeepsTheKeyLocallyAndReportsTheCloudUnchecked() throws {
        let keychain = StandIn(entitled: false)
        var cloudCalls = 0
        var calls = keychain.calls
        let list = calls.list, delete = calls.delete
        calls.list = { cloudCalls += 1; return list($0) }
        calls.delete = { q in if q[kSecAttrSynchronizable as String] as? Bool == true { cloudCalls += 1 }; return delete(q) }
        func runtime(_ interactive: Bool) -> BackupKey.Keychain {
            var k = BackupKey.Keychain.system(calls: calls, interactive: interactive)
            k.lockURL = lock
            return k
        }
        try runtime(true).put("INVNT-EARLIER", BackupKey.account, false)
        let stored = try BackupKey.store("INVNT-NEWKEY", inICloudKeychain: false, keychain: runtime(true))
        #expect(stored == BackupKey.Stored(cloudChecked: false))
        #expect(cloudCalls == 0)
        // A restart reads the new key; the replaced one stays on this Mac; no journal is left behind.
        #expect(BackupKey.load(keychain: runtime(false)) == "INVNT-NEWKEY")
        #expect(try BackupKey.localHistory(runtime(false)) == ["INVNT-EARLIER"])
        #expect(runtime(false).read(BackupKey.rollbackAccount, false).0 == errSecItemNotFound)
        #expect(keychain.protected.isEmpty)
    }

    /// A store that fails before the new key is committed puts the earlier key back.
    @Test func aFailedStoreOnAnAdHocRuntimeRollsBackToTheEarlierKey() throws {
        let keychain = StandIn(entitled: false)
        try keychain.keychain(interactive: true, lock: lock).put("INVNT-EARLIER", BackupKey.account, false)
        var calls = keychain.calls
        let update = calls.update
        var failing = true
        calls.update = { q, changes in
            if failing, q[kSecAttrAccount as String] as? String == BackupKey.account,
               changes[kSecValueData as String] as? Data == Data("INVNT-NEWKEY".utf8) { failing = false; return errSecNotAvailable }
            return update(q, changes)
        }
        var runtime = BackupKey.Keychain.system(calls: calls, interactive: true)
        runtime.lockURL = lock
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store("INVNT-NEWKEY", inICloudKeychain: false, keychain: runtime) }
        #expect(BackupKey.load(keychain: keychain.keychain(lock: lock)) == "INVNT-EARLIER")
        #expect(keychain.keychain(lock: lock).read(BackupKey.rollbackAccount, false).0 == errSecItemNotFound)
    }
}

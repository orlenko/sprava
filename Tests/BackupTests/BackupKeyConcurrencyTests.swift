@testable import Backup
import Darwin
import Dispatch
import Foundation
import Security
import Testing

@Suite struct BackupKeyConcurrencyTests {
    final class Memory: @unchecked Sendable {
        let lock = NSLock()
        var values = [BackupKey.account: "INVNT-OLDKY", BackupKey.syncedAccount: "INVNT-OLDKY"]
        let firstCloudWritten = DispatchSemaphore(value: 0)
        let resumeFirst = DispatchSemaphore(value: 0)
        var secondAccessed = false
        var errors: [String] = []
        var loaded: String?

        var keychain: BackupKey.Keychain {
            var keychain = BackupKey.Keychain(put: { key, account, _ in
                self.lock.lock()
                self.values[account] = key
                if key == "INVNT-SECOND" { self.secondAccessed = true }
                self.lock.unlock()
                if key == "INVNT-FIRST", account == BackupKey.recoveryAccount("INVNT-FIRST") {
                    self.firstCloudWritten.signal()
                    #expect(self.resumeFirst.wait(timeout: .now() + 3) == .success)
                }
            }, delete: { account, _ in
                self.lock.lock(); defer { self.lock.unlock() }
                return self.values.removeValue(forKey: account) == nil ? errSecItemNotFound : errSecSuccess
            }, read: { account, _ in
                self.lock.lock(); defer { self.lock.unlock() }
                return self.values[account].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
            })
            keychain.accounts = {
                self.lock.lock(); defer { self.lock.unlock() }
                return (errSecSuccess, self.values.keys.filter { $0.hasPrefix(BackupKey.recoveryPrefix) })
            }
            return keychain
        }

        func record(_ body: () throws -> Void) {
            do { try body() } catch {
                lock.lock(); defer { lock.unlock() }
                errors.append(String(describing: error))
            }
        }
    }

    @Test func aSecondWriterAndReaderWaitForTheActiveTransaction() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-key-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let memory = Memory()
        var configured = memory.keychain
        configured.lockURL = root.appendingPathComponent("keychain.lock")
        // The closures only touch Memory's locked state; Keychain itself contains immutable configuration here.
        let keychain = SharedKeychain(value: configured)
        let finished = DispatchGroup()
        let secondStarted = DispatchSemaphore(value: 0)
        let readerStarted = DispatchSemaphore(value: 0)
        let readerFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async(group: finished) {
            memory.record { try BackupKey.store("INVNT-FIRST", inICloudKeychain: true, keychain: keychain.value) }
        }
        #expect(memory.firstCloudWritten.wait(timeout: .now() + 3) == .success)
        DispatchQueue.global().async(group: finished) {
            secondStarted.signal()
            memory.record { try BackupKey.store("INVNT-SECOND", inICloudKeychain: true, keychain: keychain.value) }
        }
        #expect(secondStarted.wait(timeout: .now() + 3) == .success)
        DispatchQueue.global().async(group: finished) {
            readerStarted.signal()
            let loaded = BackupKey.load(keychain: keychain.value)
            memory.lock.lock()
            memory.loaded = loaded
            memory.lock.unlock()
            readerFinished.signal()
        }
        #expect(readerStarted.wait(timeout: .now() + 3) == .success)
        #expect(readerFinished.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(throws: BackupKey.Failure.self) { try keychain.value.withLock(timeout: 0.05) {} }
        memory.lock.lock()
        #expect(!memory.secondAccessed)
        memory.lock.unlock()
        memory.resumeFirst.signal()
        #expect(finished.wait(timeout: .now() + 3) == .success)
        #expect(memory.errors.isEmpty)
        #expect(memory.values[BackupKey.account] == "INVNT-SECOND")
        #expect(memory.values[BackupKey.syncedAccount] == "INVNT-OLDKY")
        #expect(memory.values[BackupKey.recoveryAccount("INVNT-FIRST")] == "INVNT-FIRST")
        #expect(memory.values[BackupKey.recoveryAccount("INVNT-SECOND")] == "INVNT-SECOND")
        #expect(memory.values[BackupKey.rollbackAccount] == nil)
        #expect(memory.loaded == "INVNT-FIRST" || memory.loaded == "INVNT-SECOND")
        #expect(BackupKey.load(keychain: keychain.value) == "INVNT-SECOND")
    }

    struct SharedKeychain: @unchecked Sendable { let value: BackupKey.Keychain }

    @Test func productionCallersLockTheCanonicalKeychainNamespace() throws {
        let canonical = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sprava/backup/keychain.lock")
        #expect(BackupKey.Keychain.system.lockURL == canonical)
        let overriddenSupport = try #require(ProcessInfo.processInfo.environment["SPRAVA_SUPPORT_DIR"])
        #expect(BackupKey.Keychain.system.lockURL.path != overriddenSupport + "/backup/keychain.lock")
    }

    @Test func aLinkedLockStopsBeforeTheKeychainIsAccessed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-key-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var accessed = false
        var keychain = BackupKey.Keychain(put: { _, _, _ in accessed = true },
                                          delete: { _, _ in accessed = true; return errSecSuccess },
                                          read: { _, _ in accessed = true; return (errSecSuccess, "invented") })
        keychain.lockURL = root.appendingPathComponent("keychain.lock")
        try FileManager.default.createSymbolicLink(at: keychain.lockURL, withDestinationURL: root.appendingPathComponent("missing"))
        #expect(throws: BackupKey.Failure.self) { try BackupKey.store("INVNT-KEYAA", inICloudKeychain: false, keychain: keychain) }
        #expect(BackupKey.load(keychain: keychain) == nil)
        #expect(!accessed)
    }
}

@testable import Backup
import Foundation
import Testing

/// The record that iCloud Keychain went unchecked outlives the process, and a key typed again for a configured mirror
/// is checked against the repository before anything changes. Temporary folders and invented keys only.
@Suite(.serialized) struct BackupKeyReentryTests {
    static let hasRestic = Restic.locate() != nil

    func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-reentry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func theUncheckedICloudKeychainMarkSurvivesAReopenUntilACheckClearsIt() throws {
        let support = try folder()
        try Backup(support: support, key: nil, resticBinary: nil).recordICloudKeychainChecked(false)
        // A new process reads the same settings.
        #expect(try Backup(support: support, key: nil, resticBinary: nil).settings().iCloudKeychainUnchecked == true)
        try Backup(support: support, key: nil, resticBinary: nil).recordICloudKeychainChecked(true)
        #expect(try Backup(support: support, key: nil, resticBinary: nil).settings().iCloudKeychainUnchecked == nil)
    }

    /// A wrong key typed again for the same mirror changes neither the settings nor the state; the right one is taken.
    @Test(.enabled(if: hasRestic)) func aKeyTypedAgainMustOpenTheExistingRepositoryBeforeAnythingChanges() throws {
        let support = try folder(), mirror = try folder().appendingPathComponent("Sprava Backup", isDirectory: true)
        let right = "INVNT-RIGHT-AAAAA-BBBBB", wrong = "INVNT-WRONG-AAAAA-BBBBB"
        try Backup(support: support, key: right, uploadCheck: { _ in .uploaded }).setUp(primary: mirror, iCloudKeychain: false)
        try Backup(support: support, key: nil, resticBinary: nil).recordICloudKeychainChecked(false)
        let settings = try Backup(support: support, key: nil, resticBinary: nil).settings()
        #expect(throws: (any Error).self) {
            try Backup(support: support, key: wrong, uploadCheck: { _ in .uploaded }).setUp(primary: mirror, iCloudKeychain: false)
        }
        #expect(try Backup(support: support, key: nil, resticBinary: nil).settings() == settings)
        try Backup(support: support, key: right, uploadCheck: { _ in .uploaded }).setUp(primary: mirror, iCloudKeychain: false)
        #expect(try Backup(support: support, key: nil, resticBinary: nil).settings().primary == mirror.standardizedFileURL.path)
    }
}

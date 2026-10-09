@testable import Backup
import Darwin
import Foundation
import SpravaKit
import Testing

/// Regressions from the fifth adversarial review of increment 1 (key files named by an inline MIME part, numbers in
/// untrusted text that overflowed, withdrawals a failing binder check held back, unreadable backup settings).
/// Invented data only.
@Suite(.serialized) struct AstraReview5Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func temp(_ name: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-astra5-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 4. Backup settings that cannot be read are never "not set up"

    func brokenSettings(_ content: String = "{ not json") throws -> (Backup, URL, Data) {
        let support = temp("support")
        let b = Backup(support: support, key: "TEST-KEY-AAAAA-BBBBB", resticBinary: URL(fileURLWithPath: "/usr/bin/true"),
                       uploadCheck: { _ in .notInICloud })
        try AtomicFile.makePrivateFolder(b.dir)
        let data = Data(content.utf8)
        try data.write(to: b.settingsURL)
        return (b, b.settingsURL, data)
    }

    @Test func missingSettingsAreNotSetUp() throws {
        let b = Backup(support: temp("support"), key: "TEST-KEY-AAAAA-BBBBB", uploadCheck: { _ in .notInICloud })
        #expect(try b.settings() == Backup.Settings())
        #expect(try !b.isConfigured)
        #expect(b.status(checkUpload: false).settingsError == nil)
        #expect(b.maintain(rows: [], deviceID: "dev", now: now) == Backup.Maintenance())
    }

    @Test func olderSettingsWithoutLaterFieldsStillRead() throws {
        let (b, _, _) = try brokenSettings(#"{"primary": "/invented/mirror", "second": "/invented/second"}"#)
        let s = try b.settings()
        #expect(s.primary == "/invented/mirror" && s.second == "/invented/second" && s.keepLast == 30 && s.keepYearly == 10)
    }

    @Test func unreadableSettingsAreReportedAndNeverSavedOver() throws {
        for content in ["{ not json", #"{"primary": 7}"#] {
            let (b, url, data) = try brokenSettings(content)
            #expect(throws: Backup.Failure.self) { try b.settings() }
            #expect(throws: Backup.Failure.self) { try b.isConfigured }
            let st = b.status(checkUpload: false)
            #expect(!st.configured && st.settingsError?.contains("settings") == true)
            let m = b.maintain(rows: [], deviceID: "dev", now: now)
            #expect(m.failed == 1 && m.failedParts == ["backup_settings"])
            #expect(throws: Backup.Failure.self) { try b.setUp(primary: temp("mirror"), iCloudKeychain: false) }
            #expect(throws: Backup.Failure.self) { try b.setSecond(temp("second")) }
            #expect(try Data(contentsOf: url) == data)
        }
    }

    @Test func settingsThatCannotBeOpenedAreReported() throws {
        let (b, url, data) = try brokenSettings(#"{"primary": "/invented/mirror", "second": "/invented/second", "keepLast": 5}"#)
        chmod(url.path, 0o000)
        defer { chmod(url.path, 0o600) }
        #expect(throws: Backup.Failure.self) { try b.settings() }
        #expect(throws: Backup.Failure.self) { try b.setSecond(temp("second")) }
        chmod(url.path, 0o600)
        #expect(try Data(contentsOf: url) == data)
    }
}

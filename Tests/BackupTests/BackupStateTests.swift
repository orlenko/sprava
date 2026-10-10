@testable import Backup
import Foundation
import Testing

/// Invented state in temporary folders only; these tests never inspect a configured Sprava installation.
@Suite struct BackupStateTests {
    func temporary(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sprava-backup-state-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func backup(_ root: URL, secondLocation: @escaping @Sendable (URL) -> Bool = { _ in true }) -> Backup {
        Backup(support: root, key: "INVNT-STATE-KEYAA", resticBinary: nil,
               uploadCheck: { _ in .waiting(2) }, secondLocationCheck: secondLocation)
    }

    @Test func missingStateHasSafeDefaultsAndSavedStateRoundTrips() throws {
        let root = try temporary("roundtrip")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = backup(root)

        #expect(try subject.settings() == Backup.Settings())
        #expect(try !subject.isConfigured)
        #expect(try subject.state().binders.isEmpty)

        var settings = Backup.Settings()
        settings.primary = "/invented/mirror"
        settings.second = "/invented/second"
        settings.keepLast = 17
        try subject.save(settings)
        // Without a restic pin, nothing runs until setup checks restic again, so it is not set up.
        #expect(try !subject.isConfigured)
        #expect(!subject.status().configured)
        settings.resticSHA256 = String(repeating: "a", count: 64)
        try subject.save(settings)

        var state = Backup.State()
        var record = Backup.State.BinderRecord()
        record.path = "/invented/binder"
        record.at = "2026-01-02T03:04:05Z"
        record.bytes = 42
        state.binders["INVNT-BINDER"] = record
        state.lastCheck = "2026-01-03T04:05:06Z"
        try subject.save(state)

        #expect(try subject.settings() == settings)
        #expect(try subject.isConfigured)
        #expect(try subject.state().binders["INVNT-BINDER"]?.bytes == 42)
        let status = subject.status()
        #expect(status.configured && status.secondConfigured)
        #expect(status.binders.map(\.id) == ["INVNT-BINDER"])
        #expect(status.lastCheck == "2026-01-03T04:05:06Z")
        #expect(status.upload == .waiting(2))
        #expect(status.settingsError == nil && status.stateError == nil)
    }

    @Test func unreadableFilesFailClosedAndStatusReportsBothErrors() throws {
        let root = try temporary("damaged")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = backup(root)
        try FileManager.default.createDirectory(at: subject.dir, withIntermediateDirectories: true)
        let settings = Data("{not-json".utf8)
        let state = Data("[also-not-json".utf8)
        try settings.write(to: subject.settingsURL)
        try state.write(to: subject.stateURL)

        #expect(throws: Backup.Failure.self) { try subject.settings() }
        #expect(throws: Backup.Failure.self) { try subject.state() }
        let status = subject.status()
        #expect(!status.configured)
        #expect(status.settingsError != nil && status.stateError != nil)
        #expect(try Data(contentsOf: subject.settingsURL) == settings)
        #expect(try Data(contentsOf: subject.stateURL) == state)

        try FileManager.default.removeItem(at: subject.dir)
        try Data("invented obstruction".utf8).write(to: subject.dir)
        #expect(throws: Backup.Failure.self) { try subject.settings() }
        #expect(throws: Backup.Failure.self) { try subject.state() }
    }

    @Test func linksAreNeverReadAsSettingsOrState() throws {
        let root = try temporary("links")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = backup(root)
        try FileManager.default.createDirectory(at: subject.dir, withIntermediateDirectories: true)
        let external = root.appendingPathComponent("invented.json")
        try Data("{}".utf8).write(to: external)
        try FileManager.default.createSymbolicLink(at: subject.settingsURL, withDestinationURL: external)
        try FileManager.default.createSymbolicLink(at: subject.stateURL, withDestinationURL: external)
        #expect(throws: Backup.Failure.self) { try subject.settings() }
        #expect(throws: Backup.Failure.self) { try subject.state() }
    }

    @Test func olderStateGetsDefaultsAndPreservesEveryKnownRepository() throws {
        let root = try temporary("older")
        defer { try? FileManager.default.removeItem(at: root) }
        let subject = backup(root)
        try FileManager.default.createDirectory(at: subject.dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: subject.settingsURL)
        let older = #"""
        {
          "offloaded": [{"backupID":"INVNT-BINDER","originalPath":"/invented/binder","snapshot":"snap-a","repository":"/invented/first"}],
          "offloads": {"INVNT-BINDER":{"path":"/invented/binder","stage":"start","secondRepository":"/invented/second"}},
          "restored": {"INVNT-RESTORED":{"snapshot":"snap-b","repository":"/invented/old","manifest":{}}},
          "forgetting": [{"backupID":"INVNT-BINDER","path":"documents/invented.pdf","at":"2026-01-02T03:04:05Z","scopes":[{"repository":"/invented/archive","snapshots":[],"done":false}]}]
        }
        """#
        try Data(older.utf8).write(to: subject.stateURL)

        let settings = try subject.settings()
        #expect(settings.keepLast == 30 && settings.keepWithinDays == 90)
        #expect(!settings.iCloudKeychain)
        let state = try subject.state()
        #expect(state.binders["INVNT-BINDER"]?.repositories ==
                ["/invented/first", "/invented/second", "/invented/archive"])
        #expect(state.binders["INVNT-RESTORED"]?.repositories == ["/invented/old"])
        #expect(state.offloaded.first?.bytes == 0)
        #expect(state.offloaded.first?.name == "")
        #expect(state.offloads["INVNT-BINDER"]?.stateSaved == false)
        #expect(state.forgetting.first?.request == nil)
    }

    @Test func uploadStatusRequiresEveryUbiquitousFileToBeUploaded() {
        let local = Backup.UploadEntry(regular: true, ubiquitous: false, uploaded: false)
        let folder = Backup.UploadEntry(regular: false, ubiquitous: true, uploaded: false)
        let uploaded = Backup.UploadEntry(regular: true, ubiquitous: true, uploaded: true)
        let waiting = Backup.UploadEntry(regular: true, ubiquitous: true, uploaded: false)
        #expect(Backup.uploadStatus([]) == .notInICloud)
        #expect(Backup.uploadStatus([local, folder]) == .notInICloud)
        #expect(Backup.uploadStatus([folder, uploaded]) == .uploaded)
        #expect(Backup.uploadStatus([uploaded, waiting, nil]) == .waiting(2))
    }

    @Test func aSecondDestinationMustNotShareTheMirrorsFate() throws {
        let root = try temporary("destinations")
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("mirror", isDirectory: true)
        let second = root.appendingPathComponent("independent", isDirectory: true)
        let allowed = backup(root)
        try allowed.refuseSharedFate(second, primary: primary)
        #expect(throws: Backup.Failure.self) { try allowed.refuseSharedFate(primary, primary: primary) }
        #expect(throws: Backup.Failure.self) {
            try allowed.refuseSharedFate(primary.appendingPathComponent("nested"), primary: primary)
        }
        #expect(throws: Backup.Failure.self) {
            try allowed.refuseSharedFate(primary, primary: primary.appendingPathComponent("nested"))
        }
        let localOnly = backup(root, secondLocation: { _ in false })
        #expect(throws: Backup.Failure.self) { try localOnly.refuseSharedFate(second, primary: primary) }
    }

    @Test func onlyRegisteredCloudStorageRootsCountAsProviderDestinations() throws {
        let home = try temporary("provider-home")
        defer { try? FileManager.default.removeItem(at: home) }
        let provider = home.appendingPathComponent("Library/CloudStorage/InventedProvider", isDirectory: true)
        try FileManager.default.createDirectory(at: provider, withIntermediateDirectories: true)
        let destination = provider.appendingPathComponent("Sprava", isDirectory: true)
        #expect(Backup.isIndependentSecondLocation(destination, home: home, fileProviderCheck: { $0 == provider }))
        #expect(!Backup.isIndependentSecondLocation(destination, home: home, fileProviderCheck: { _ in false }))
    }

    @Test func aLinkInPlaceOfTheBackupFolderIsNeverFollowed() throws {
        let root = try temporary("linked-folder")
        defer { try? FileManager.default.removeItem(at: root) }
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let invented = Data(#"{"primary": "/invented/elsewhere"}"#.utf8)
        try invented.write(to: elsewhere.appendingPathComponent("settings.json"))
        let subject = backup(root)
        try FileManager.default.createSymbolicLink(at: subject.dir, withDestinationURL: elsewhere)
        #expect(throws: Backup.Failure.self) { _ = try subject.settings() }
        #expect(throws: Backup.Failure.self) { try subject.save(Backup.Settings()) }
        #expect(throws: Backup.Failure.self) { try subject.save(Backup.State()) }
        #expect(try Data(contentsOf: elsewhere.appendingPathComponent("settings.json")) == invented)
        #expect(!FileManager.default.fileExists(atPath: elsewhere.appendingPathComponent("state.json").path))
    }

    @Test func settingsWithoutAResticPinRunNothing() throws {
        let root = try temporary("unpinned")
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("restic")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        let subject = Backup(support: root, key: "INVNT-STATE-KEYAA", resticBinary: binary,
                             uploadCheck: { _ in .uploaded }, secondLocationCheck: { _ in true })
        var settings = Backup.Settings()
        settings.primary = root.appendingPathComponent("mirror").path
        try subject.save(settings)
        #expect(throws: Backup.Failure.self) { _ = try subject.engine(settings.primary) }
        settings.resticSHA256 = Restic.sha256(of: binary)
        try subject.save(settings)
        #expect(try subject.engine(settings.primary).expectedSHA256 == settings.resticSHA256)
    }
}

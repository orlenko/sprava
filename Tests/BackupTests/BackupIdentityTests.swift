@testable import Backup
import Darwin
import Foundation
import Testing

/// Backup ids (made once, kept in the binder, never shared by a copy) and manifests (everything restic saves, so a
/// metadata-only change counts). Binders live in temporary folders only; nothing here runs restic. Invented data only.
@Suite struct BackupIdentityTests {
    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-identity-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Backup ids

    @Test func aBinderThatIsGoneGetsNoBackupID() throws {
        let base = try temp("gone")
        let gone = base.appendingPathComponent("moved-away/Estate", isDirectory: true)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(gone) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("moved-away").path))
    }

    @Test func aBackupIDThatCannotBeReadIsNeverReplaced() throws {
        let folder = try temp("unreadable-id")
        let sprava = folder.appendingPathComponent(".sprava")
        let url = sprava.appendingPathComponent("backup-id")
        try FileManager.default.createDirectory(at: sprava, withIntermediateDirectories: true)

        // A FIFO is refused without waiting on it.
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        #expect(Backup.existingBackupID(folder) == nil)
        try FileManager.default.removeItem(at: url)

        // One that cannot be read, or holds something else, is left as it is.
        let id = "0123456789abcdef0123456789abcdef\n"
        try Data(id.utf8).write(to: url)
        chmod(url.path, 0o000)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        chmod(url.path, 0o600)
        #expect(try String(contentsOf: url, encoding: .utf8) == id)
        try Data("invented, not an id".utf8).write(to: url)
        #expect(throws: Backup.Failure.self) { _ = try Backup.backupID(folder) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "invented, not an id")

        // None at all: one is made, and kept.
        try FileManager.default.removeItem(at: url)
        let made = try Backup.backupID(folder)
        #expect(try Backup.backupID(folder) == made)
        #expect(Backup.existingBackupID(folder) == made)
    }

    @Test func anExistingBackupIDIsReadOnlyAndRefusesLinks() throws {
        let folder = try temp("existing-id")
        #expect(Backup.existingBackupID(folder) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava").path))
        let id = try Backup.backupID(folder)
        #expect(Backup.existingBackupID(folder) == id)

        // A backup-id that is a link to another binder's id is refused, and left as it is.
        let other = folder.appendingPathComponent("other-id")
        try Data("0123456789abcdef0123456789abcdef\n".utf8).write(to: other)
        let url = folder.appendingPathComponent(".sprava/backup-id")
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: other.path)
        #expect(Backup.existingBackupID(folder) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == other.path)

        // A .sprava folder that is a link is refused too.
        let elsewhere = folder.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try Data("0123456789abcdef0123456789abcdef\n".utf8).write(to: elsewhere.appendingPathComponent("backup-id"))
        try FileManager.default.removeItem(at: folder.appendingPathComponent(".sprava"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent(".sprava").path, withDestinationPath: elsewhere.path)
        #expect(Backup.existingBackupID(folder) == nil)
    }

    @Test func aCopyCannotClaimItsOriginalsIDUntilItHasItsOwn() throws {
        let base = try temp("copy")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let id = try Backup.backupID(original)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        #expect(try b.claim(original, &st) == id)
        try b.save(st)
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.claim(copy, &st) }
        #expect(st.binders[id]?.path == original.standardizedFileURL.path)

        // The original keeps its id; the copy gets its own, recorded before it is written.
        #expect(throws: Backup.Failure.self) { try b.giveOwnBackupID(original) }
        let own = try b.giveOwnBackupID(copy)
        #expect(own != id && Backup.existingBackupID(copy) == own)
        #expect(try b.state().binders[own]?.path == copy.standardizedFileURL.path)
        #expect(try b.claim(copy, &st) == own)
    }

    @Test func aCopyCannotClaimAnIDWhoseRecordedVolumeIsUnavailable() throws {
        let base = try temp("unavailable-owner")
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        let id = "0123456789abcdef0123456789abcdef"
        try Data((id + "\n").utf8).write(to: copy.appendingPathComponent(".sprava/backup-id"))
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        st.binders[id] = .init(path: base.appendingPathComponent("disconnected-volume/Binders/Original").path)
        #expect(throws: Backup.SharedBackupID.self) { _ = try b.claim(copy, &st) }
        #expect(st.binders[id]?.path?.hasSuffix("/Original") == true)
    }

    // MARK: - Manifests

    @Test func aManifestThrowsForWhatItCannotReadAndHoldsLinks() throws {
        let folder = try temp("manifest")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("documents/empty"), withIntermediateDirectories: true)
        try Data("invented deed".utf8).write(to: folder.appendingPathComponent("documents/deed.pdf"))
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("documents/current.pdf").path, withDestinationPath: "deed.pdf")
        let m = try Backup.manifest(folder)
        #expect(m["documents/current.pdf"] == "link deed.pdf")
        #expect(m["documents/empty"]?.hasPrefix("folder mode:") == true)
        #expect(m["documents/deed.pdf"]?.wholeMatch(of: /[0-9a-f]{64} mode:[0-7]+( xattr:[0-9a-f]{64})?/) != nil)

        let hidden = folder.appendingPathComponent("documents/hidden")
        try FileManager.default.createDirectory(at: hidden, withIntermediateDirectories: true)
        try Data("invented secret".utf8).write(to: hidden.appendingPathComponent("note.pdf"))
        chmod(hidden.path, 0o000)
        defer { chmod(hidden.path, 0o755) }
        #expect(throws: Backup.Failure.self) { _ = try Backup.manifest(folder) }
        chmod(hidden.path, 0o755)
        chmod(hidden.appendingPathComponent("note.pdf").path, 0o000)
        defer { chmod(hidden.appendingPathComponent("note.pdf").path, 0o644) }
        #expect(throws: Backup.Failure.self) { _ = try Backup.manifest(folder) }
    }

    @Test func theManifestSeesAttributesAndPermissions() throws {
        func setAttribute(_ name: String, _ value: String, on url: URL) {
            let bytes = Array(value.utf8)
            #expect(setxattr(url.path, name, bytes, bytes.count, 0, 0) == 0)
        }
        let folder = try temp("metadata")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("documents"), withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("documents/invented.pdf")
        try Data("invented".utf8).write(to: file)
        let plain = try Backup.manifest(folder)

        setAttribute("com.apple.metadata:_kMDItemUserTags", "invented tag", on: file)
        let tagged = try Backup.manifest(folder)
        #expect(tagged["documents/invented.pdf"] != plain["documents/invented.pdf"])
        setAttribute("com.apple.ResourceFork", "invented fork", on: file)
        #expect(try Backup.manifest(folder)["documents/invented.pdf"] != tagged["documents/invented.pdf"])

        let before = try Backup.manifest(folder)
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try Backup.manifest(folder)["documents/invented.pdf"] != before["documents/invented.pdf"])
        // A folder's own attributes count too.
        let folderBefore = try Backup.manifest(folder)["documents"]
        setAttribute("com.example.invented", "invented note", on: folder.appendingPathComponent("documents"))
        #expect(try Backup.manifest(folder)["documents"] != folderBefore)
        // What macOS keeps itself, and a restore cannot write back, is left out.
        #expect(Backup.volatileAttributes.isSuperset(of: ["com.apple.provenance", "com.apple.macl"]))

        // The binder folder's own metadata goes into the binder, so every snapshot holds it.
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        setAttribute("com.example.invented", "invented folder note", on: folder)
        let kept = try Backup.keepRootMetadata(folder)
        #expect(kept.attributes["com.example.invented"] == Data("invented folder note".utf8))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(Backup.folderMetadataPath).path))
    }

    @Test func differentManifestsNeverShareADigest() {
        let one = ["a": "link target\nb\tlink other"]
        let two = ["a": "link target", "b": "link other"]
        #expect(Backup.digest(one) != Backup.digest(two))
        #expect(Backup.digest(two) == Backup.digest(["b": "link other", "a": "link target"]))
    }
}

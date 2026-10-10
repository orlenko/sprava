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
        st.binders[id] = .init(path: "/Volumes/Invented-Disconnected-\(UUID().uuidString)/Binders/Original")
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
        #expect(m["documents/current.pdf"] == "link 8:deed.pdf")
        // A link's own attribute counts, read without following it.
        let link = folder.appendingPathComponent("documents/current.pdf").path
        let note = Array("invented link note".utf8)
        #expect(setxattr(link, "com.example.invented", note, note.count, 0, XATTR_NOFOLLOW) == 0)
        #expect(try Backup.manifest(folder)["documents/current.pdf"] != m["documents/current.pdf"])
        #expect(try Backup.manifest(folder)["documents/deed.pdf"] == m["documents/deed.pdf"])
        #expect(m["documents/empty"]?.hasPrefix("folder mtime:") == true)
        #expect(m["documents/deed.pdf"]?.wholeMatch(of: /[0-9a-f]{64} mtime:[0-9]+\.[0-9]+ mode:[0-7]+( xattr:[0-9a-f]{64})?/) != nil)

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

    @Test func aBinderWhoseAncestorMovedTakesItsIDAlong() throws {
        let base = try temp("ancestor")
        let original = base.appendingPathComponent("Projects/Binder", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let id = try Backup.backupID(original)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        _ = try b.claim(original, &st)
        // The whole Projects folder is renamed: the binder's old parent is gone too.
        try FileManager.default.moveItem(at: base.appendingPathComponent("Projects"), to: base.appendingPathComponent("Archive"))
        let moved = base.appendingPathComponent("Archive/Binder", isDirectory: true)
        #expect(Backup.folderEntry(original) == .missing)
        #expect(try b.claim(moved, &st) == id)
        #expect(st.binders[id]?.path == moved.standardizedFileURL.path)
        // A disk that is away is not a move.
        let away = URL(fileURLWithPath: "/Volumes/Invented-Away-\(UUID().uuidString)/Binders/Estate", isDirectory: true)
        #expect(Backup.folderEntry(away) == .unavailable)
    }

    @Test func anInterruptedReassignmentIsFinishedNotRepeated() throws {
        let base = try temp("reassign")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let old = try b.claim(original, &st)
        try b.save(st)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        // The new id is recorded, then writing it into the copy fails.
        let sprava = copy.appendingPathComponent(".sprava")
        chmod(sprava.path, 0o500)
        #expect(throws: (any Error).self) { try b.giveOwnBackupID(copy) }
        chmod(sprava.path, 0o700)
        #expect(Backup.existingBackupID(copy) == old)
        let pending = try #require(try b.state().binders.keys.first { $0 != old })
        #expect(try b.giveOwnBackupID(copy) == pending)
        #expect(try b.state().binders.count == 2)
    }

    @Test func modificationTimesAndHardLinksCount() throws {
        let folder = try temp("mtime-links")
        let a = folder.appendingPathComponent("a.pdf"), b = folder.appendingPathComponent("b.pdf")
        try Data("invented same bytes".utf8).write(to: a)
        let plain = try Backup.manifest(folder)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: a.path)
        let touched = try Backup.manifest(folder)
        #expect(touched["a.pdf"] != plain["a.pdf"])

        // Two links to one file, then two separate files with the same bytes and times: not the same manifest.
        try FileManager.default.linkItem(at: a, to: b)
        let linked = try Backup.manifest(folder)
        #expect(linked["b.pdf"]?.hasSuffix(" hardlink:a.pdf") == true)
        try FileManager.default.removeItem(at: b)
        try FileManager.default.copyItem(at: a, to: b)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_700_000_000)], ofItemAtPath: b.path)
        let separate = try Backup.manifest(folder)
        #expect(separate["b.pdf"] != linked["b.pdf"] || separate["a.pdf"] != linked["a.pdf"])
        #expect(Backup.digest(separate) != Backup.digest(linked))
    }

    @Test func anEmptyRecordOfAMovedBinderIsNeverTakenForAPendingReassignment() throws {
        let base = try temp("empty-record")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let source = try b.claim(original, &st)
        // Another binder was claimed at Place, never backed up, then moved away; a copy of Original now sits there.
        let place = base.appendingPathComponent("Place", isDirectory: true)
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        let earlier = try b.claim(place, &st)
        try b.save(st)
        try FileManager.default.moveItem(at: place, to: base.appendingPathComponent("Elsewhere"))
        try FileManager.default.copyItem(at: original, to: place)
        let own = try b.giveOwnBackupID(place)
        #expect(own != earlier && own != source)
        #expect(Backup.existingBackupID(base.appendingPathComponent("Elsewhere")) == earlier)
        #expect(try b.state().reassigning.isEmpty)
    }

    @Test func aFileWhereTheParentWasMeansTheBinderIsGone() throws {
        let base = try temp("enotdir")
        try Data("invented".utf8).write(to: base.appendingPathComponent("Projects"))
        #expect(Backup.folderEntry(base.appendingPathComponent("Projects/Binder", isDirectory: true)) == .missing)
    }

    @Test func foldersCountTheirTimesAndSocketsAreLeftOut() throws {
        let folder = try temp("folder-times")
        let documents = folder.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let before = try Backup.manifest(folder)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: documents.path)
        #expect(try Backup.manifest(folder)["documents"] != before["documents"])

        // A socket, which restic does not back up, is not in the manifest either.
        let socketPath = documents.appendingPathComponent("s").path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in socketPath.utf8.enumerated() where i < buffer.count - 1 { buffer[i] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        #expect(try Backup.manifest(folder)["documents/s"] == nil)
    }

    @Test func exclusionsMatchResticsPatternExactly() throws {
        let folder = try temp("tmp-names")
        for name in [".tmp", "..tmp", ".invented.tmp", "invented.tmp"] {
            try Data("invented".utf8).write(to: folder.appendingPathComponent(name))
        }
        let m = try Backup.manifest(folder)
        #expect(m[".tmp"] != nil && m["invented.tmp"] != nil)
        #expect(m["..tmp"] == nil && m[".invented.tmp"] == nil)
    }

    @Test func aLinkTargetCannotPassForMetadata() throws {
        let folder = try temp("link-collision")
        let plain = folder.appendingPathComponent("a")
        try FileManager.default.createSymbolicLink(atPath: plain.path, withDestinationPath: "target")
        let note = Array("invented".utf8)
        #expect(setxattr(plain.path, "com.example.invented", note, note.count, 0, XATTR_NOFOLLOW) == 0)
        let withAttribute = try #require(try Backup.manifest(folder)["a"])
        try FileManager.default.removeItem(at: plain)
        let suffix = String(withAttribute.dropFirst("link 6:target".count))
        try FileManager.default.createSymbolicLink(atPath: plain.path, withDestinationPath: "target" + suffix)
        #expect(try Backup.manifest(folder)["a"] != withAttribute)
    }

    @Test func aFIFOsPermissionsCount() throws {
        let folder = try temp("fifo")
        let fifo = folder.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let before = try #require(try Backup.manifest(folder)["pipe"])
        #expect(chmod(fifo, 0o640) == 0)
        #expect(try Backup.manifest(folder)["pipe"] != before)
    }

    @Test func aFileWhereTheBinderWasLetsTheMovedBinderKeepItsID() throws {
        let base = try temp("file-in-place")
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        for replaceParent in [false, true] {
            let original = base.appendingPathComponent("Projects-\(replaceParent)/Binder", isDirectory: true)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            var st = Backup.State()
            let id = try b.claim(original, &st)
            let moved = base.appendingPathComponent("Archive-\(replaceParent)", isDirectory: true)
            try FileManager.default.moveItem(at: original, to: moved)
            // A file now sits where the binder, or its parent folder, was.
            let replaced = replaceParent ? original.deletingLastPathComponent() : original
            if replaceParent { try FileManager.default.removeItem(at: replaced) }
            try Data("invented".utf8).write(to: replaced)
            #expect(try b.claim(moved, &st) == id)
            #expect(st.binders[id]?.path == moved.standardizedFileURL.path)
        }
    }

    @Test func aReassignmentThatWroteItsIDIsFinishedOnRetry() throws {
        let base = try temp("reassigned")
        let original = base.appendingPathComponent("Original", isDirectory: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let b = Backup(support: base.appendingPathComponent("support"), key: nil, resticBinary: nil, uploadCheck: { _ in .uploaded })
        var st = Backup.State()
        let old = try b.claim(original, &st)
        let copy = base.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        // As if the process stopped after writing the copy's new id, before clearing the reassignment.
        let new = "0123456789abcdef0123456789abcdef"
        st.binders[new] = .init(path: copy.standardizedFileURL.path)
        st.reassigning[old] = .init(path: copy.standardizedFileURL.path, id: new)
        try b.save(st)
        try Backup.writeBackupID(new, into: copy, creating: false)
        #expect(try b.giveOwnBackupID(copy) == new)
        #expect(try b.state().reassigning.isEmpty)
    }

    @Test func aBinderReachedThroughALinkOrWritableByItsGroupGetsAnID() throws {
        let base = try temp("binder-roots")
        let real = base.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        chmod(real.path, 0o775)
        let link = base.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let id = try Backup.backupID(link)
        #expect(Backup.existingBackupID(real) == id)
        #expect(try Backup.backupID(link) == id)
        #expect(try Backup.keepRootMetadata(link).mode == 0o775)
    }

    @Test func aBinderBehindALinkToADiskThatIsAwayKeepsItsID() throws {
        let base = try temp("linked-away")
        // Projects is a link to a folder on a disk that is not connected now.
        try FileManager.default.createSymbolicLink(atPath: base.appendingPathComponent("Projects").path,
                                                   withDestinationPath: "/Volumes/Invented-Away-\(UUID().uuidString)/Projects")
        let recorded = base.appendingPathComponent("Projects/Binder", isDirectory: true)
        #expect(Backup.folderEntry(recorded) == .unavailable)
        // A file at a parent's path still means the binder is gone; a working link to a folder is followed.
        let real = base.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real.appendingPathComponent("Binder"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("Shortcut"), withDestinationURL: real)
        #expect(Backup.folderEntry(base.appendingPathComponent("Shortcut/Binder", isDirectory: true)) == .present)
        #expect(Backup.folderEntry(base.appendingPathComponent("Shortcut/Gone", isDirectory: true)) == .missing)
    }
}

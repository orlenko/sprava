@testable import Backup
import Darwin
import Foundation
import Testing

/// Manifests: everything restic saves, compared entry by entry, and a read that a save lands in fails. Binders live
/// in temporary folders only; nothing here runs restic. Invented data only.
@Suite struct BackupManifestTests {
    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-manifest-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

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

    @Test func aFileSavedWhileItIsReadFailsTheManifest() throws {
        let folder = try temp("saved-during-read")
        let file = folder.appendingPathComponent("letter.pdf")
        try Data("invented first version".utf8).write(to: file)
        // An editor saves by renaming a new file into place, right after the old one was hashed.
        #expect(throws: Backup.Failure.self) {
            _ = try Backup.manifest(folder, afterRead: { url in
                try? Data("invented second version".utf8).write(to: url, options: .atomic)
            })
        }
        #expect(try Backup.manifest(folder)["letter.pdf"] != nil)
    }

    @Test func aFileAddedWhileTheBinderIsReadFailsTheManifest() throws {
        let folder = try temp("added-during-read")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("documents"), withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: folder.appendingPathComponent("documents/a.pdf"))
        for (watched, added) in [("documents", "documents/new.txt"), ("", "new.txt")] {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(added))
            let target = folder.appendingPathComponent(watched).standardizedFileURL.path
            #expect(throws: Backup.Failure.self) {
                _ = try Backup.manifest(folder, afterRead: { url in
                    // A save lands in a folder just after it was listed.
                    if url.standardizedFileURL.path == target {
                        try? Data("invented new".utf8).write(to: folder.appendingPathComponent(added))
                    }
                })
            }
        }
        #expect(try Backup.manifest(folder)["new.txt"] != nil)
    }

    @Test func aFIFOsAttributesCount() throws {
        let folder = try temp("fifo-xattr")
        let fifo = folder.appendingPathComponent("pipe").path
        #expect(mkfifo(fifo, 0o600) == 0)
        let before = try #require(try Backup.manifest(folder)["pipe"])
        let note = Array("invented note".utf8)
        #expect(setxattr(fifo, "com.example.invented", note, note.count, 0, XATTR_NOFOLLOW) == 0)
        #expect(try Backup.manifest(folder)["pipe"] != before)
    }

    @Test func aSaveIntoAFolderReadEarlierFailsTheManifest() throws {
        let folder = try temp("saved-into-earlier-folder")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("documents"), withIntermediateDirectories: true)
        try Data("invented".utf8).write(to: folder.appendingPathComponent("documents/a.pdf"))
        try Data("invented later file".utf8).write(to: folder.appendingPathComponent("z.bin"))
        // documents/ was read already; while z.bin is hashed, a save lands in documents/, and then in a.pdf.
        for target in ["documents/new.txt", "documents/a.pdf"] {
            #expect(throws: Backup.Failure.self) {
                _ = try Backup.manifest(folder, afterRead: { url in
                    if url.lastPathComponent == "z.bin" {
                        try? Data("invented save".utf8).write(to: folder.appendingPathComponent(target))
                    }
                })
            }
        }
    }

    @Test func aLinksAttributeChangedLaterInTheReadFailsTheManifest() throws {
        let folder = try temp("link-changed-later")
        let link = folder.appendingPathComponent("a-link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "z.bin")
        try Data("invented later file".utf8).write(to: folder.appendingPathComponent("z.bin"))
        #expect(throws: Backup.Failure.self) {
            _ = try Backup.manifest(folder, afterRead: { url in
                guard url.lastPathComponent == "z.bin" else { return }
                let note = Array("invented note".utf8)
                _ = setxattr(link.path, "com.example.invented", note, note.count, 0, XATTR_NOFOLLOW)
            })
        }
    }
}

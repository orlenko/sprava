@testable import SpravaKit
import Darwin
import Foundation
import Testing

@Suite struct DirectoryPublicationTests {
    enum FixtureFailure: Error { case unreadable }
    func data(_ directory: StateDirectory, _ name: String) throws -> Data {
        guard case .ok(let bytes) = try directory.read(name) else { throw FixtureFailure.unreadable }
        return bytes
    }

    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-publication-\(UUID())")
        _ = try StateDirectory.open(url, create: true)
        return url
    }

    @Test func publicationKeepsTheDirectoryContentsAndWriterLock() throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base))
        let privateArea = try #require(try root.directory("private", create: true))
        let visible = try #require(try root.directory("visible", create: true))
        let staged = try #require(try privateArea.directory("pending", create: true))
        let bytes = Data("invented prepared record".utf8)
        try staged.createImmutable(bytes, to: "record")
        let nested = try #require(try staged.directory("nested", create: true))
        try nested.write(bytes, to: "other")
        let original = base.appendingPathComponent("private/pending")
        var first = stat(); #expect(lstat(original.path, &first) == 0)
        let writer = try staged.openLock("writer.lock")
        defer { flock(writer, LOCK_UN); close(writer) }
        #expect(flock(writer, LOCK_EX | LOCK_NB) == 0)

        let published = try privateArea.publishDirectory("pending", to: visible, as: "binder")
        var after = stat(); #expect(lstat(base.appendingPathComponent("visible/binder").path, &after) == 0)
        #expect(first.st_dev == after.st_dev && first.st_ino == after.st_ino)
        #expect(after.st_mode & 0o7777 == 0o700)
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(try data(published, "record") == bytes)
        let publishedNested = try #require(try published.directory("nested"))
        #expect(try data(publishedNested, "other") == bytes)
        #expect(throws: (any Error).self) { try staged.read("record") }
        try published.write(bytes, to: "written-after-publication")
        let contender = try published.openLock("writer.lock")
        defer { close(contender) }
        #expect(flock(contender, LOCK_EX | LOCK_NB) != 0)
        #expect(errno == EWOULDBLOCK)
        #expect(flock(writer, LOCK_UN) == 0)
        #expect(flock(contender, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(contender, LOCK_UN) == 0)
    }

    @Test(arguments: ["directory", "file", "link", "fifo"])
    func anExistingDestinationIsPreserved(kind: String) throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base))
        let source = try #require(try root.directory("source", create: true))
        try source.write(Data("invented source".utf8), to: "record")
        let destination = base.appendingPathComponent("occupied")
        let bytes = Data("invented existing destination".utf8)
        if kind == "directory" {
            let existing = try #require(try root.directory("occupied", create: true))
            try existing.write(bytes, to: "record")
        } else if kind == "file" {
            try root.write(bytes, to: "occupied")
        } else if kind == "link" {
            try root.write(bytes, to: "outside")
            try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: base.appendingPathComponent("outside"))
        } else { #expect(mkfifo(destination.path, 0o600) == 0) }
        var first = stat(); #expect(lstat(destination.path, &first) == 0)
        #expect(throws: (any Error).self) { try root.publishDirectory("source", to: root, as: "occupied") }
        var after = stat(); #expect(lstat(destination.path, &after) == 0)
        #expect(first.st_ino == after.st_ino && first.st_mode == after.st_mode)
        #expect(try data(source, "record") == Data("invented source".utf8))
        if kind == "directory" {
            let existing = try #require(try root.directory("occupied"))
            #expect(try data(existing, "record") == bytes)
        }
        if kind == "file" { #expect(try data(root, "occupied") == bytes) }
        if kind == "link" { #expect(try data(root, "outside") == bytes) }
    }

    @Test(arguments: ["missing", "file", "link", "fifo", "writable-directory"])
    func onlyATrustedDirectoryCanBePublished(kind: String) throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base))
        let source = base.appendingPathComponent("source")
        if kind == "file" { try root.write(Data("invented file".utf8), to: "source") }
        if kind == "fifo" { #expect(mkfifo(source.path, 0o600) == 0) }
        if kind == "link" {
            _ = try root.directory("outside", create: true)
            try FileManager.default.createSymbolicLink(at: source, withDestinationURL: base.appendingPathComponent("outside"))
        }
        if kind == "writable-directory" {
            _ = try root.directory("source", create: true)
            #expect(chmod(source.path, 0o777) == 0)
        }
        var first = stat(); let existed = lstat(source.path, &first) == 0
        #expect(throws: (any Error).self) { try root.publishDirectory("source", to: root, as: "published") }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("published").path))
        if existed {
            var after = stat(); #expect(lstat(source.path, &after) == 0)
            #expect(first.st_ino == after.st_ino && first.st_mode == after.st_mode)
        }
    }

    @Test func aDestinationCreatedDuringPreparationIsNeverReplaced() throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base))
        let source = try #require(try root.directory("source", create: true))
        let bytes = Data("invented competing publication".utf8)
        try source.write(Data("invented original".utf8), to: "record")
        #expect(throws: (any Error).self) {
            try root.publishDirectory("source", to: root, as: "winner", beforePublish: {
                let winner = try #require(try root.directory("winner", create: true))
                try winner.write(bytes, to: "record")
            })
        }
        let winner = try #require(try root.directory("winner"))
        #expect(try data(winner, "record") == bytes)
        #expect(try data(source, "record") == Data("invented original".utf8))
    }

    @Test func invalidNamesCannotEscapeEitherParent() throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base))
        let source = try #require(try root.directory("source", create: true))
        let bytes = Data("invented retained contents".utf8)
        try source.write(bytes, to: "record")
        for name in ["", ".", "..", "../outside", "nested/entry", "invalid\0name"] {
            #expect(throws: (any Error).self) { try root.publishDirectory("source", to: root, as: name) }
            #expect(throws: (any Error).self) { try root.publishDirectory(name, to: root, as: "published") }
            #expect(try data(source, "record") == bytes)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["source"])
    }

    final class FailureSwitch: @unchecked Sendable {
        private let lock = NSLock()
        private var enabled = false
        var fails: Bool { lock.withLock { enabled } }
        func set(_ value: Bool) { lock.withLock { enabled = value } }
    }

    @Test func aFlushFailureAfterRenameLeavesThePublishedDirectoryIntact() throws {
        let base = try temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let failure = FailureSwitch()
        let flush = StateDirectory.Flush(directory: { fd in
            if failure.fails { throw AtomicFile.Failure(step: "invented post-publication flush", code: EIO) }
            try AtomicFile.flushToDisk(fd, step: "flush fixture directory")
        })
        let root = try #require(try StateDirectory.open(base, create: false, flush: flush))
        let source = try #require(try root.directory("source", create: true))
        let bytes = Data("invented recoverable contents".utf8)
        try source.createImmutable(bytes, to: "record")
        var first = stat(); #expect(lstat(base.appendingPathComponent("source").path, &first) == 0)
        #expect(throws: (any Error).self) {
            try root.publishDirectory("source", to: root, as: "published", beforePublish: { failure.set(true) })
        }
        failure.set(false)
        var after = stat(); #expect(lstat(base.appendingPathComponent("published").path, &after) == 0)
        #expect(after.st_ino == first.st_ino)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("source").path))
        let retained = try #require(try root.directory("published"))
        #expect(try data(retained, "record") == bytes)
        // A higher owner reconciles its recorded instance before using the durable matching-file retry.
        try retained.createImmutable(bytes, to: "record")
        #expect(throws: (any Error).self) { try root.publishDirectory("source", to: root, as: "published") }
        #expect(try data(retained, "record") == bytes)
    }
}

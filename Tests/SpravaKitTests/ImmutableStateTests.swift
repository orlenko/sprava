@testable import SpravaKit
import Darwin
import Foundation
import Testing

@Suite struct ImmutableStateTests {
    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-immutable-\(UUID())")
    }

    @Test func immutableCreationAndMatchingRetryArePrivateAndDurable() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base, create: true))
        let bytes = Data("invented immutable record".utf8)
        try root.createImmutable(bytes, to: "record")
        let file = base.appendingPathComponent("record")
        var first = stat()
        #expect(lstat(file.path, &first) == 0)
        #expect(first.st_mode & 0o7777 == 0o600)
        try root.createImmutable(bytes, to: "record")
        var retried = stat()
        #expect(lstat(file.path, &retried) == 0)
        #expect(retried.st_ino == first.st_ino)
        #expect(try Data(contentsOf: file) == bytes)
        #expect(throws: (any Error).self) { try root.createImmutable(Data("different".utf8), to: "record") }
        #expect(try Data(contentsOf: file) == bytes)
        try root.createImmutable(Data(), to: "empty")
        try root.createImmutable(Data(), to: "empty")
        for name in ["", ".", "..", "../outside", "invalid\0name"] {
            #expect(throws: (any Error).self) { try root.createImmutable(bytes, to: name) }
        }
    }

    @Test func existingUnsafeEntriesAreNeverReplacedOrRepaired() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base, create: true))
        let bytes = Data("invented original".utf8), target = base.appendingPathComponent("entry")
        let outside = base.appendingPathComponent("outside")
        try bytes.write(to: outside)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try root.createImmutable(bytes, to: "entry") }
        #expect(try Data(contentsOf: outside) == bytes)
        try FileManager.default.removeItem(at: target)
        #expect(mkfifo(target.path, 0o600) == 0)
        #expect(throws: (any Error).self) { try root.createImmutable(bytes, to: "entry") }
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try root.createImmutable(bytes, to: "entry") }
        try FileManager.default.removeItem(at: target)
        try bytes.write(to: target)
        #expect(chmod(target.path, 0o644) == 0)
        #expect(throws: (any Error).self) { try root.createImmutable(bytes, to: "entry") }
        var info = stat()
        #expect(lstat(target.path, &info) == 0)
        #expect(info.st_mode & 0o7777 == 0o644)
        #expect(try Data(contentsOf: target) == bytes)
    }

    final class Probe: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var files = 0
        func arm() { lock.withLock { armed = true } }
        func disarm() { lock.withLock { armed = false } }
        func file() { lock.withLock { files += 1 } }
        var count: Int { lock.withLock { files } }
        var refuses: Bool { lock.withLock { armed } }
    }

    @Test func retryReflushesThePublishedFileAfterAnUncertainDirectoryFlush() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try StateDirectory.open(base, create: true)
        let probe = Probe(), bytes = Data("invented recoverable record".utf8)
        let flush = StateDirectory.Flush(directory: { fd in
            if probe.refuses { throw AtomicFile.Failure(step: "invented directory flush failure", code: EIO) }
            try AtomicFile.flushToDisk(fd, step: "flush fixture directory")
        }, file: { fd in
            probe.file()
            try AtomicFile.flushToDisk(fd, step: "flush fixture file")
        })
        let root = try #require(try StateDirectory.open(base, create: false, flush: flush))
        #expect(throws: (any Error).self) {
            try root.write(bytes, to: "record", immutable: true, beforeOpen: {}, beforePublish: { _ in probe.arm() })
        }
        #expect(try Data(contentsOf: base.appendingPathComponent("record")) == bytes)
        #expect(probe.count == 1)
        probe.disarm()
        try root.createImmutable(bytes, to: "record")
        #expect(probe.count == 2)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["record"])
    }

    @Test(arguments: [false, true]) func concurrentPublishNeverOverwritesTheWinner(sameBytes: Bool) throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base, create: true))
        let ours = Data("invented first contender".utf8)
        let winner = sameBytes ? ours : Data("invented other contender".utf8)
        let create = {
            try root.write(ours, to: "record", immutable: true, beforeOpen: {}, beforePublish: { _ in
                try root.createImmutable(winner, to: "record")
            })
        }
        if sameBytes { try create() }
        else { #expect(throws: (any Error).self) { try create() } }
        #expect(try Data(contentsOf: base.appendingPathComponent("record")) == winner)
        #expect(try FileManager.default.contentsOfDirectory(atPath: base.path) == ["record"])
    }
}

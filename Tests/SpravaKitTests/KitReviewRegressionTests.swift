import Darwin
import Foundation
import Synchronization
@testable import SpravaKit
import Testing

/// Regression tests for the review of the SpravaKit layer. Each test names the finding it pins.
@Suite struct KitReviewRegressionTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(dir)
        return dir
    }

    // 1. A key that starts with a combining mark does not swallow the `/` before it.
    @Test func diffRoundTripsKeysStartingWithACombiningMark() throws {
        let a = try JSONParser.parse(Data("{\"outer\":{\"\u{0301}key\":1}}".utf8)).value
        let b = try JSONParser.parse(Data("{\"outer\":{\"\u{0301}key\":2}}".utf8)).value
        let patch = JSONPatch.diff(from: a, to: b)
        #expect(try JSONPatch.apply(patch, to: a) == b)
        #expect(try JSONPatch.tokens("/outer/\u{0301}key") == ["outer", "\u{0301}key"])
        #expect(JSONPatch.value(at: "/outer/\u{0301}key", in: b) == .int(2))
        // Escapes stay scalar-exact too, even next to a combining mark.
        #expect(JSONPatch.escape("a/\u{0301}~\u{0301}") == "a~1\u{0301}~0\u{0301}")
        #expect(try JSONPatch.tokens("/a~1\u{0301}~0\u{0301}") == ["a/\u{0301}~\u{0301}"])
        #expect(throws: JSONPatch.Failure.self) { try JSONPatch.tokens("/a~2") }
    }

    // 2. A failed F_FULLFSYNC, or a folder that cannot be opened or flushed, fails the write; a disk error is
    // never papered over with plain fsync.
    @Test func failedFlushesFailTheWrite() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("x.json")
        try AtomicFile.write(Data("old".utf8), to: url)

        let fsyncCalls = Mutex(0)
        var flush = AtomicFile.Flush()
        flush.fullSync = { _ in errno = EIO; return -1 }
        flush.sync = { fd in fsyncCalls.withLock { $0 += 1 }; return fsync(fd) }
        #expect { try AtomicFile.write(Data("new".utf8), to: url, mode: 0o600, flush: flush) } throws: {
            ($0 as? AtomicFile.Failure).map { $0.step == "fsync" && $0.code == EIO } ?? false
        }
        #expect(fsyncCalls.withLock { $0 } == 0)
        #expect(try String(contentsOf: url, encoding: .utf8) == "old")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x.json"])

        flush = AtomicFile.Flush()
        flush.openFolder = { _ in errno = EACCES; return -1 }
        #expect { try AtomicFile.write(Data("new".utf8), to: url, mode: 0o600, flush: flush) } throws: {
            ($0 as? AtomicFile.Failure)?.step == "open folder"
        }

        // The file flush passes, the folder flush hits a disk error.
        let fullSyncCalls = Mutex(0)
        flush = AtomicFile.Flush()
        flush.fullSync = { fd in
            if fullSyncCalls.withLock({ $0 += 1; return $0 }) == 2 { errno = EIO; return -1 }
            return fcntl(fd, F_FULLFSYNC)
        }
        #expect { try AtomicFile.write(Data("new".utf8), to: url, mode: 0o600, flush: flush) } throws: {
            ($0 as? AtomicFile.Failure)?.step == "fsync folder"
        }
    }

    // 2. A volume without F_FULLFSYNC (exFAT, SMB) falls back to fsync, and only fsync's failure fails the write.
    @Test(arguments: [ENOTSUP, EINVAL, ENOTTY])
    func unsupportedFullSyncFallsBackToFsync(code: Int32) throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("x.json")
        let fsyncCalls = Mutex(0)
        var flush = AtomicFile.Flush()
        flush.fullSync = { _ in errno = code; return -1 }
        flush.sync = { fd in fsyncCalls.withLock { $0 += 1 }; return fsync(fd) }
        try AtomicFile.write(Data("new".utf8), to: url, mode: 0o600, flush: flush)
        #expect(fsyncCalls.withLock { $0 } == 2)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")

        try AtomicFile.write(Data("old".utf8), to: url)
        flush.sync = { _ in errno = EIO; return -1 }
        #expect { try AtomicFile.write(Data("new".utf8), to: url, mode: 0o600, flush: flush) } throws: {
            ($0 as? AtomicFile.Failure).map { $0.step == "fsync" && $0.code == EIO } ?? false
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "old")

        // The file's fsync passes, the folder's fails.
        let calls = Mutex(0)
        flush.sync = { fd in
            if calls.withLock({ $0 += 1; return $0 }) == 2 { errno = EIO; return -1 }
            return fsync(fd)
        }
        #expect { try AtomicFile.write(Data("new".utf8), to: url, mode: 0o600, flush: flush) } throws: {
            ($0 as? AtomicFile.Failure)?.step == "fsync folder"
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x.json"])
    }

    // 2. An interrupted flush is retried, not reported.
    @Test func interruptedFlushIsRetried() throws {
        let url = try tempDir().appendingPathComponent("x.json")
        let calls = Mutex(0)
        var flush = AtomicFile.Flush()
        flush.fullSync = { fd in
            if calls.withLock({ $0 += 1; return $0 }) == 1 { errno = EINTR; return -1 }
            return fcntl(fd, F_FULLFSYNC)
        }
        try AtomicFile.write(Data("new".utf8), to: url, mode: 0o600, flush: flush)
        // The file twice (one interrupted), then the folder.
        #expect(calls.withLock { $0 } == 3)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new")
    }

    // 3. Array indices are `0` or digits without a leading zero; no sign.
    @Test func arrayIndicesAreStrict() throws {
        let doc = JSONValue.array([.int(10), .int(20)])
        for path in ["/01", "/+1", "/-0", "/ 1", "/1 ", "/00"] {
            #expect(throws: JSONPatch.Failure.self) {
                try JSONPatch.apply([.obj([("op", .str("remove")), ("path", .str(path))])], to: doc)
            }
            #expect(throws: JSONPatch.Failure.self) {
                try JSONPatch.apply([.obj([("op", .str("replace")), ("path", .str(path)), ("value", .int(0))])], to: doc)
            }
            #expect(throws: JSONPatch.Failure.self) {
                try JSONPatch.apply([.obj([("op", .str("add")), ("path", .str(path)), ("value", .int(0))])], to: doc)
            }
            #expect(JSONPatch.value(at: path, in: doc) == nil)
        }
        #expect(try JSONPatch.apply([.obj([("op", .str("remove")), ("path", .str("/1"))])], to: doc) == .array([.int(10)]))
        #expect(try JSONPatch.apply([.obj([("op", .str("add")), ("path", .str("/-")), ("value", .int(30))])], to: doc)
            == .array([.int(10), .int(20), .int(30)]))
        #expect(JSONPatch.value(at: "/0", in: doc) == .int(10))
        #expect(JSONPatch.index("99999999999999999999999") == nil)
    }
}

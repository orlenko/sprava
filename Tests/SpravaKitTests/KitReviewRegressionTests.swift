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

    // The flush rule other targets share: fsync stands in only where F_FULLFSYNC is unsupported, and a folder
    // that cannot be opened fails under the named step.
    @Test func sharedFlushRule() throws {
        let dir = try tempDir()
        let fd = open(dir.appendingPathComponent("x").path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        defer { close(fd) }
        var synced = 0
        try AtomicFile.flushToDisk(fd, step: "flush x", fullSync: { _ in errno = ENOTSUP; return -1 },
                                   sync: { synced += 1; return fsync($0) })
        #expect(synced == 1)
        #expect { try AtomicFile.flushToDisk(fd, step: "flush x", fullSync: { _ in errno = EIO; return -1 }) } throws: {
            ($0 as? AtomicFile.Failure).map { $0.step == "flush x" && $0.code == EIO } ?? false
        }
        try AtomicFile.flushFolder(dir, step: "flush folder")
        #expect { try AtomicFile.flushFolder(dir.appendingPathComponent("absent"), step: "flush folder") } throws: {
            ($0 as? AtomicFile.Failure).map { $0.step == "flush folder" && $0.code == ENOENT } ?? false
        }
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

    // 4. Only an absent file is `missing`: one without read permission is refused, and an open, stat or read
    // that fails is `unreadable`, never taken for absence.
    @Test func safeReadTellsAbsentFromUnreadable() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("note.json")
        try AtomicFile.write(Data("{}".utf8), to: url)
        guard case .ok = SafeFile.read(url) else { Issue.record("a readable file"); return }
        guard case .missing = SafeFile.read(dir.appendingPathComponent("absent.json")) else { Issue.record("absent"); return }
        guard case .missing = SafeFile.read(url.appendingPathComponent("below-a-file")) else { Issue.record("ENOTDIR"); return }
        if getuid() != 0 {
            #expect(chmod(url.path, 0) == 0)
            defer { chmod(url.path, 0o600) }
            guard case .refused = SafeFile.read(url) else { Issue.record("no permission is not missing"); return }
        }
        guard case .unreadable = SafeFile.openFailure(EMFILE) else { Issue.record("EMFILE"); return }
        guard case .unreadable = SafeFile.openFailure(EIO) else { Issue.record("EIO"); return }
        // A descriptor that cannot be read: a regular file of this user opened for writing only.
        let writeOnly = open(url.path, O_WRONLY)
        #expect(writeOnly >= 0)
        defer { close(writeOnly) }
        guard case .unreadable = SafeFile.read(fd: writeOnly, limit: 1024) else { Issue.record("read error"); return }
        guard case .unreadable = SafeFile.read(fd: -1, limit: 1024) else { Issue.record("fstat error"); return }
    }

    // 5. Instants convert on the proleptic Gregorian calendar, as parsing and day arithmetic do, before 1582 too.
    @Test func instantsConvertProleptically() throws {
        let utc = TimeZone(identifier: "UTC")!
        for date in [CalendarDate(year: 1500, month: 3, day: 1)!, CalendarDate(year: 1, month: 1, day: 1)!,
                     CalendarDate(year: 1582, month: 10, day: 10)!, CalendarDate(year: 9999, month: 12, day: 31)!] {
            let midnight = Date(timeIntervalSince1970: Double(date.dayNumber - 719_162) * 86_400)
            #expect(CalendarDate(midnight, in: utc) == date)
            #expect(CalendarDate(midnight.addingTimeInterval(86_399), in: utc) == date)
        }
        #expect(CalendarDate(Date(timeIntervalSince1970: -62_135_596_801), in: utc) == nil)   // 0000-12-31T23:59:59Z
        #expect(CalendarDate(Date(timeIntervalSince1970: 253_402_300_800), in: utc) == nil)   // 10000-01-01
        #expect(CalendarDate(Date(timeIntervalSince1970: 0), in: TimeZone(secondsFromGMT: -3600)!)?.description == "1969-12-31")
    }

    // 6. A fraction longer than Foundation takes still parses, and nine nines stay in their own second and day.
    @Test func longFractionsParse() throws {
        let utc = TimeZone(identifier: "UTC")!
        let midnight = Date(timeIntervalSince1970: 1_791_244_800)   // 2026-10-06T00:00:00Z
        for text in ["2026-10-05T23:59:59.1234567890Z", "2026-10-05T23:59:59.999999999Z",
                     "2026-10-05T23:59:59.99999999999999999999z", "2026-10-05T19:59:59.9999999999-04:00"] {
            let instant = try #require(Timestamp.parse(text), "\(text)")
            #expect(instant < midnight && instant >= midnight.addingTimeInterval(-1), "\(text)")
            #expect(CalendarDate(instant, in: utc)?.description == "2026-10-05", "\(text)")
        }
        let short = try #require(Timestamp.parse("2026-10-05T23:59:59.25+05:30"))
        #expect(abs(short.timeIntervalSince1970 - 1_791_224_999.25) < 0.000_01)
        #expect(Timestamp.parse("2016-12-31T23:59:60Z") == Timestamp.parse("2016-12-31T23:59:59Z"))
    }

    // 7. The random part of an id is always filled, so two processes starting in one millisecond never meet.
    @Test func idsCarryRandomBits() {
        let at = Date(timeIntervalSince1970: 1_791_360_000)
        let tails = (0..<64).map { _ in String(UUIDv7.make(now: at).suffix(12)) }
        #expect(Set(tails).count == tails.count)
        #expect(!tails.contains("000000000000"))
    }

    // 8. Appends from several jobs at once never lose a rotated log: every line is still in one of the files.
    @Test func concurrentAppendsKeepEveryLine() throws {
        let dir = try tempDir()
        let log = dir.appendingPathComponent("jobs.log")
        let count = 400
        DispatchQueue.concurrentPerform(iterations: count) { i in
            AtomicFile.appendLine("line \(i)", to: log, limit: 64, keep: 200)
        }
        let files = [log] + (1...201).map { URL(fileURLWithPath: log.path + ".\($0)") }
        let lines = files.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { $0.split(separator: "\n").map(String.init) }
        #expect(Set(lines) == Set((0..<count).map { "line \($0)" }))
        #expect(lines.count == count)
    }
}

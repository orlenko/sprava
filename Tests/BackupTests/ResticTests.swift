@testable import Backup
import Darwin
import Foundation
import SpravaKit
import Testing

/// Regressions from the last Bugbot review of the Backup layer and issue #205 (a restic run that waits forever).
/// restic runs against repositories in temporary folders only, or is replaced by a /bin/sh stand-in. Invented data only.
@Suite(.serialized) struct ResticTests {

    func temp(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-final-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A Restic whose binary is `script`, a /bin/sh stand-in, with its own repository and support folders.
    func standIn(_ script: String) throws -> (Restic, URL) {
        let base = try temp("standin")
        let binary = base.appendingPathComponent("restic")
        try Data(("#!/bin/sh\n" + script + "\n").utf8).write(to: binary)
        chmod(binary.path, 0o755)
        var r = Restic(binary: binary, repository: base.appendingPathComponent("repo"), key: "TEST-KEY-AAAAA-BBBBB",
                       support: base.appendingPathComponent("support"))
        r.grace = 0.5
        return (r, base)
    }

    // MARK: - #205: a restic run can wait forever

    @Test func aChildLeftHoldingResticsOutputNeverHoldsUpTheRun() throws {
        let (r, base) = try standIn("sleep 30 &\necho $! > \"$(dirname \"$0\")/child.pid\"\necho done\nexit 0")
        let started = Date()
        let o = try r.run(["snapshots"])
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(o.status == 0)
        #expect(String(decoding: o.stdout, as: UTF8.self) == "done\n")
        // The child it left is stopped with it.
        let pid = try #require(Int32(String(contentsOf: base.appendingPathComponent("child.pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        var gone = false
        for _ in 0..<100 where !gone {
            gone = kill(pid, 0) != 0 && errno == ESRCH
            if !gone { usleep(20_000) }
        }
        #expect(gone)
    }

    @Test func aResticThatIgnoresSIGTERMIsKilledAtTheDeadline() throws {
        let (r, _) = try standIn("trap '' TERM\nsleep 30 &\nwhile :; do sleep 1; done")
        let started = Date()
        #expect(throws: Restic.Failure.self) { try r.run(["check"], timeout: 1) }
        #expect(Date().timeIntervalSince(started) < 10)
    }

    // MARK: - q5Hag: the no-progress cutoff

    @Test func aResticThatOnlyCountsTheSecondsIsStoppedAsStalled() throws {
        let (r, _) = try standIn("i=0\nwhile :; do i=$((i+1)); echo \"[0:0$i] 10.00%  1 / 10 packs\"; sleep 0.1; done")
        let started = Date()
        do {
            try r.run(["check"], stall: 1)
            Issue.record("a stalled run finished")
        } catch let failure as Restic.Failure {
            #expect(failure.message.contains("no progress"))
        }
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(ResticProcess.progressKey(#"{"message_type":"status","seconds_elapsed":5,"seconds_remaining":9,"percent_done":0.5}"#)
            == ResticProcess.progressKey(#"{"message_type":"status","seconds_elapsed":10,"seconds_remaining":4,"percent_done":0.5}"#))
    }

    @Test func aResticThatMakesProgressIsNeverStopped() throws {
        let (r, _) = try standIn("for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo \"[0:0$i] $i.00%  $i / 15 packs\"; sleep 0.2; done")
        let o = try r.run(["check"], stall: 1)
        #expect(o.status == 0)
    }

    @Test func verificationIsSupervisedAfterTheRestorationSummary() throws {
        var (r, _) = try standIn("echo '{\"message_type\":\"summary\",\"files_restored\":2}'\nsleep 3\nexit 0")
        r.diskProgress = { _ in 0 }
        #expect(throws: Restic.Failure.self) {
            try r.run(["restore"], stall: 0.3, observeIOAfter: Restic.summaryMarker)
        }
        let progress = Counter()
        r.diskProgress = { _ in progress.next() }
        #expect(try r.run(["restore"], stall: 0.3, observeIOAfter: Restic.summaryMarker).status == 0)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0
        func next() -> UInt64 { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    // MARK: - qnY_p: peeked documents are streamed to their file

    @Test func dumpWritesTheDocumentToItsFileNotToMemory() throws {
        let (r, base) = try standIn("head -c 3000000 /dev/zero")
        let file = base.appendingPathComponent("deed.pdf")
        let o = try r.run(["dump"], stdoutTo: file)
        #expect(o.stdout.isEmpty)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path))[.size] as? Int == 3_000_000)
        try r.dump("0123abcd", path: "/documents/deed.pdf", to: base.appendingPathComponent("again.pdf"))
        #expect((try FileManager.default.attributesOfItem(atPath: base.appendingPathComponent("again.pdf").path))[.size] as? Int == 3_000_000)
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: base.path)).contains { $0.hasSuffix(".part") })
    }

    @Test func aDocumentWithTheLongestNameCanBePeeked() throws {
        let (r, base) = try standIn("echo invented")
        let name = String(repeating: "a", count: 251) + ".pdf"
        try r.dump("0123abcd", path: "/documents/" + name, to: base.appendingPathComponent(name))
        #expect(try String(contentsOf: base.appendingPathComponent(name), encoding: .utf8) == "invented\n")
    }

    // MARK: - Sleep: the cutoff runs on a clock that stops while the Mac sleeps

    final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        let jumpAfter: Int?
        init(jumpAfter: Int?) { self.jumpAfter = jumpAfter }
        /// Frozen at 0 (a Mac asleep throughout), or jumping an hour ahead at read `jumpAfter + 1`, which takes a
        /// moment of real time, as a Mac that sleeps while restic's output comes in, on a clock that counts the sleep.
        func now() -> TimeInterval {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            guard let jumpAfter else { return 0 }
            if calls == jumpAfter + 1 { usleep(300_000) }
            return calls > jumpAfter ? 3600 : 0
        }
    }

    @Test func theCutoffIsMeasuredOnTheInjectedClock() throws {
        var (r, _) = try standIn("echo '[0:01] 10.00%  1 / 10 packs'\nsleep 2\nexit 0")
        let frozen = FakeClock(jumpAfter: nil)
        r.clock = { frozen.now() }
        #expect(try r.run(["check"], stall: 1).status == 0)
    }

    @Test func outputWaitingAfterASleepIsReadBeforeTheCutoff() throws {
        var (r, _) = try standIn("for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do echo \"[0:0$i] $i.00%  $i / 15 packs\"; sleep 0.1; done")
        let jumping = FakeClock(jumpAfter: 6)
        r.clock = { jumping.now() }
        #expect(try r.run(["check"], stall: 600).status == 0)
    }

    // MARK: - q5Hav: key files an interrupted run left behind

    @Test func keyFilesLeftByAnInterruptedRunAreRemovedByTheNextRun() throws {
        let (r, _) = try standIn("exit 0")
        try AtomicFile.makePrivateFolder(r.runDir)
        let stale = r.runDir.appendingPathComponent("stale-key")
        let fresh = r.runDir.appendingPathComponent("fresh-key")
        try Data("INVNT-KEYAA\n".utf8).write(to: stale)
        try Data("INVNT-KEYBB\n".utf8).write(to: fresh)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: stale.path)
        try r.run(["snapshots"])
        let left = try FileManager.default.contentsOfDirectory(atPath: r.runDir.path)
        #expect(left == ["fresh-key"])
    }

    @Test func everyResticCommandRechecksThePinnedExecutable() throws {
        let base = try temp("restic-pin")
        let binary = base.appendingPathComponent("restic")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: binary)
        chmod(binary.path, 0o755)
        let r = Restic(binary: binary, repository: base.appendingPathComponent("repo"), key: "TEST-KEY-AAAAA-BBBBB",
                       support: base.appendingPathComponent("support"))
        #expect(try r.run(["version"]).status == 0)
        let marker = base.appendingPathComponent("invented-ran")
        try Data("#!/bin/sh\ntouch \"\(marker.path)\"\nexit 0\n".utf8).write(to: binary)
        chmod(binary.path, 0o755)
        #expect(throws: Restic.Failure.self) { try r.run(["version"]) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aMissingExecutableNeverCreatesAKeyFile() throws {
        let base = try temp("missing-binary")
        let r = Restic(binary: base.appendingPathComponent("missing"), repository: base.appendingPathComponent("repo"),
                       key: "INVNT-KEYAA", support: base.appendingPathComponent("support"))
        #expect(throws: Restic.Failure.self) { try r.run(["version"]) }
        #expect(!FileManager.default.fileExists(atPath: r.runDir.path))
    }

    @Test func keyFilesAreRemovedWhenTheWriteThrowsAfterRenaming() throws {
        for rejectedKey in ["TEST-KEY-AAAAA-BBBBB", "INVNT-OTHER"] {
            var (r, _) = try standIn("exit 0")
            r.writeKey = { data, url in
                try AtomicFile.write(data, to: url)
                if data == Data((rejectedKey + "\n").utf8) { throw Restic.Failure(message: "invented post-rename flush failure") }
            }
            #expect(throws: Restic.Failure.self) {
                try r.run(["copy"], otherKey: (r.repository, "INVNT-OTHER"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: r.runDir.path).isEmpty)
        }
    }

    @Test func aBlockedSinkWriterCannotBlockTheSupervisor() throws {
        var (r, base) = try standIn("head -c 3000000 /dev/zero")
        let helper = base.appendingPathComponent("blocked-writer")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do sleep 1; done\n".utf8).write(to: helper)
        chmod(helper.path, 0o755)
        r.sinkWriterBinary = helper
        let started = Date()
        #expect(throws: Restic.Failure.self) {
            try r.run(["dump"], timeout: 0.5, stdoutTo: base.appendingPathComponent("output"))
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func tagRemovalResolvesShortIDsAndRefusesAmbiguousOnes() throws {
        let first = "0123abcd" + String(repeating: "a", count: 56)
        let second = "0123abcd" + String(repeating: "b", count: 56)
        for ids in [[first], [first, second]] {
            let json = String(data: try JSONSerialization.data(withJSONObject: ids.enumerated().map { index, id in
                ["id": id, "tags": index == 0 ? ["offloaded"] : []] as [String: Any]
            }), encoding: .utf8)!
            let (r, base) = try standIn("if [ \"$1\" = snapshots ]; then echo '\(json)'; else printf '%s\\n' \"$@\" > \"$(dirname \"$0\")/arguments\"; fi")
            let output = base.appendingPathComponent("arguments")
            if ids.count == 1 {
                try r.removeTag("offloaded", from: "0123abcd")
                #expect(try String(contentsOf: output, encoding: .utf8).split(separator: "\n")[1] == Substring(first))
            } else {
                #expect(throws: Restic.Failure.self) { try r.removeTag("offloaded", from: "0123abcd") }
                #expect(!FileManager.default.fileExists(atPath: output.path))
            }
        }
    }

    @Test func lockMaintenanceCannotKeepAStuckVerificationAlive() throws {
        var (r, _) = try standIn("echo '{\"message_type\":\"summary\"}'\nsleep 30")
        let maintenance = Counter()
        r.diskProgress = { _ in
            var usage = rusage_info_v4()
            usage.ri_diskio_byteswritten = maintenance.next()
            return ResticProcess.verificationReads(usage)
        }
        let started = Date()
        #expect(throws: Restic.Failure.self) {
            try r.run(["restore"], stall: 0.3, observeIOAfter: Restic.summaryMarker)
        }
        #expect(Date().timeIntervalSince(started) < 3)
    }

    @Test func aDescendantHoldingStreamedOutputCannotKeepTheHelperAlive() throws {
        var (r, base) = try standIn("sleep 30 &\necho invented\nexit 0")
        r.drainLimit = 0.3
        let started = Date()
        #expect(throws: Restic.Failure.self) { try r.run(["dump"], stall: nil, stdoutTo: base.appendingPathComponent("output")) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func spawnPreservesSourcesThatOverlapStandardDestinations() throws {
        let process = ResticProcess(binary: URL(fileURLWithPath: "/bin/sh"),
                                    arguments: ["-c", "printf 'invented descriptor probe\\n' >&2"],
                                    environment: ["PATH": "/usr/bin:/bin"], cwd: nil, timeout: 1, stall: 1,
                                    observeIOAfter: nil, grace: 0.5)
        // stdout maps descriptor 0 over descriptor 1. stderr must still refer to the original writable 1.
        let pid = try process.spawn(stdout: 0, stderr: 1)
        let exited = process.exited(pid, within: 2)
        if !exited { killpg(pid, SIGKILL) }
        #expect(exited)
        if process.exited(pid, within: 1) { #expect(process.reap(pid) == 0) }
    }

    @Test func checkedErrorsDoNotExposePrivateDiagnosticPaths() throws {
        let (r, _) = try standIn("echo 'permission denied: /Invented Private Binder/private-paper.pdf' >&2\nexit 1")
        do {
            try r.initRepository()
            Issue.record("the failing command succeeded")
        } catch let failure as Restic.Failure {
            #expect(failure.message.contains("access was denied"))
            #expect(!failure.message.contains("Invented Private Binder"))
            #expect(!failure.message.contains("private-paper.pdf"))
        }
    }

    @Test func aFIFOOutputDestinationIsRefusedBeforeStartingRestic() throws {
        let (r, base) = try standIn("touch \"$(dirname \"$0\")/started\"")
        let file = base.appendingPathComponent("output")
        #expect(mkfifo(file.path, 0o600) == 0)
        let started = Date()
        #expect(throws: Restic.Failure.self) { try r.run(["dump"], stdoutTo: file) }
        #expect(Date().timeIntervalSince(started) < 1)
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("started").path))
    }

    @Test func outputSetupErrorsContainNoPrivatePaths() throws {
        for denyErrorOutput in [true, false] {
            var (r, base) = try standIn("exit 0")
            r.openOutput = { url, flags, mode in
                if url.path.hasSuffix(".err") == denyErrorOutput { errno = EACCES; return -1 }
                return open(url.path, flags, mode)
            }
            do {
                try r.run(["dump"], stdoutTo: base.appendingPathComponent("invented-private-paper.pdf"))
                Issue.record("the refused setup succeeded")
            } catch let failure as Restic.Failure {
                #expect(failure.message.contains("errno"))
                #expect(!failure.message.contains(base.path))
                #expect(!failure.message.contains("invented-private-paper.pdf"))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: r.runDir.path).isEmpty)
        }
    }

    @Test(.enabled(if: Restic.locate() != nil)) func theRealResticAdapterRoundTripsInventedFiles() throws {
        let base = try temp("real-restic")
        defer { try? FileManager.default.removeItem(at: base) }
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let contents = Data("an invented letter\n".utf8)
        try contents.write(to: source.appendingPathComponent("letter.txt"))
        let r = Restic(binary: try #require(Restic.locate()), repository: base.appendingPathComponent("repository"),
                       key: "INVNT-KEYAA-BBBBB", support: base.appendingPathComponent("support"))
        try r.initRepository()
        let written = try r.backup(source, tags: ["binder:invented", "offloaded"], excludes: [])
        let snapshot = try #require(written.snapshot)
        #expect(try r.snapshots(tag: "binder:invented").contains { $0.id == snapshot })
        #expect(try r.files(snapshot).contains("letter.txt"))
        let restored = base.appendingPathComponent("restored")
        try r.restore(snapshot, into: restored)
        #expect(try Data(contentsOf: restored.appendingPathComponent("letter.txt")) == contents)
        let preview = base.appendingPathComponent("preview.txt")
        try r.dump(snapshot, path: "/letter.txt", to: preview)
        #expect(try Data(contentsOf: preview) == contents)
        try r.removeTag("offloaded", from: String(snapshot.prefix(8)))
        #expect(try r.snapshots(tag: "binder:invented").allSatisfy { !$0.tags.contains("offloaded") })
    }

    @Test func aSlowFinalSinkWriteUsesTheConfiguredStallPolicy() throws {
        var (r, base) = try standIn("echo invented")
        let helper = base.appendingPathComponent("slow-writer")
        try Data("#!/bin/sh\nsleep 2\nexec /usr/bin/tee \"$@\"\n".utf8).write(to: helper)
        chmod(helper.path, 0o755)
        r.sinkWriterBinary = helper
        let file = base.appendingPathComponent("output")
        #expect(try r.run(["dump"], stall: 3, stdoutTo: file).status == 0)
        #expect(try String(contentsOf: file, encoding: .utf8) == "invented\n")
    }
}

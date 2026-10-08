import Foundation
@testable import SpravaKit
import Testing

@Suite struct LeaseAndHeartbeatTests {
    func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(dir)
        return dir
    }

    @Test func atomicWriteLeavesNoTempFiles() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("x.json")
        for i in 0..<5 { try AtomicFile.write(Data("\(i)".utf8), to: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "4")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["x.json"])
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func logRotation() throws {
        let url = try tempDir().appendingPathComponent("jobs.log")
        for i in 0..<50 { AtomicFile.appendLine("line \(i) " + String(repeating: "x", count: 30), to: url, limit: 200, keep: 3) }
        let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path).sorted()
        #expect(files == ["jobs.log", "jobs.log.1", "jobs.log.2", "jobs.log.3"])
    }

    @Test func processCheckRecognisesThisProcess() {
        let start = ProcessCheck.startTime(pid: getpid())
        #expect(start != nil)
        #expect(ProcessCheck.isAlive(pid: getpid(), startedAt: start))
        #expect(!ProcessCheck.isAlive(pid: getpid(), startedAt: start!.addingTimeInterval(-3600)))
        #expect(!ProcessCheck.isAlive(pid: 999_999, startedAt: nil))
    }
}

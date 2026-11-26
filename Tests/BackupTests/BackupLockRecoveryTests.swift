@testable import Backup
import Darwin
import Foundation
import Testing

extension BackupMaintenanceTests {
    @Test(.enabled(if: hasRestic)) func maintenanceRecoversAKilledBackupButPreservesALiveLock() throws {
        let base = try temp("abandoned-lock")
        defer { try? FileManager.default.removeItem(at: base) }
        let b = backup(base.appendingPathComponent("support"))
        let repo = base.appendingPathComponent("repo")
        try b.setUp(primary: repo, iCloudKeychain: false, deviceID: "dev")
        let r = try b.engine(repo.path)
        let source = base.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("Invented note".utf8).write(to: source.appendingPathComponent("note.txt"))
        let saved = try #require(try r.backup(source, tags: ["fixture"], excludes: []).snapshot)

        // Hold a real append lock by leaving the fixture's stdin open, then simulate an unclean exit.
        let writer = Process()
        let input = Pipe()
        writer.executableURL = r.binary
        writer.arguments = ["backup", "--stdin", "--repo", repo.path, "--no-cache"]
        writer.environment = ["RESTIC_PASSWORD": r.key, "PATH": "/usr/bin:/bin"]
        writer.standardInput = input
        writer.standardOutput = FileHandle.nullDevice
        writer.standardError = FileHandle.nullDevice
        try writer.run()
        defer {
            if writer.isRunning { kill(writer.processIdentifier, SIGKILL); writer.waitUntilExit() }
            try? input.fileHandleForWriting.close()
        }
        let locks = repo.appendingPathComponent("locks")
        func lockIDs() throws -> [String] {
            try FileManager.default.contentsOfDirectory(atPath: locks.path).filter { $0.wholeMatch(of: /[0-9a-f]{64}/) != nil }
        }
        let deadline = ContinuousClock.now + .seconds(15)
        while try lockIDs().isEmpty && writer.isRunning && ContinuousClock.now < deadline { usleep(20_000) }
        let ids = try lockIDs()
        try #require(ids.count == 1)

        try b.recoverAbandonedLocks(in: repo, mark: Backup.macMark("dev"))
        #expect(try lockIDs() == ids)
        #expect(try r.run(["check"]).status == 11)
        try #require(kill(writer.processIdentifier, SIGKILL) == 0)
        writer.waitUntilExit()
        try b.recoverAbandonedLocks(in: repo, mark: Backup.macMark("other"))
        #expect(try lockIDs() == ids)

        let recovered = maintain(b, [])
        #expect(recovered.failed == 0 && recovered.checked && recovered.retention && recovered.stateSnapshot)
        #expect(try lockIDs().isEmpty)
        #expect(try r.snapshots(tag: "fixture").contains { $0.id == saved })
    }
}

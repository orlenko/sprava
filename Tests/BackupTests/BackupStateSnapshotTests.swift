@testable import Backup
import Darwin
import Foundation
import SpravaKit
import Testing

@Suite struct BackupStateSnapshotTests {
    func support() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sbs-\(UUID().uuidString.prefix(8))")
    }

    @Test func liveDatabasesRestoreWithoutSidecarsAndAttachmentsKeepTheirBytes() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        let database = support.appendingPathComponent("runtime/services.sqlite")
        let schema = StateStore.Schema(version: 1, statements: [])
        let writer = try StateStore.open(database, schema: schema)
        try writer.write { try $0.setDocument(["invented-before"], key: "value") }
        for path in ["Captures/invented.sqlite", "Captures/invented.log", "runtime/jobs.log", "runtime/jobs.log.1", "mcp/audit/invented.log"] {
            let file = support.appendingPathComponent(path)
            try AtomicFile.makePrivateFolder(file.deletingLastPathComponent())
            try Data("invented bytes".utf8).write(to: file)
        }
        // The runtime's live IPC socket is transient state, not a document to copy.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(support.appendingPathComponent("mcp/mcp.sock").path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            for (index, byte) in bytes.enumerated() { raw[index] = byte }
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(bound == 0)
        let backup = Backup(support: support, key: "INVENTED-KEY", resticBinary: nil)
        var snapshot: URL?
        try backup.withStateSnapshot { copy in
            snapshot = copy
            #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("runtime/services.sqlite-wal").path))
            #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("runtime/services.sqlite-shm").path))
            #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("runtime/jobs.log").path))
            #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("runtime/jobs.log.1").path))
            #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("mcp/audit").path))
            #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("mcp/mcp.sock").path))
            #expect(!FileManager.default.fileExists(atPath: copy.appendingPathComponent("backup/run").path))
            for path in ["Captures/invented.sqlite", "Captures/invented.log"] {
                #expect(try Data(contentsOf: copy.appendingPathComponent(path)) == Data("invented bytes".utf8))
            }
            try writer.write { try $0.setDocument(["invented-after"], key: "value") }
            let restored = try StateStore.open(copy.appendingPathComponent("runtime/services.sqlite"), schema: schema)
            #expect(try restored.read { try $0.document([String].self, key: "value") } == ["invented-before"])
        }
        #expect(snapshot.map { !FileManager.default.fileExists(atPath: $0.path) } == true)
    }

    @Test func aSpecialFileFailsWithoutBlockingAndNoPartialCopyReachesRestic() throws {
        let support = support()
        defer { try? FileManager.default.removeItem(at: support) }
        try AtomicFile.makePrivateFolder(support)
        #expect(mkfifo(support.appendingPathComponent("invented-pipe").path, 0o600) == 0)
        let backup = Backup(support: support, key: "INVENTED-KEY", resticBinary: nil)
        var reached = false
        let began = Date()
        #expect(throws: (any Error).self) { try backup.withStateSnapshot { _ in reached = true } }
        #expect(!reached && Date().timeIntervalSince(began) < 2)
    }
}

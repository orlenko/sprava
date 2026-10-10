@testable import Services
import Darwin
import Foundation
import Testing

/// Every lease belongs to an invented temporary runtime, never a running Sprava installation.
@Suite struct LeaseTests {
    func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-lease-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test func aSecondLeaseIsRefusedAndClosingReleasesIt() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("runtime/lease")
        guard case .acquired(let first) = try Lease.acquire(at: url) else {
            Issue.record("the first lease was not acquired"); return
        }
        guard case .held(let owner) = try Lease.acquire(at: url) else {
            Issue.record("a second lease was acquired"); return
        }
        #expect(owner == getpid())
        #expect(first.inode > 0)
        _ = consume first
        guard case .acquired = try Lease.acquire(at: url) else {
            Issue.record("closing the lease did not release it"); return
        }
    }

    @Test func stalePIDTextDoesNotKeepALeaseHeld() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lease")
        try Data("12345\n".utf8).write(to: url, options: [])
        chmod(url.path, 0o600)
        guard case .acquired(let lease) = try Lease.acquire(at: url) else {
            Issue.record("stale text was treated as a held lease"); return
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "\(getpid())\n")
        _ = consume lease
    }

    @Test func linkedAndSharedFilesAreNeverTruncated() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.appendingPathComponent("invented-unrelated-file")
        let before = Data("invented unrelated bytes".utf8)
        try before.write(to: outside)
        chmod(outside.path, 0o600)
        let url = root.appendingPathComponent("lease")
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: outside)
        #expect(throws: (any Error).self) { try Lease.acquire(at: url) }
        try FileManager.default.removeItem(at: url)
        #expect(link(outside.path, url.path) == 0)
        #expect(throws: (any Error).self) { try Lease.acquire(at: url) }
        #expect(try Data(contentsOf: outside) == before)
    }

    @Test func specialAndWritableFilesAreRefusedWithoutWaiting() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("lease")
        #expect(mkfifo(url.path, 0o600) == 0)
        let start = Date()
        #expect(throws: (any Error).self) { try Lease.acquire(at: url) }
        #expect(Date().timeIntervalSince(start) < 1)
        try FileManager.default.removeItem(at: url)
        try Data("invented".utf8).write(to: url)
        chmod(url.path, 0o666)
        #expect(throws: (any Error).self) { try Lease.acquire(at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "invented")
    }

    @Test func unsafeAndLinkedRuntimeDirectoriesAreRefused() throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = root.appendingPathComponent("runtime")
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
        chmod(runtime.path, 0o777)
        #expect(throws: (any Error).self) { try Lease.acquire(at: runtime.appendingPathComponent("lease")) }
        #expect(!FileManager.default.fileExists(atPath: runtime.appendingPathComponent("lease").path))
        chmod(runtime.path, 0o700)
        let alias = root.appendingPathComponent("linked-runtime")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: runtime)
        #expect(throws: (any Error).self) { try Lease.acquire(at: alias.appendingPathComponent("lease")) }
        #expect(!FileManager.default.fileExists(atPath: runtime.appendingPathComponent("lease").path))
    }
}

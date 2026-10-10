@testable import SpravaKit
import Darwin
import Foundation
import Testing

@Suite struct StateDirectoryTests {
    func temporary() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("sprava-state-handle-\(UUID().uuidString)")
    }

    @Test func missingDirectoriesAreFreshAndWritesRoundTrip() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(try StateDirectory.open(base) == nil)
        let root = try #require(try StateDirectory.open(base, create: true))
        #expect(try root.directory("mcp") == nil)
        let folder = try #require(try root.directory("mcp", create: true))
        try folder.write(Data("invented".utf8), to: "clients.json")
        guard case .ok(let data) = try folder.read("clients.json") else { Issue.record("not read"); return }
        #expect(data == Data("invented".utf8))
        for name in ["", ".", "..", "../outside", "invalid\0name"] {
            #expect(throws: (any Error).self) { try folder.write(Data(), to: name) }
        }
    }

    @Test func linksAndInvalidParentsAreNotFreshDirectories() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        try AtomicFile.makePrivateFolder(base)
        let root = try #require(try StateDirectory.open(base))
        let link = base.appendingPathComponent("mcp")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: base.appendingPathComponent("missing"))
        #expect(throws: (any Error).self) { try root.directory("mcp", create: true) }
        #expect(throws: (any Error).self) { try StateDirectory.open(link) }
        try FileManager.default.removeItem(at: link)
        try Data("invented".utf8).write(to: link)
        #expect(throws: (any Error).self) { try root.directory("mcp") }
    }

    @Test(arguments: [false, true]) func directorySwapsCannotRedirectFileOperations(writing: Bool) throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("support")
        let root = try #require(try StateDirectory.open(support, create: true))
        let folder = try #require(try root.directory("mcp", create: true))
        let old = Data("invented old state".utf8), outside = Data("invented outside state".utf8)
        try folder.write(old, to: "clients.json")
        let otherRoot = try #require(try StateDirectory.open(base.appendingPathComponent("outside"), create: true))
        try otherRoot.write(outside, to: "clients.json")
        let moved = base.appendingPathComponent("moved")
        let swap = {
            try FileManager.default.moveItem(at: support.appendingPathComponent("mcp"), to: moved)
            try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("mcp"),
                                                       withDestinationURL: base.appendingPathComponent("outside"))
        }
        if writing {
            #expect(throws: (any Error).self) { try folder.write(Data("new".utf8), to: "clients.json", beforeOpen: swap) }
        } else {
            #expect(throws: (any Error).self) { try folder.read("clients.json", limit: 100, beforeOpen: swap) }
        }
        #expect(try Data(contentsOf: base.appendingPathComponent("outside/clients.json")) == outside)
        #expect(try Data(contentsOf: moved.appendingPathComponent("clients.json")) == old)
        #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path) == ["clients.json"])
    }

    @Test func replacedRootInvalidatesItsRetainedChildren() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("support")
        let root = try #require(try StateDirectory.open(support, create: true))
        let folder = try #require(try root.directory("mcp", create: true))
        try FileManager.default.moveItem(at: support, to: base.appendingPathComponent("moved"))
        try AtomicFile.makePrivateFolder(support)
        #expect(throws: (any Error).self) { try folder.read("clients.json") }
        #expect(throws: (any Error).self) { try folder.write(Data(), to: "clients.json") }
    }

    @Test func aMissingChildUnderAReplacedParentIsNeverFresh() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("support")
        let root = try #require(try StateDirectory.open(support, create: true))
        #expect(throws: (any Error).self) {
            try root.directory("mcp", create: false, beforeOpen: {
                try FileManager.default.moveItem(at: support, to: base.appendingPathComponent("moved"))
                try AtomicFile.makePrivateFolder(support)
            })
        }
    }

    @Test func failedCreationFlushesCannotBeBypassedByRetryingExistingDirectories() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        let root = try #require(try StateDirectory.open(base, create: true))
        let refusing = StateDirectory.Flush(directory: { _ in throw AtomicFile.Failure(step: "invented flush failure", code: EIO) })
        let refusedRoot = try #require(try StateDirectory.open(base, create: false, flush: refusing))
        #expect(throws: (any Error).self) { try refusedRoot.directory("mcp", create: true) }
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("mcp").path))
        #expect(throws: (any Error).self) { try refusedRoot.directory("mcp", create: true) }
        let child = try #require(try refusedRoot.directory("mcp", create: false))
        #expect(throws: (any Error).self) { try child.write(Data("invented".utf8), to: "clients.json") }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("mcp/clients.json").path))
        let nested = base.appendingPathComponent("new/child")
        #expect(throws: (any Error).self) { try StateDirectory.open(nested, create: true, flush: refusing) }
        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("new").path))
        #expect(try root.directory("mcp", create: true) != nil)
        #expect(try StateDirectory.open(nested, create: true) != nil)
    }

    @Test func failingFlushNeverDeletesAReplacementDirectory() throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try StateDirectory.open(base, create: true)
        let refusing = StateDirectory.Flush(directory: { _ in
            try FileManager.default.moveItem(at: base.appendingPathComponent("mcp"), to: base.appendingPathComponent("moved"))
            try AtomicFile.makePrivateFolder(base.appendingPathComponent("mcp"))
            throw AtomicFile.Failure(step: "invented swapped flush", code: EIO)
        })
        let root = try #require(try StateDirectory.open(base, create: false, flush: refusing))
        #expect(throws: (any Error).self) { try root.directory("mcp", create: true) }
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("moved").path))
        #expect(FileManager.default.fileExists(atPath: base.appendingPathComponent("mcp").path))
    }

    final class TemporaryName: @unchecked Sendable {
        let lock = NSLock()
        private var value: String?
        func set(_ value: String) { lock.lock(); defer { lock.unlock() }; self.value = value }
        func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test(arguments: [false, true]) func aPublishedTemporaryNameIsNoLongerOwnedByTheWriter(failFlush: Bool) throws {
        let base = temporary()
        defer { try? FileManager.default.removeItem(at: base) }
        _ = try StateDirectory.open(base, create: true)
        let name = TemporaryName()
        let replacement = Data("invented replacement".utf8)
        let flush = StateDirectory.Flush(directory: { _ in
            if let temporary = name.get() {
                try replacement.write(to: base.appendingPathComponent(temporary))
                if failFlush { throw AtomicFile.Failure(step: "invented post-rename flush", code: EIO) }
            }
        })
        let root = try #require(try StateDirectory.open(base, create: false, flush: flush))
        let write = { try root.write(Data("new".utf8), to: "state.json", beforeOpen: {}, beforePublish: { name.set($0) }) }
        if failFlush { #expect(throws: (any Error).self) { try write() } }
        else { try write() }
        let temporary = try #require(name.get())
        #expect(try Data(contentsOf: base.appendingPathComponent(temporary)) == replacement)
        #expect(try Data(contentsOf: base.appendingPathComponent("state.json")) == Data("new".utf8))
    }
}

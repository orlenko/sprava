@testable import BinderStore
import Foundation
import SpravaKit
import Testing

@Suite struct BinderIdentityAllocationTests {
    typealias Instance = BinderIdentityAllocations.FolderInstance
    let instance = Instance(device: 42, inode: 91, birthSeconds: 1_000, birthNanoseconds: 123)

    func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-allocation-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    @Test func lostReplyAndRestartKeepOnePendingIdentity() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.sqlite")
        let request = UUID()
        let first = try BinderIdentityAllocations(at: database)
        #expect(try first.pending(requestID: request) == nil)
        let saved = try first.begin(requestID: request, instance: instance)
        #expect(saved.binderID.uuidString.lowercased().utf8.dropFirst(14).first == UInt8(ascii: "4"))
        for _ in 0..<5 {
            let restarted = try BinderIdentityAllocations(at: database)
            #expect(try restarted.pending(requestID: request) == saved)
            #expect(try restarted.begin(requestID: request, instance: instance) == saved)
            #expect(try restarted.pending(requestID: UUID()) == nil)
        }
        // Only trusted pending state exists. No binder claim, directory or admitted capability was made.
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".sprava").path))
    }

    @Test func conflictingRequestsNeverOverwriteOrRemint() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let journal = try BinderIdentityAllocations(at: root.appendingPathComponent("state.sqlite"))
        let request = UUID(), otherRequest = UUID()
        let saved = try journal.begin(requestID: request, instance: instance)
        let other = Instance(device: 42, inode: 92, birthSeconds: 1_000, birthNanoseconds: 123)
        #expect(throws: BinderIdentityAllocations.Refused.self) {
            try journal.begin(requestID: request, instance: other)
        }
        #expect(throws: BinderIdentityAllocations.Refused.self) {
            try journal.begin(requestID: otherRequest, instance: instance)
        }
        #expect(try journal.pending(requestID: request) == saved)
        #expect(try journal.pending(requestID: otherRequest) == nil)
        let second = try journal.begin(requestID: otherRequest, instance: other)
        #expect(second.binderID != saved.binderID)
        #expect(throws: BinderIdentityAllocations.Refused.self) {
            try journal.begin(requestID: UUID(), instance: Instance(device: 0, inode: 0, birthSeconds: 0, birthNanoseconds: 0))
        }
    }

    @Test func independentConnectionsSerializeOneAllocation() async throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("state.sqlite")
        let left = try BinderIdentityAllocations(at: database)
        let right = try BinderIdentityAllocations(at: database)
        let request = UUID(), stamp = instance
        let replies = try await withThrowingTaskGroup(of: BinderIdentityAllocations.Pending.self) { group in
            for n in 0..<40 {
                let journal = n.isMultiple(of: 2) ? left : right
                group.addTask { try journal.begin(requestID: request, instance: stamp) }
            }
            var replies: [BinderIdentityAllocations.Pending] = []
            for try await reply in group { replies.append(reply) }
            return replies
        }
        #expect(replies.count == 40)
        let original = try #require(replies.first)
        #expect(replies.allSatisfy { $0 == original })
        #expect(try BinderIdentityAllocations(at: database).pending(requestID: request) == original)
    }

    @Test func damagedOrUnsupportedTrustedStateIsPreserved() throws {
        let root = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let damaged = root.appendingPathComponent("damaged.sqlite")
        let bytes = Data("invented damaged trusted state".utf8)
        try bytes.write(to: damaged)
        #expect(throws: (any Error).self) { try BinderIdentityAllocations(at: damaged) }
        #expect(try Data(contentsOf: damaged) == bytes)
        let future = root.appendingPathComponent("future.sqlite")
        let store = try StateStore.open(future, schema: .init(version: 2, statements: []))
        try store.write { try $0.setDocument("keep this invented record", key: "fixture") }
        #expect(throws: (any Error).self) { try BinderIdentityAllocations(at: future) }
        #expect(try store.read { try $0.document(String.self, key: "fixture") } == "keep this invented record")
    }
}

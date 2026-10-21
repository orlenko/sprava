@testable import BinderStore
import BinderFormat
import Darwin
import Foundation
import Testing

@Suite struct BinderIdentityClaimWriteTests {
    func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-claim-write-\(UUID())")
        try makeFolder(root)
        return root
    }

    func makeFolder(_ url: URL, mode: Int = 0o700) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: mode])
    }

    func begin(_ journal: BinderIdentityAllocations, request: UUID, folder: URL) throws -> BinderIdentityAllocations.Pending {
        try journal.begin(requestID: request, instance: .capture(folder))
    }

    @Test func missingIntentAndWrongInstanceCauseNoFolderWrites() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("new-folder"), other = root.appendingPathComponent("other-folder")
        try makeFolder(folder); try makeFolder(other)
        let journal = try BinderIdentityAllocations(at: root.appendingPathComponent("state.sqlite"))
        let writer = BinderIdentityClaimWriter(allocations: journal), request = UUID()
        #expect(throws: BinderIdentityClaimWriter.Refused.self) { try writer.writePending(requestID: request, in: folder) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
        let pending = try begin(journal, request: request, folder: folder)
        #expect(throws: BinderIdentityClaimWriter.Refused.self) { try writer.writePending(requestID: request, in: other) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: other.path).isEmpty)
        #expect(try journal.pending(requestID: request) == pending)
    }

    enum LostReply: Error { case afterPublication }
    @Test func lostPublicationReplyRecoversTheExactPendingClaim() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("new-folder"), database = root.appendingPathComponent("state.sqlite")
        try makeFolder(folder)
        let journal = try BinderIdentityAllocations(at: database), request = UUID()
        let intent = try begin(journal, request: request, folder: folder)
        let writer = BinderIdentityClaimWriter(allocations: journal)
        #expect(throws: LostReply.self) {
            try writer.writePending(requestID: request, in: folder, publish: { directory, bytes in
                try directory.createImmutable(bytes, to: "binder-identity.json")
                throw LostReply.afterPublication
            })
        }
        let file = folder.appendingPathComponent(".sprava/binder-identity.json")
        let bytes = try Data(contentsOf: file)
        var first = stat(); #expect(lstat(file.path, &first) == 0)
        #expect(first.st_mode & 0o7777 == 0o600)
        let restarted = try BinderIdentityAllocations(at: database)
        let recovered = try BinderIdentityClaimWriter(allocations: restarted).writePending(requestID: request, in: folder)
        #expect(recovered.binderID == intent.binderID.uuidString.lowercased())
        #expect(try restarted.pending(requestID: request) == intent)
        #expect(try Data(contentsOf: file) == bytes)
        var after = stat(); #expect(lstat(file.path, &after) == 0)
        #expect(after.st_ino == first.st_ino)
        // This is still an untrusted format claim. There is no admitted-binding or capability result.
        #expect(BinderIdentityClaim.read(in: folder) == .claim(recovered))
    }

    @Test func copiedAndForeignClaimsArePreservedWithoutAdmissionOrReminting() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("original"), copied = root.appendingPathComponent("copy")
        try makeFolder(folder)
        let journal = try BinderIdentityAllocations(at: root.appendingPathComponent("state.sqlite"))
        let writer = BinderIdentityClaimWriter(allocations: journal), request = UUID()
        let original = try begin(journal, request: request, folder: folder)
        let claim = try writer.writePending(requestID: request, in: folder)
        try FileManager.default.copyItem(at: folder, to: copied)
        #expect(throws: BinderIdentityClaimWriter.Refused.self) { try writer.writePending(requestID: request, in: copied) }
        // Even an erroneous upstream allocation cannot replace the copied foreign claim with its new UUID.
        let otherRequest = UUID()
        let other = try begin(journal, request: otherRequest, folder: copied)
        #expect(other.binderID != original.binderID)
        #expect(throws: (any Error).self) { try writer.writePending(requestID: otherRequest, in: copied) }
        #expect(BinderIdentityClaim.read(in: copied) == .claim(claim))
        #expect(BinderIdentityClaim.read(in: folder) == .claim(claim))
        #expect(try journal.pending(requestID: request) == original)
    }

    @Test(arguments: ["link", "public-directory", "fifo", "oversized"])
    func unsafeStateAndExistingClaimsAreUntouched(kind: String) throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("candidate"), outside = root.appendingPathComponent("outside")
        try makeFolder(folder); try makeFolder(outside)
        let state = folder.appendingPathComponent(".sprava"), file = state.appendingPathComponent("binder-identity.json")
        let journal = try BinderIdentityAllocations(at: root.appendingPathComponent("state.sqlite")), request = UUID()
        _ = try begin(journal, request: request, folder: folder)
        if kind == "link" {
            try FileManager.default.createSymbolicLink(at: state, withDestinationURL: outside)
        } else {
            try makeFolder(state, mode: kind == "public-directory" ? 0o755 : 0o700)
            if kind == "public-directory" { #expect(chmod(state.path, 0o755) == 0) }
            if kind == "fifo" { #expect(mkfifo(file.path, 0o600) == 0) }
            if kind == "oversized" {
                try Data(repeating: 32, count: 20 * 1024).write(to: file)
                #expect(chmod(file.path, 0o600) == 0)
            }
        }
        #expect(throws: (any Error).self) {
            try BinderIdentityClaimWriter(allocations: journal).writePending(requestID: request, in: folder)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        if kind == "public-directory" { #expect(!FileManager.default.fileExists(atPath: file.path)) }
        if kind == "oversized" { #expect(try Data(contentsOf: file) == Data(repeating: 32, count: 20 * 1024)) }
        if kind == "fifo" { var info = stat(); #expect(lstat(file.path, &info) == 0); #expect(info.st_mode & S_IFMT == S_IFIFO) }
    }

    @Test func busyWriterRetainsItsIntentForTheLaterRetry() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("candidate")
        try makeFolder(folder)
        let journal = try BinderIdentityAllocations(at: root.appendingPathComponent("state.sqlite")), request = UUID()
        let pending = try begin(journal, request: request, folder: folder)
        let descriptor = open(folder.appendingPathComponent(".teka.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        #expect(descriptor >= 0)
        guard descriptor >= 0 else { return }
        defer { flock(descriptor, LOCK_UN); close(descriptor) }
        #expect(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let writer = BinderIdentityClaimWriter(allocations: journal)
        #expect(throws: TekaStore.Busy.self) { try writer.writePending(requestID: request, in: folder, lockTimeout: 0) }
        #expect(try journal.pending(requestID: request) == pending)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(".sprava").path))
        #expect(flock(descriptor, LOCK_UN) == 0)
        #expect(try writer.writePending(requestID: request, in: folder).binderID == pending.binderID.uuidString.lowercased())
    }
}

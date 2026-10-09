@testable import Backup
import Darwin
import Foundation
import SpravaKit
import Testing

/// Regressions from the fifth calibrated review of the restacked Backup layer: metadata-only changes count as
/// changes (Finder tags, permissions), and a deletion forgotten long ago is never forgotten again over newer backups.
/// Repositories and binders live in temporary folders only. Invented data only.
@Suite(.serialized) struct BackupLayerReview5Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()
    let letter = "correspondence/notary/letter.pdf"
    let tags = "com.apple.metadata:_kMDItemUserTags"

    func setAttribute(_ name: String, _ value: String, on url: URL) {
        let bytes = Array(value.utf8)
        #expect(setxattr(url.path, name, bytes, bytes.count, 0, 0) == 0)
    }

    func attribute(_ name: String, of url: URL) -> String? {
        let size = getxattr(url.path, name, nil, 0, 0, 0)
        guard size >= 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard getxattr(url.path, name, &buffer, size, 0, 0) == size else { return nil }
        return String(decoding: buffer, as: UTF8.self)
    }

    // MARK: - 1. Metadata-only changes

    @Test func theManifestSeesAttributesAndPermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-metadata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("documents"), withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("documents/invented.pdf")
        try Data("invented".utf8).write(to: file)
        let plain = try Backup.manifest(folder)

        setAttribute(tags, "invented tag", on: file)
        let tagged = try Backup.manifest(folder)
        #expect(tagged["documents/invented.pdf"] != plain["documents/invented.pdf"])
        setAttribute("com.apple.ResourceFork", "invented fork", on: file)
        #expect(try Backup.manifest(folder)["documents/invented.pdf"] != tagged["documents/invented.pdf"])

        let before = try Backup.manifest(folder)
        #expect(chmod(file.path, 0o600) == 0)
        #expect(try Backup.manifest(folder)["documents/invented.pdf"] != before["documents/invented.pdf"])
        // A folder's own attributes count too.
        let folderBefore = try Backup.manifest(folder)["documents"]
        setAttribute("com.example.invented", "invented note", on: folder.appendingPathComponent("documents"))
        #expect(try Backup.manifest(folder)["documents"] != folderBefore)
        // What macOS keeps itself, and a restore cannot write back, is left out.
        #expect(Backup.volatileAttributes.isSuperset(of: ["com.apple.provenance", "com.apple.macl"]))
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aTagAddedAfterARestoreIsOffloadedAndComesBack() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let first) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        let restored = try b.restore(first.backupID, now: now)
        // Only a Finder tag changes.
        setAttribute(tags, "invented tag", on: restored.appendingPathComponent(letter))
        guard case .done(let again) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(again.snapshot != first.snapshot, "the old snapshot, without the tag, was reused")
        let back = try b.restore(again.backupID, now: now)
        #expect(attribute(tags, of: back.appendingPathComponent(letter)) == "invented tag")
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aPermissionChangeAfterARestoreIsOffloaded() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        guard case .done(let first) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        let restored = try b.restore(first.backupID, now: now)
        #expect(chmod(restored.appendingPathComponent(letter).path, 0o600) == 0)
        guard case .done(let again) = try b.offload(restored, deviceID: "dev", confirmOpenItems: true, now: now) else {
            Issue.record("not done"); return
        }
        #expect(again.snapshot != first.snapshot)
        let back = try b.restore(again.backupID, now: now)
        var info = stat()
        #expect(lstat(back.appendingPathComponent(letter).path, &info) == 0 && info.st_mode & 0o777 == 0o600)
    }

    // MARK: - 2. A deletion forgotten long ago is never forgotten again

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func anOldDeletionAskedForAgainLeavesNewerBackups() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        try b.backUp(e.folder, now: now)
        try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
        #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: now))

        // Long after, the finished request has left the list; a new letter is filed at the same path and backed up.
        let later = now.addingTimeInterval(40 * 86_400)
        try b.forgetPending(now: later)
        #expect(try b.state().forgetting.isEmpty)
        #expect(try b.state().forgotten.map(\.request) == ["invented-deletion-1"])
        try Data("invented new letter".utf8).write(to: e.folder.appendingPathComponent(letter))
        let snap = try #require(try b.backUp(e.folder, now: later).snapshot)

        // The old deletion asked for again is answered from its tombstone; the new letter's backup stays.
        #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: later))
        #expect(try b.state().forgetting.isEmpty)
        #expect(try b.engine(e.primary.path).files(snap).contains(letter))
        // The same id for another path is refused.
        #expect(throws: Backup.Failure.self) {
            try b.forgetDocument(in: e.folder, path: "correspondence/notary/other.pdf", request: "invented-deletion-1", now: later)
        }
        // A new deletion of the new letter is a request of its own, and does forget it.
        #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-2", now: later))
        #expect(try !b.engine(e.primary.path).snapshots(tag: "binder:\(Backup.backupID(e.folder))").contains { $0.id == snap })
    }
}

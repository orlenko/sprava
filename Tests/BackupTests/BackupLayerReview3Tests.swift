@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit
import Testing

/// Regressions from the first calibrated review of the restacked Backup layer: a restore retried after its binder
/// went live, copied binders that share a backup id, rewrites cut off before their new ids were saved, the second
/// backup's scheduled check, and the size "Offload again" records. Repositories and binders live in temporary
/// folders only. Invented data only.
@Suite(.serialized) struct BackupLayerReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()
    let letter = "correspondence/notary/letter.pdf"

    func offloaded(_ e: BugbotBackupTests.Env, _ b: Backup) throws -> Backup.Offloaded {
        guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            throw Backup.Failure(message: "not done")
        }
        return record
    }

    // MARK: - 1. A restore retried after its binder went live never restores over it

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aRetriedRestoreKeepsWhatThePersonApproved() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let record = try offloaded(e, b)
        // The restore put the binder on the Shelf, then its last state save failed: its state is unwritable.
        var stalled = b
        stalled.atStep = { step in
            if step == "restore.shelved" { chmod(b.dir.path, 0o500) }
        }
        #expect(throws: (any Error).self) { _ = try stalled.restore(record.backupID, now: now) }
        chmod(b.dir.path, 0o700)
        #expect(ShelfStore(supportDirectory: e.support).pickedFolders().contains { $0.standardizedFileURL == e.folder.standardizedFileURL })

        // The binder is live: the person changes a document and approves an entry.
        try Data("invented edit".utf8).write(to: e.folder.appendingPathComponent(letter))
        try bb.addLogEntry(e.folder, "invented approval")
        #expect(try b.restore(record.backupID, now: now) == e.folder.standardizedFileURL)
        #expect(try String(contentsOf: e.folder.appendingPathComponent(letter), encoding: .utf8) == "invented edit")
        let titles = (Teka.read(e.folder).catalog?["processing_log"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
        #expect(titles.contains("invented approval"))
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().restoredContents.isEmpty)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func anOlderStoppedRestoreOnTheShelfOnlyFinishesItsRecords() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let record = try offloaded(e, b)
        _ = try b.restore(record.backupID, now: now)
        // State as an older Sprava left it: the binder on the Shelf, the restore still recorded as under way.
        var st = try b.state()
        st.offloaded = [record]
        st.restoring[record.backupID] = e.folder.standardizedFileURL.path
        st.restored[record.backupID] = nil
        try b.save(st)
        try Data("invented edit".utf8).write(to: e.folder.appendingPathComponent(letter))

        _ = try b.restore(record.backupID, now: now)
        #expect(try String(contentsOf: e.folder.appendingPathComponent(letter), encoding: .utf8) == "invented edit")
        #expect(try b.offloaded().isEmpty)
        #expect(try b.state().restoring.isEmpty)
        // No baseline: the binder may have changed, so the next offload takes a new snapshot.
        #expect(try b.state().restored[record.backupID] == nil)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func nothingIsRestoredIntoABinderOnTheShelf() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let record = try offloaded(e, b)
        // Another binder now lives where the record would restore to, and is on the Shelf (an empty folder, so only
        // the Shelf says it is a binder).
        try FileManager.default.createDirectory(at: e.folder, withIntermediateDirectories: true)
        try ShelfStore(supportDirectory: e.support).add(e.folder)
        do {
            _ = try b.restore(record.backupID, now: now)
            Issue.record("restored into a binder on the Shelf")
        } catch {
            #expect("\(error)".contains("is a binder on the Shelf"))
        }
        #expect(try b.offloaded() == [record])
        #expect(try FileManager.default.contentsOfDirectory(atPath: e.folder.path).isEmpty)
    }

    // MARK: - 2. Copied binders never share backups

    func copy(_ e: BugbotBackupTests.Env) throws -> URL {
        let copy = e.folder.deletingLastPathComponent().appendingPathComponent("invented-copy", isDirectory: true)
        try FileManager.default.copyItem(at: e.folder, to: copy)
        return copy
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aCopyIsNotBackedUpOrForgottenUnderTheOriginalsID() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        let copy = try copy(e)

        #expect(throws: Backup.SharedBackupID.self) { try b.backUp(copy, now: now) }
        #expect(throws: Backup.SharedBackupID.self) { try b.forgetDocument(in: copy, path: letter, now: now) }
        #expect(throws: Backup.SharedBackupID.self) { try b.drill(copy, now: now) }
        #expect(try b.state().forgetting.isEmpty)
        #expect(try b.state().binders[id]?.path == e.folder.standardizedFileURL.path)
        #expect(try b.state().binders[id]?.error == nil)
        // The scheduled run says which folder it skipped, and why.
        let m = b.maintain(rows: Shelf.rows(registry: nil, picked: [e.folder, copy]), deviceID: "dev", now: now.addingTimeInterval(7200))
        #expect(m.sharedBackupIDs == [copy.standardizedFileURL.path])
        let message = "\(Backup.SharedBackupID(folder: copy.path, holder: e.folder.path))"
        #expect(message.contains("give it its own backup id"))

        // The original keeps its id; the copy gets its own and is then backed up on its own.
        #expect(throws: Backup.Failure.self) { try b.giveOwnBackupID(e.folder) }
        let own = try b.giveOwnBackupID(copy)
        #expect(own != id)
        #expect(try Backup.backupID(copy) == own)
        #expect(try Backup.backupID(e.folder) == id)
        try b.backUp(copy, now: now)
        #expect(try b.state().binders[own]?.path == copy.standardizedFileURL.path)
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aMovedBinderTakesItsRecordAlong() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        try b.backUp(e.folder, now: now)
        let id = try Backup.backupID(e.folder)
        let moved = e.folder.deletingLastPathComponent().appendingPathComponent("invented-moved", isDirectory: true)
        try FileManager.default.moveItem(at: e.folder, to: moved)
        try b.backUp(moved, now: now)
        #expect(try b.state().binders[id]?.path == moved.standardizedFileURL.path)
    }

    // MARK: - 3. A rewrite cut off before its new ids were saved is reconciled

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func aRewriteCutOffBeforeItsIDsWereSavedStillRestores() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let record = try offloaded(e, b)
        // restic rewrote the mirror and forgot the originals, then Sprava stopped before saving the new ids: the disk
        // as that crash left it.
        let images = BackupCrashTests.Images([e.base, e.folder.deletingLastPathComponent()])
        var cut = b
        cut.atStep = { images.take($0) }
        _ = try cut.forget(record.backupID, path: letter, now: now)
        try images.restore("forget.rewritten#1")
        defer { try? FileManager.default.removeItem(at: images.store) }
        let stale = try b.state()
        #expect(stale.rewrites.count == 1)
        #expect(stale.offloaded.first?.snapshot == record.snapshot)
        #expect(try !b.engine(e.primary.path).snapshots().contains { $0.id == record.snapshot })

        // A restore reconciles first, through the new snapshots' `original` ids, and works.
        let restored = try b.restore(record.backupID, now: now)
        #expect(!FileManager.default.fileExists(atPath: restored.appendingPathComponent(letter).path))
        #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent("catalog.json").path))
        #expect(try b.state().rewrites.isEmpty)
    }

    // MARK: - 4. The second backup is checked too, with its own date

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func theSecondBackupIsCheckedOnItsOwn() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        try b.check(readData: false, now: now)
        #expect(try b.state().lastCheck != nil)
        #expect(try b.state().lastSecondCheck != nil)
        #expect(b.status(checkUpload: false).lastSecondCheck != nil)

        // A second backup that is away fails the check and stays due; the mirror's check still counts.
        let later = now.addingTimeInterval(8 * 86_400)
        let away = e.second.deletingLastPathComponent().appendingPathComponent("invented-away")
        try FileManager.default.moveItem(at: e.second, to: away)
        do {
            try b.check(readData: false, now: later)
            Issue.record("a missing second backup passed its check")
        } catch {
            #expect("\(error)".contains("the second backup"))
        }
        #expect(try b.state().lastCheck == ISOTime.string(later))
        #expect(try b.state().lastSecondCheck == ISOTime.string(now))
        let m = b.maintain(rows: [], deviceID: "dev", now: later.addingTimeInterval(3600))
        #expect(m.failedParts.contains("check"))
        try FileManager.default.moveItem(at: away, to: e.second)
    }

    // MARK: - restic runs from every cooperative thread at once never wait on each other

    @Test(.enabled(if: BugbotBackupTests.hasRestic), .timeLimit(.minutes(2))) func manyResticRunsAtOnceAllFinish() async throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let r = try b.engine(e.primary.path)
        // More runs than cooperative threads, each blocking its thread until restic exits: a run that needed another
        // thread to read restic's output would wait forever.
        let n = ProcessInfo.processInfo.activeProcessorCount * 3
        let ok = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<n { group.addTask { (try? r.snapshots()) != nil } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(ok == n)
        // restic's error output still reaches the message.
        let missing = Restic(binary: r.binary, repository: e.base.appendingPathComponent("invented-missing"), key: r.key, support: e.support)
        do {
            _ = try missing.snapshots()
            Issue.record("a missing repository listed snapshots")
        } catch {
            #expect("\(error)".hasPrefix("restic snapshots: ") && !"\(error)".hasSuffix("exit 1"))
        }
    }

    // MARK: - 5. "Offload again" records the binder's size

    @Test(.enabled(if: BugbotBackupTests.hasRestic)) func offloadAgainRecordsTheSize() throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let first = try offloaded(e, b)
        #expect(first.bytes > 0)
        _ = try b.restore(first.backupID, now: now)
        let again = try offloaded(e, b)
        #expect(again.snapshot == first.snapshot)
        #expect(again.bytes == first.bytes)
    }
}

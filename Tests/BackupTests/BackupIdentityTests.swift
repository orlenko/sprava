@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Backup identity and scope, case by case: no operation ever touches another binder's backups, or a snapshot made
/// after the request that started it. Copies before and after an offload, restores that are partial or meet another
/// binder, and forgetting with a repository away, a new document filed at the same path, or destinations changed after
/// a restore. Repositories and binders live in temporary folders only. Invented data only.
@Suite struct BackupIdentityTests {
    static let now = Date(timeIntervalSince1970: 1_791_360_000)
    var now: Date { Self.now }
    let bb = BugbotBackupTests()
    static let letter = "correspondence/notary/letter.pdf"
    var letter: String { Self.letter }

    enum Case: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case copyBeforeOffload, copyAfterRestore, partialRestoreOnTheShelf, anotherBinderOnTheShelf,
             forgetWithARepositoryAway, forgetAfterDestinationsChanged
        var testDescription: String { rawValue }
    }

    /// Every snapshot of every binder in a repository, with whether it holds `path`.
    func holding(_ b: Backup, _ repo: URL, _ path: String) throws -> [String: Bool] {
        let r = try b.engine(repo.path)
        var out: [String: Bool] = [:]
        for s in try r.snapshots() { out[s.id] = try r.files(s.id).contains(path) }
        return out
    }

    func message(_ body: () throws -> Void) -> String {
        do { try body() } catch { return "\(error)" }
        return ""
    }

    func offload(_ b: Backup, _ folder: URL) throws -> Backup.Offloaded {
        guard case .done(let record) = try b.offload(folder, deviceID: "dev", confirmOpenItems: true, now: now) else {
            throw Backup.Failure(message: "not done")
        }
        return record
    }

    /// Another binder in the same repositories, with a file at the same path, whose backups nothing here may touch.
    func bystander(_ b: Backup) throws -> URL {
        let other = try makeTeka(fixture: "sprava-v0", folderName: "invented-bystander")
        try TekaStore(folder: other).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        try FileManager.default.createDirectory(at: other.appendingPathComponent("correspondence/notary"), withIntermediateDirectories: true)
        try Data("invented bystander letter".utf8).write(to: other.appendingPathComponent(letter))
        try b.backUp(other, now: now)
        return other
    }

    @Test(.enabled(if: BugbotBackupTests.hasRestic), arguments: Case.allCases)
    func identityAndScope(_ c: Case) throws {
        let e = try bb.env()
        let b = try bb.configured(e)
        let other = try bystander(b)
        let otherID = try Backup.backupID(other)
        let otherSnapshots = try Set(b.engine(e.primary.path).snapshots(tag: "binder:\(otherID)").map(\.id))
        defer {
            // Whatever happened, the other binder's backups are as they were.
            let now = (try? Set(b.engine(e.primary.path).snapshots(tag: "binder:\(otherID)").map(\.id))) ?? []
            #expect(now == otherSnapshots, "\(c): another binder's backups changed")
        }

        switch c {
        case .copyBeforeOffload:
            // A copy made, with the binder's backup id, before the binder left: once it has, the copy must not take
            // the id. (Under another parent, so its folder name still matches its catalog.)
            _ = try Backup.backupID(e.folder)
            let copy = e.base.appendingPathComponent("copies/\(e.folder.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: e.folder, to: copy)
            let record = try offload(b, e.folder)
            let before = try holding(b, e.primary, letter)
            #expect(throws: Backup.SharedBackupID.self) { try b.backUp(copy, now: now) }
            #expect(throws: Backup.SharedBackupID.self) { try b.forgetDocument(in: copy, path: letter, now: now) }
            #expect(throws: Backup.SharedBackupID.self) { _ = try b.offload(copy, deviceID: "dev", confirmOpenItems: true, now: now) }
            #expect(try holding(b, e.primary, letter) == before)
            #expect(try b.state().forgetting.isEmpty)
            // Given its own id, the copy is backed up apart; the offloaded binder still restores whole.
            let own = try b.giveOwnBackupID(copy)
            try b.backUp(copy, now: now)
            #expect(try b.state().binders[own]?.path == copy.standardizedFileURL.path)
            try FileManager.default.removeItem(at: copy)
            let restored = try b.restore(record.backupID, now: now)
            #expect(FileManager.default.fileExists(atPath: restored.appendingPathComponent(letter).path))

        case .copyAfterRestore:
            let record = try offload(b, e.folder)
            _ = try b.restore(record.backupID, now: now)
            let copy = e.folder.deletingLastPathComponent().appendingPathComponent("invented-copy", isDirectory: true)
            try FileManager.default.copyItem(at: e.folder, to: copy)
            let before = try holding(b, e.primary, letter)
            #expect(throws: Backup.SharedBackupID.self) { try b.backUp(copy, now: now) }
            #expect(throws: Backup.SharedBackupID.self) { try b.forgetDocument(in: copy, path: letter, now: now) }
            #expect(try holding(b, e.primary, letter) == before)
            try b.backUp(e.folder, now: now)

        case .partialRestoreOnTheShelf, .anotherBinderOnTheShelf:
            let record = try offload(b, e.folder)
            if c == .partialRestoreOnTheShelf {
                // A restore stopped partway, and the person put the partial folder on the Shelf: a document is missing.
                _ = try b.restore(record.backupID, now: now)
                try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
            } else {
                // Another binder now lives where the record restores to.
                let unrelated = try makeTeka(fixture: "sprava-v0")
                try TekaStore(folder: unrelated).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
                _ = try Backup.backupID(unrelated)
                try FileManager.default.moveItem(at: unrelated, to: e.folder)
                try ShelfStore(supportDirectory: e.support).add(e.folder)
            }
            // As an older Sprava would have left it: the restore still recorded as under way into that folder.
            var st = try b.state()
            st.offloaded = [record]
            st.restoring[record.backupID] = e.folder.standardizedFileURL.path
            st.restored[record.backupID] = nil
            try b.save(st)
            let before = try Backup.manifest(e.folder)

            let failed = message { _ = try b.restore(record.backupID, now: now) }
            #expect(failed.contains("is on the Shelf but"), "\(c): \(failed)")
            #expect(failed.contains(c == .partialRestoreOnTheShelf ? "lacks 1 of" : "is another binder"), "\(c): \(failed)")
            #expect(try b.offloaded() == [record])
            #expect(try Backup.manifest(e.folder) == before, "\(c): the folder was written into")

        case .forgetWithARepositoryAway:
            // Offloaded and restored, so both repositories hold the letter; it is deleted for good from the binder.
            let record = try offload(b, e.folder)
            _ = try b.restore(record.backupID, now: now)
            let id = record.backupID
            try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
            let away = e.second.deletingLastPathComponent().appendingPathComponent("invented-away")
            try FileManager.default.moveItem(at: e.second, to: away)
            #expect(try b.forgetDocument(in: e.folder, path: letter, now: now) == false)
            let pending = try #require(try b.state().forgetting.first)
            #expect(pending.scopes.first { $0.repository == e.primary.path }?.done == true)
            #expect(pending.scopes.first { $0.repository == e.second.path }?.done == false)

            // A new document is filed at the same path and backed up while the second backup is away.
            try Data("invented new letter".utf8).write(to: e.folder.appendingPathComponent(letter))
            let later = try #require(try b.backUp(e.folder, now: now.addingTimeInterval(3600)).snapshot)
            try FileManager.default.moveItem(at: away, to: e.second)
            let m = b.maintain(rows: [], deviceID: "dev", now: now.addingTimeInterval(7200))
            #expect(!m.failedParts.contains("forget"))
            #expect(try b.state().forgetting.first?.done != nil)
            // The later snapshot, and the new document in it, are untouched; every earlier one is without the letter.
            let primary = try holding(b, e.primary, letter)
            #expect(primary[later] == true, "the later snapshot was rewritten")
            let earlier = try b.engine(e.primary.path).snapshots(tag: "binder:\(id)").filter { $0.id != later }
            #expect(!earlier.isEmpty && earlier.allSatisfy { primary[$0.id] == false })
            #expect(try holding(b, e.second, letter).values.allSatisfy { !$0 })

        case .forgetAfterDestinationsChanged:
            let record = try offload(b, e.folder)
            _ = try b.restore(record.backupID, now: now)
            try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
            // The person moves both backups to new places; the old ones still hold the letter.
            let newPrimary = e.base.appendingPathComponent("icloud/Sprava Backup 2", isDirectory: true)
            let newSecond = e.base.appendingPathComponent("external/Sprava Second 2", isDirectory: true)
            try b.setUp(primary: newPrimary, iCloudKeychain: false)
            try b.setSecond(newSecond)
            #expect(try b.forgetDocument(in: e.folder, path: letter, now: now))
            let scopes = try #require(try b.state().forgetting.first?.scopes).map(\.repository)
            #expect(Set(scopes).isSuperset(of: [e.primary.path, e.second.path, newPrimary.path, newSecond.path]))
            let id = record.backupID
            for repo in [e.primary, e.second] {
                let held = try holding(b, repo, letter)
                let mine = try b.engine(repo.path).snapshots(tag: "binder:\(id)").map(\.id)
                #expect(!mine.isEmpty && mine.allSatisfy { held[$0] == false }, "\(repo.lastPathComponent) still holds the letter")
            }
        }
    }
}

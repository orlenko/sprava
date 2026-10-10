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
        case copyBeforeOffload, copyAfterRestore, copyAfterRestoringElsewhere, workPutWhereARestoreIsGoing, partialRestoreOnTheShelf,
             anotherBinderOnTheShelf,
             forgetWithARepositoryAway, aSecondDeletionAtTheSamePath, forgetAfterDestinationsChanged,
             forgetAfterPrimaryChanged, forgetAfterDrillAndPrimaryChanged
        var testDescription: String { rawValue }
    }

    /// Why a backup id has no owner, or nil when it has one: an offloaded record, an offload or a restore under way,
    /// or a recorded folder that still holds the id. A copy can take an id only in such a gap (`Backup.claim`).
    static func ownerGap(_ b: Backup, _ id: String) -> String? {
        guard let st = try? b.state() else { return "the state cannot be read" }
        if st.offloaded.contains(where: { $0.backupID == id }) || st.offloads[id] != nil || st.restoring[id] != nil
            || st.restoredContents[id] != nil { return nil }
        guard let path = st.binders[id]?.path else { return "no folder is recorded for \(id)" }
        let holds = (try? Backup.storedBackupID(URL(fileURLWithPath: path, isDirectory: true))) == id
        return holds ? nil : "\(path) no longer holds \(id), and nothing else reserves it"
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
        let id = try Backup.backupID(e.folder)
        defer {
            // Whatever happened, the other binder's backups are as they were, and both ids still have an owner.
            let now = (try? Set(b.engine(e.primary.path).snapshots(tag: "binder:\(otherID)").map(\.id))) ?? []
            #expect(now == otherSnapshots, "\(c): another binder's backups changed")
            #expect(Self.ownerGap(b, id) == nil, "\(c): \(Self.ownerGap(b, id) ?? "")")
            #expect(Self.ownerGap(b, otherID) == nil, "\(c): \(Self.ownerGap(b, otherID) ?? "")")
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
            #expect(throws: Backup.SharedBackupID.self) { try b.forgetDocument(in: copy, path: letter, request: "invented-deletion-1", now: now) }
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
            #expect(throws: Backup.SharedBackupID.self) { try b.forgetDocument(in: copy, path: letter, request: "invented-deletion-1", now: now) }
            #expect(try holding(b, e.primary, letter) == before)
            try b.backUp(e.folder, now: now)

        case .copyAfterRestoringElsewhere:
            // Restored into another place, then copied before that place's first backup: the restored folder owns the
            // id from the moment the restore ends.
            let record = try offload(b, e.folder)
            let elsewhere = e.base.appendingPathComponent("restored/\(e.folder.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(try b.restore(record.backupID, to: elsewhere, now: now) == elsewhere.standardizedFileURL)
            #expect(Self.ownerGap(b, id) == nil)
            #expect(try b.state().binders[id]?.path == elsewhere.standardizedFileURL.path)
            let copy = e.base.appendingPathComponent("copies/\(e.folder.lastPathComponent)", isDirectory: true)
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: elsewhere, to: copy)
            let before = try holding(b, e.primary, letter)
            #expect(throws: Backup.SharedBackupID.self) { try b.backUp(copy, now: now) }
            #expect(throws: Backup.SharedBackupID.self) {
                try b.forgetDocument(in: copy, path: letter, request: "invented-deletion-1", now: now)
            }
            #expect(try holding(b, e.primary, letter) == before)
            // A copy given its own id has an owner from the save before it holds it.
            let own = try b.giveOwnBackupID(copy)
            #expect(Self.ownerGap(b, own) == nil)
            #expect(try b.state().binders[own]?.path == copy.standardizedFileURL.path)

        case .aSecondDeletionAtTheSamePath:
            // A letter is deleted for good while the second backup is away; a new letter is filed at the same path,
            // backed up, and deleted for good too, then a third is filed and backed up. Each deletion forgets only
            // the snapshots made before it, and the third letter stays.
            let record = try offload(b, e.folder)
            _ = try b.restore(record.backupID, now: now)
            try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
            let away = e.second.deletingLastPathComponent().appendingPathComponent("invented-away")
            try FileManager.default.moveItem(at: e.second, to: away)
            #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: now) == false)
            try Data("invented second letter".utf8).write(to: e.folder.appendingPathComponent(letter))
            let second = try #require(try b.backUp(e.folder, now: now.addingTimeInterval(3600)).snapshot)
            try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
            #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-2", now: now) == false)
            #expect(try b.state().forgetting.count == 2)
            // Asking again for the first deletion retries it; it adds no request.
            #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: now) == false)
            #expect(try b.state().forgetting.count == 2)
            try Data("invented third letter".utf8).write(to: e.folder.appendingPathComponent(letter))
            let third = try #require(try b.backUp(e.folder, now: now.addingTimeInterval(7200)).snapshot)
            try FileManager.default.moveItem(at: away, to: e.second)
            _ = b.maintain(rows: [], deviceID: "dev", now: now.addingTimeInterval(9000))
            #expect(try b.state().forgetting.allSatisfy { $0.done != nil })
            let primary = try holding(b, e.primary, letter)
            #expect(primary[third] == true, "the snapshot made after both deletions was rewritten")
            #expect(primary[second] == nil, "the second letter's snapshot still holds it")
            let mine = try b.engine(e.primary.path).snapshots(tag: "binder:\(id)").map(\.id).filter { $0 != third }
            #expect(!mine.isEmpty && mine.allSatisfy { primary[$0] == false })
            #expect(try holding(b, e.second, letter).values.allSatisfy { !$0 })

        case .workPutWhereARestoreIsGoing:
            // A restore stops (a crash) once started, and again once its files are staged; each time the person puts
            // work of their own where the binder is going. A retry never overwrites it, and finishes once it is moved.
            let record = try offload(b, e.folder)
            let images = BackupCrashTests.Images([e.base, e.folder.deletingLastPathComponent()])
            defer { try? FileManager.default.removeItem(at: images.store) }
            var watched = b
            watched.atStep = { images.take($0) }
            _ = try watched.restore(record.backupID, now: now)
            for key in ["restore.started#1", "restore.contents#1"] {
                try images.restore(key)
                let work = e.folder.appendingPathComponent(letter)
                try FileManager.default.createDirectory(at: work.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("invented new work".utf8).write(to: work)
                let failed = message { _ = try b.restore(record.backupID, now: now) }
                #expect(failed.contains(key == "restore.started#1" ? "already exists there" : "something was put at"), "\(key): \(failed)")
                #expect(try String(contentsOf: work, encoding: .utf8) == "invented new work", "\(key): the person's work was overwritten")
                #expect(try b.offloaded() == [record], "\(key)")
                // Once the work is moved away, the retry finishes.
                let moved = e.base.appendingPathComponent("invented-moved-work-\(key.prefix(13))")
                try FileManager.default.moveItem(at: e.folder, to: moved)
                _ = try b.restore(record.backupID, now: now)
                #expect(try String(contentsOf: e.folder.appendingPathComponent(letter), encoding: .utf8) == "invented letter", "\(key)")
                #expect(try b.offloaded().isEmpty, "\(key)")
            }

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
            #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: now) == false)
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
            #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: now))
            let scopes = try #require(try b.state().forgetting.first?.scopes).map(\.repository)
            #expect(Set(scopes).isSuperset(of: [e.primary.path, e.second.path, newPrimary.path, newSecond.path]))
            let id = record.backupID
            for repo in [e.primary, e.second] {
                let held = try holding(b, repo, letter)
                let mine = try b.engine(repo.path).snapshots(tag: "binder:\(id)").map(\.id)
                #expect(!mine.isEmpty && mine.allSatisfy { held[$0] == false }, "\(repo.lastPathComponent) still holds the letter")
            }

        case .forgetAfterPrimaryChanged:
            // An ordinary live-binder snapshot remains in an old mirror after the person chooses a new one. Its
            // repository stays with the binder's record, so expunging a document reaches the old copy too.
            _ = try b.backUp(e.folder, now: now)
            let oldPrimary = e.primary
            let newPrimary = e.base.appendingPathComponent("icloud/Sprava Backup 2", isDirectory: true)
            try b.setUp(primary: newPrimary, iCloudKeychain: false)
            try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
            #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: now))
            let scopes = try #require(try b.state().forgetting.first?.scopes).map(\.repository)
            #expect(Set(scopes).isSuperset(of: [oldPrimary.path, newPrimary.path]))
            let held = try holding(b, oldPrimary, letter)
            let mine = try b.engine(oldPrimary.path).snapshots(tag: "binder:\(id)").map(\.id)
            #expect(!mine.isEmpty && mine.allSatisfy { held[$0] == false }, "the old mirror still holds the letter")

        case .forgetAfterDrillAndPrimaryChanged:
            // A drill also writes a binder snapshot, without making it the ordinary latest-snapshot record.
            try b.drill(e.folder, now: now)
            let oldPrimary = e.primary
            let newPrimary = e.base.appendingPathComponent("icloud/Sprava Backup 2", isDirectory: true)
            try b.setUp(primary: newPrimary, iCloudKeychain: false)
            try FileManager.default.removeItem(at: e.folder.appendingPathComponent(letter))
            #expect(try b.forgetDocument(in: e.folder, path: letter, request: "invented-deletion-1", now: now))
            let held = try holding(b, oldPrimary, letter)
            let mine = try b.engine(oldPrimary.path).snapshots(tag: "binder:\(id)").map(\.id)
            #expect(!mine.isEmpty && mine.allSatisfy { held[$0] == false }, "the drill's old snapshot still holds the letter")
        }
    }
}

@testable import Backup
import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit
import Testing

/// Every multi-step backup operation survives a crash between any two of its durable steps. Each operation runs once
/// with `Backup.atStep` taking an image of the disk (Sprava's state, both repositories, the spool, the Trash and the
/// binder) at every step boundary, as a crash there would leave it. Each image is then put back, the operation runs
/// again, and the end state is checked: nothing lost, nothing overwritten, every record naming snapshots that exist.
/// Repositories and binders live in temporary folders only. Invented data only.
@Suite struct BackupCrashTests {
    static let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotBackupTests()
    var now: Date { Self.now }
    static let letter = "correspondence/notary/letter.pdf"

    /// Disk images taken at step boundaries, named "step#n" for the n-th time that step was reached.
    final class Images: @unchecked Sendable {
        let lock = NSLock()
        let dirs: [URL]
        let store: URL
        private var counts: [String: Int] = [:]
        private(set) var taken: [String] = []

        init(_ dirs: [URL]) {
            self.dirs = dirs
            store = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-crash-images-\(UUID().uuidString)")
        }

        func take(_ step: String) {
            lock.lock(); defer { lock.unlock() }
            counts[step, default: 0] += 1
            let key = "\(step)#\(counts[step]!)"
            for (i, dir) in dirs.enumerated() where FileManager.default.fileExists(atPath: dir.path) {
                let to = store.appendingPathComponent("\(key)/\(i)")
                try? FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? FileManager.default.copyItem(at: dir, to: to)
            }
            taken.append(key)
        }

        /// Puts the disk back as it was at `key`.
        func restore(_ key: String) throws {
            for (i, dir) in dirs.enumerated() {
                try? FileManager.default.removeItem(at: dir)
                let from = store.appendingPathComponent("\(key)/\(i)")
                if FileManager.default.fileExists(atPath: from.path) { try FileManager.default.copyItem(at: from, to: dir) }
            }
        }
    }

    enum Operation: String, CaseIterable, CustomTestStringConvertible, Sendable {
        case backup, offload, restore, offloadAgain, expunge, forgetOffloaded
        var testDescription: String { rawValue }
    }

    func ids(_ b: Backup, _ repo: URL) throws -> Set<String> { Set(try b.engine(repo.path).snapshots().map(\.id)) }

    @Test(.enabled(if: BugbotBackupTests.hasRestic), arguments: Operation.allCases)
    func everyStepSurvivesACrash(_ op: Operation) throws {
        let e = try bb.env()
        var b = try bb.configured(e)
        let id = try Backup.backupID(e.folder)
        // Set up what the operation starts from.
        switch op {
        case .backup, .offload:
            break
        case .restore, .forgetOffloaded:
            guard case .done = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else { Issue.record("not offloaded"); return }
        case .offloadAgain:
            guard case .done(let record) = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now) else { Issue.record("not offloaded"); return }
            _ = try b.restore(record.backupID, now: now)
        case .expunge:
            try b.backUp(e.folder, now: now)
            try bb.addLogEntry(e.folder, "invented second entry")
            try b.backUp(e.folder, now: now)
        }
        let before = try b.state()
        let images = Images([e.base, e.folder.deletingLastPathComponent()])
        b.atStep = { images.take($0) }
        let run: (Backup) throws -> Void = { b in
            switch op {
            case .backup: try b.backUp(e.folder, now: now)
            case .offload, .offloadAgain: _ = try b.offload(e.folder, deviceID: "dev", confirmOpenItems: true, now: now)
            case .restore: _ = try b.restore(id, now: now)
            case .expunge: try b.forgetDocument(in: e.folder, path: Self.letter, now: now)
            case .forgetOffloaded: _ = try b.forget(id, path: Self.letter, now: now)
            }
        }
        try run(b)
        b.atStep = nil
        let expected: [Operation: Set<String>] = [
            .backup: ["backup.snapshotted#1"],
            .offload: ["offload.snapshotted#1", "offload.verified#1", "offload.copied#1", "offload.unpublished#1", "offload.leaving#1",
                       "offload.removed#1", "offload.unshelved#1"],
            .restore: ["restore.started#1", "restore.contents#1", "restore.shelved#1"],
            .offloadAgain: ["offload.verified#1", "offload.unpublished#1", "offload.leaving#1", "offload.removed#1", "offload.unshelved#1"],
            .expunge: ["forget.claimed#1", "forget.recorded#1", "forget.journaled#1", "forget.rewritten#1", "forget.renamed#1"],
            .forgetOffloaded: ["forget.recorded#1", "forget.journaled#1", "forget.rewritten#1", "forget.renamed#1",
                               "forget.journaled#2", "forget.rewritten#2", "forget.renamed#2"],
        ]
        #expect(expected[op]!.isSubset(of: Set(images.taken)), "steps reached: \(images.taken)")

        for key in images.taken {
            try images.restore(key)
            // What the person does meanwhile: a restored binder whose files are in place may be changed, and must keep it.
            let edited = op == .restore && key != "restore.started#1"
            if edited {
                try Data("invented edit".utf8).write(to: e.folder.appendingPathComponent(Self.letter))
                try bb.addLogEntry(e.folder, "invented approval after the restore")
            }
            do { try run(b) } catch { Issue.record("\(op) after a crash at \(key): \(error)"); continue }
            try checkEnd(op, b, e, id: id, before: before, edited: edited, key: key)
        }
        try? FileManager.default.removeItem(at: images.store)
    }

    func checkEnd(_ op: Operation, _ b: Backup, _ e: BugbotBackupTests.Env, id: String, before: Backup.State, edited: Bool, key: String) throws {
        let st = try b.state()
        let primary = try ids(b, e.primary), second = try ids(b, e.second)
        #expect(st.rewrites.isEmpty && st.restoredContents.isEmpty && st.restoring.isEmpty, "\(key)")
        // Every record names snapshots that exist.
        for r in st.offloaded {
            #expect(primary.contains(r.snapshot), "\(key): the record's snapshot is gone")
            #expect(r.secondSnapshot.map(second.contains) ?? false, "\(key): the record's second copy is gone")
        }
        for (_, rec) in st.binders { if let s = rec.snapshot { #expect(primary.contains(s), "\(key)") } }
        switch op {
        case .backup:
            #expect(st.binders[id]?.snapshot != nil && st.binders[id]?.path == e.folder.standardizedFileURL.path, "\(key)")
        case .offload, .offloadAgain:
            #expect(st.offloads.isEmpty && st.offloaded.count == 1, "\(key)")
            #expect(!FileManager.default.fileExists(atPath: e.folder.path), "\(key)")
            #expect(!ShelfStore(supportDirectory: e.support).pickedFolders().contains { $0.standardizedFileURL == e.folder.standardizedFileURL })
            // The binder went to the Trash once (offloading again, once more), with the person's confirmation in its
            // history at most once.
            let trashed = try FileManager.default.contentsOfDirectory(at: e.trash, includingPropertiesForKeys: nil)
            #expect(trashed.count == (op == .offloadAgain ? 2 : 1), "\(key)")
            for folder in trashed {
                let log = Teka.read(folder).catalog?["processing_log"]?.arrayValue ?? []
                #expect(log.filter { $0["action"]?.stringValue == "offloaded" }.count <= 1, "\(key)")
            }
            if op == .offloadAgain, let record = st.offloaded.first {
                #expect(record.bytes > 0, "\(key)")
                #expect(record.snapshot == before.restored[id]?.snapshot, "\(key): offload again took a new snapshot")
            }
        case .restore:
            #expect(st.offloaded.isEmpty, "\(key)")
            #expect(ShelfStore(supportDirectory: e.support).pickedFolders().contains { $0.standardizedFileURL == e.folder.standardizedFileURL })
            let letter = try String(contentsOf: e.folder.appendingPathComponent(Self.letter), encoding: .utf8)
            #expect(letter == (edited ? "invented edit" : "invented letter"), "\(key): the binder was restored over")
            if edited {
                let titles = (Teka.read(e.folder).catalog?["processing_log"]?.arrayValue ?? []).compactMap { $0["title"]?.stringValue }
                #expect(titles.contains("invented approval after the restore"), "\(key): an approved edit was lost")
            }
        case .expunge, .forgetOffloaded:
            #expect(st.forgetting.allSatisfy { $0.done != nil } && !st.forgetting.isEmpty, "\(key)")
            let pinned = op == .expunge ? [st.binders[id]?.snapshot].compactMap { $0 } : st.offloaded.map(\.snapshot)
            #expect(!pinned.isEmpty, "\(key)")
            for snap in pinned { #expect(!(try b.engine(e.primary.path).files(snap)).contains(Self.letter), "\(key)") }
            for snap in st.offloaded.compactMap(\.secondSnapshot) {
                #expect(!(try b.engine(e.second.path).files(snap)).contains(Self.letter), "\(key)")
            }
            for repo in [e.primary, e.second] where op == .forgetOffloaded {
                for snap in try b.engine(repo.path).snapshots(tag: "binder:\(id)") {
                    #expect(!(try b.engine(repo.path).files(snap.id)).contains(Self.letter), "\(key)")
                }
            }
        }
    }
}

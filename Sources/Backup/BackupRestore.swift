import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit

/// Restoring an offloaded binder and peeking at one of its documents (docs/backup.md §6.2, §6.3).
extension Backup {
    // MARK: - Restore (§6.2) and peek (§6.3)

    /// Restores an offloaded binder to its original folder (or `target`), from the mirror, else the second backup.
    /// An attempt that failed partway is resumed in the same folder: restic skips what it already restored.
    ///
    /// Once every file is in place and verified, that is recorded before the binder goes on the Shelf. From then on a
    /// retry only finishes the bookkeeping, at the folder already restored whatever `target` says: the binder may be
    /// live by then, and restic would overwrite whatever the person changed since. Nor is anything ever restored into
    /// a folder the Shelf lists.
    public func restore(_ backupID: String, to target: URL? = nil, now: Date = Date()) throws -> URL {
        var st = try state()
        if !st.rewrites.isEmpty { try? reconcileRewrites(&st) }
        if st.restoredContents[backupID] != nil { return try finishRestore(backupID) }
        guard let record = st.offloaded.first(where: { $0.backupID == backupID }) else { throw Failure(message: "no such offloaded binder") }
        let s = try settings()
        let destination = (target ?? URL(fileURLWithPath: record.originalPath, isDirectory: true)).standardizedFileURL
        // A live binder is never in a folder a sync service uploads (architecture 2.3), as adoption requires.
        if Adoption.syncedLocation(destination) || Adoption.syncedLocation(destination.deletingLastPathComponent()) {
            throw Failure(message: "\(destination.lastPathComponent) would be in a folder a sync service uploads; a live binder stays local. Choose another place")
        }
        let live = ShelfStore(supportDirectory: support).rows(includeArchived: true)
            .contains { Self.realPath($0.folder) == Self.realPath(destination) }
        if live {
            // Only a restore whose files were recorded as in place is finished without restic (`restoredContents`).
            // An older Sprava put the binder on the Shelf and stopped before its records were saved; the folder may
            // also be a partial restore the person put on the Shelf, or another binder. It counts as the restored
            // binder only when it is: its backup id, its history (the snapshot's op log, which only grows, still
            // starts it), and every other entry the snapshot holds present with the same contents. Then only the
            // records are finished, with no baseline (the next offload takes a new snapshot); nothing is written into
            // the folder either way.
            guard st.restoring[backupID] == destination.path else {
                throw Failure(message: "\(destination.lastPathComponent) is a binder on the Shelf; choose another place")
            }
            try verifyLive(record, s, destination: destination)
            st.restoredContents[backupID] = State.RestoredContents(path: destination.path, baseline: nil)
            try save(st)
            return try finishRestore(backupID)
        }
        // Only a missing place or a folder seen to be empty is restored to; one that cannot be listed may hold anything.
        try Self.refuseOccupied(destination)
        // restic restores, and resumes, into a private folder beside the destination (the same volume), never into
        // the destination itself: whatever the person puts there meanwhile is never overwritten (`install`).
        let staging = Self.staging(for: destination, id: backupID)
        if let earlier = st.restoring[backupID], earlier != destination.path {
            try? FileManager.default.removeItem(at: Self.staging(for: URL(fileURLWithPath: earlier, isDirectory: true), id: backupID))
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFile.makePrivateFolder(staging)
        st.restoring[backupID] = destination.path
        try save(st)
        step("restore.started")
        let held: Set<String>?
        do {
            held = try fromBackups(record, s) { r, snapshot in
                try r.restore(snapshot, into: staging)
                return try? r.files(snapshot)
            }
        } catch {
            throw Failure(message: "\(destination.lastPathComponent) is only partly restored (\(error)); restore again to resume")
        }
        try? FileManager.default.removeItem(at: staging.appendingPathComponent(".teka.lock"))
        // The binder folder's own metadata comes from the snapshot itself (`folderMetadataPath`), or for a snapshot
        // taken before it was kept there, from the record.
        let root = try Self.keptRootMetadata(in: staging) ?? record.rootMetadata
        if let root { try Self.apply(root, to: staging) }
        // The baseline a later offload compares with (§6.4) is the snapshot's own entries, as restic restored and
        // verified them. Without the snapshot's listing, or a folder that can be read whole, there is no baseline,
        // and the next offload takes a new snapshot.
        var baseline: State.Restored?
        if let held, let all = try? Self.manifest(staging) {
            baseline = State.Restored(snapshot: record.snapshot, repository: record.repository, secondSnapshot: record.secondSnapshot,
                                      secondRepository: record.secondRepository ?? s.second,
                                      manifest: all.filter { held.contains($0.key) }, bytes: record.bytes,
                                      rootEntry: root == nil ? nil : (try? Self.rootMetadata(staging))?.entry)
        }
        st.restoredContents[backupID] = State.RestoredContents(path: destination.path, baseline: baseline, staging: staging.path)
        try save(st)
        step("restore.contents")
        return try finishRestore(backupID)
    }

    /// The private folder a restore into `destination` works in: beside it, so moving it into place is one rename.
    static func staging(for destination: URL, id: String) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(".\(destination.lastPathComponent).sprava-restore-\(id.prefix(8))",
                                                                       isDirectory: true)
    }

    /// Refuses a destination that holds anything, or cannot be checked.
    static func refuseOccupied(_ destination: URL) throws {
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            guard info.st_mode & S_IFMT == S_IFDIR, let names = try? FileManager.default.contentsOfDirectory(atPath: destination.path),
                  names.isEmpty else {
                throw Failure(message: "\(destination.lastPathComponent) already exists there; choose another place")
            }
        } else if errno != ENOENT {
            throw Failure(message: "\(destination.lastPathComponent) cannot be checked; choose another place")
        }
    }

    /// Moves a restore's verified files into place with one rename, only into a missing place or an empty folder.
    /// Anything the person put there since is never overwritten: the restore stops, keeps its records and its staged
    /// files, and says so. A rename already done (a crash after it) is recognised by the binder's backup id.
    func install(_ contents: State.RestoredContents, id: String) throws {
        guard let stagingPath = contents.staging else { return }
        let staging = URL(fileURLWithPath: stagingPath, isDirectory: true)
        let destination = URL(fileURLWithPath: contents.path, isDirectory: true)
        guard FileManager.default.fileExists(atPath: staging.path) else {
            guard (try? Self.storedBackupID(destination)) == id else {
                throw Failure(message: "the restored files of \(destination.lastPathComponent) are missing; restore again")
            }
            return
        }
        do { try Self.refuseOccupied(destination) } catch {
            throw Failure(message: "something was put at \(destination.lastPathComponent) while it was being restored; nothing there was "
                + "changed, and the restored binder waits in \(staging.lastPathComponent) beside it. Move that away and restore again")
        }
        _ = rmdir(destination.path)
        guard rename(staging.path, destination.path) == 0 else {
            throw Failure(message: "the restored binder could not be moved to \(destination.lastPathComponent) (\(String(cString: strerror(errno)))); restore again")
        }
    }

    /// Checks that a folder on the Shelf is all of an offloaded binder's snapshot (`restore`), reading it only. The
    /// catalog, DASHBOARD.md and `.sprava/` other than the op log change with every approval, so they are not compared.
    func verifyLive(_ record: Offloaded, _ s: Settings, destination: URL) throws {
        let name = destination.lastPathComponent
        func conflict(_ why: String) -> Failure {
            Failure(message: "\(name) is on the Shelf but \(why); nothing was changed, and the offloaded binder's record is kept. "
                + "Take that folder off the Shelf and restore again to finish into it, or restore into another place")
        }
        guard (try? Self.storedBackupID(destination)) == record.backupID else { throw conflict("is another binder (its backup id differs)") }
        let (held, history) = try fromBackups(record, s) { r, snapshot -> ([String: String], Data?) in
            let verify = dir.appendingPathComponent("verify/live-\(record.backupID)", isDirectory: true)
            try? FileManager.default.removeItem(at: verify)
            try AtomicFile.makePrivateFolder(verify)
            defer { try? FileManager.default.removeItem(at: verify) }
            try r.restore(snapshot, into: verify)
            // A snapshot without an op log has no history to compare; one whose op log cannot be read throws.
            let log = verify.appendingPathComponent(".sprava/ops.ndjson")
            return (try Self.manifest(verify), FileManager.default.fileExists(atPath: log.path) ? try Data(contentsOf: log) : nil)
        }
        let current: [String: String]
        do { current = try Self.manifest(destination) } catch { throw conflict("cannot be read whole") }
        let changing: Set<String> = ["catalog.json", "DASHBOARD.md", ".sprava"]
        let differ = held.filter { !changing.contains($0.key) && !$0.key.hasPrefix(".sprava/") && current[$0.key] != $0.value }
        guard differ.isEmpty else { throw conflict("lacks \(differ.count) of the restored binder's files, or holds them changed") }
        let now = try? Data(contentsOf: destination.appendingPathComponent(".sprava/ops.ndjson"))
        if let history, !(now?.starts(with: history) ?? false) { throw conflict("its history is not the restored binder's") }
    }

    /// The bookkeeping after a restore's files are in place: the binder goes on the Shelf, then its records change.
    /// The binder is back only once the Shelf lists it; until then its record and the restore under way stay, so it
    /// is never in neither section of the Shelf, and restoring again (or the scheduled run) finishes here. Never
    /// touches the binder's files.
    @discardableResult
    func finishRestore(_ backupID: String) throws -> URL {
        var st = try state()
        guard var done = st.restoredContents[backupID] else { throw Failure(message: "no restore to finish") }
        let destination = URL(fileURLWithPath: done.path, isDirectory: true)
        if done.staging != nil {
            try install(done, id: backupID)
            done.staging = nil
            st.restoredContents[backupID] = done
            try save(st)
            step("restore.installed")
        }
        do { try ShelfStore(supportDirectory: support).add(destination) } catch {
            throw Failure(message: "\(destination.lastPathComponent) is restored but could not be put on the Shelf (\(error)); restore again to finish")
        }
        step("restore.shelved")
        st.restored[backupID] = done.baseline
        // The restored folder holds the id from the save that ends the reservations, so no moment is left in which
        // a copy carrying the id could claim it (`claim`).
        st.binders[backupID, default: State.BinderRecord()].path = destination.standardizedFileURL.path
        st.offloaded.removeAll { $0.backupID == backupID }
        st.restoring[backupID] = nil
        st.restoredContents[backupID] = nil
        try save(st)
        return destination
    }

    /// One document of an offloaded binder, into a private temporary folder (`cleanPeeks` removes it a day later).
    public func peek(_ backupID: String, path: String) throws -> URL {
        var st = try state()
        if !st.rewrites.isEmpty { try? reconcileRewrites(&st) }
        guard let record = st.offloaded.first(where: { $0.backupID == backupID }) else { throw Failure(message: "no such offloaded binder") }
        guard record.documents.contains(where: { $0.path == path }), DocumentPaths.isSafe(path, forFiling: false) else {
            throw Failure(message: "that document is not in the binder")
        }
        let folder = dir.appendingPathComponent("peek/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try AtomicFile.makePrivateFolder(folder)
        let file = folder.appendingPathComponent((path as NSString).lastPathComponent)
        try fromBackups(record, try settings()) { r, snapshot in try r.dump(snapshot, path: "/" + path, to: file) }
        return file
    }

    /// Runs `body` on an offloaded binder's snapshot: in the mirror it was written to, then in the current mirror if
    /// that is another folder (a mirror moved with its files keeps its snapshots), then in the second backup.
    func fromBackups<T>(_ record: Offloaded, _ s: Settings, _ body: (Restic, String) throws -> T) throws -> T {
        var mirrors = [record.repository ?? s.primary]
        if record.repository != nil, s.primary != record.repository { mirrors.append(s.primary) }
        var last: Error = Failure(message: "backup is not set up")
        for mirror in mirrors {
            do { return try body(try engine(mirror), record.snapshot) } catch { last = error }
        }
        guard let second = record.secondSnapshot else { throw last }
        return try body(try engine(record.secondRepository ?? s.second), second)
    }

    /// Removes peeked documents older than a day: plain copies of offloaded documents do not stay on the Mac. So do
    /// verification restores (offload, restore and drill checks) that Sprava stopped in the middle of, which would
    /// otherwise stay as whole plain copies of binders. One still in use a day on only fails its check, safely.
    public func cleanPeeks(now: Date = Date()) {
        let fm = FileManager.default
        for folder in ["peek", "verify"] {
            let parent = dir.appendingPathComponent(folder, isDirectory: true)
            for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] {
                let url = parent.appendingPathComponent(name)
                let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
                if now.timeIntervalSince(modified) > 86_400 { try? fm.removeItem(at: url) }
            }
        }
    }
}

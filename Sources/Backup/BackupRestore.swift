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
        // restic overwrites what is in its way, so only a missing place or a folder seen to be empty is restored
        // into, unless this restore is being resumed. One that cannot be listed may hold anything.
        if st.restoring[backupID] != destination.path {
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
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        st.restoring[backupID] = destination.path
        try save(st)
        step("restore.started")
        let held: Set<String>?
        do {
            held = try fromBackups(record, s) { r, snapshot in
                try r.restore(snapshot, into: destination)
                return try? r.files(snapshot)
            }
        } catch {
            throw Failure(message: "\(destination.lastPathComponent) is only partly restored (\(error)); restore again to resume")
        }
        try? FileManager.default.removeItem(at: destination.appendingPathComponent(".teka.lock"))
        // The baseline a later offload compares with (§6.4) is the snapshot's own entries, as restic restored and
        // verified them, never the whole folder: a resumed restore keeps whatever was added to the folder in the
        // meantime, and no snapshot holds that, so the binder no longer counts as unchanged. Without the
        // snapshot's listing, or a folder that can be read whole, there is no baseline, and the next offload takes
        // a new snapshot.
        var baseline: State.Restored?
        if let held, let all = try? Self.manifest(destination) {
            baseline = State.Restored(snapshot: record.snapshot, repository: record.repository, secondSnapshot: record.secondSnapshot,
                                      secondRepository: record.secondRepository ?? s.second,
                                      manifest: all.filter { held.contains($0.key) }, bytes: record.bytes)
        }
        st.restoredContents[backupID] = State.RestoredContents(path: destination.path, baseline: baseline)
        try save(st)
        step("restore.contents")
        return try finishRestore(backupID)
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
            return (try Self.manifest(verify), try? Data(contentsOf: verify.appendingPathComponent(".sprava/ops.ndjson")))
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
        guard let done = st.restoredContents[backupID] else { throw Failure(message: "no restore to finish") }
        let destination = URL(fileURLWithPath: done.path, isDirectory: true)
        do { try ShelfStore(supportDirectory: support).add(destination) } catch {
            throw Failure(message: "\(destination.lastPathComponent) is restored but could not be put on the Shelf (\(error)); restore again to finish")
        }
        step("restore.shelved")
        st.restored[backupID] = done.baseline
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

    /// Removes peeked documents older than a day: plain copies of offloaded documents do not stay on the Mac.
    public func cleanPeeks(now: Date = Date()) {
        let peeks = dir.appendingPathComponent("peek", isDirectory: true)
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: peeks.path)) ?? [] {
            let url = peeks.appendingPathComponent(name)
            let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date ?? .distantPast
            if now.timeIntervalSince(modified) > 86_400 { try? fm.removeItem(at: url) }
        }
    }
}

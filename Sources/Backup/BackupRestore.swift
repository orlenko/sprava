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
    public func restore(_ backupID: String, to target: URL? = nil, now: Date = Date()) throws -> URL {
        var st = try state()
        guard let record = st.offloaded.first(where: { $0.backupID == backupID }) else { throw Failure(message: "no such offloaded binder") }
        let s = try settings()
        let destination = (target ?? URL(fileURLWithPath: record.originalPath, isDirectory: true)).standardizedFileURL
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
        // The binder is back only once the Shelf lists it. Until then its record and the restore under way stay, so
        // it is never in neither section of the Shelf, and restoring again resumes here and adds it.
        do { try ShelfStore(supportDirectory: support).add(destination) } catch {
            throw Failure(message: "\(destination.lastPathComponent) is restored but could not be put on the Shelf (\(error)); restore again to finish")
        }
        // The baseline a later offload compares with (§6.4) is the snapshot's own entries, as restic restored and
        // verified them, never the whole folder: a resumed restore keeps whatever was added to the folder in the
        // meantime, and no snapshot holds that, so the binder no longer counts as unchanged. Without the
        // snapshot's listing, or a folder that can be read whole, there is no baseline, and the next offload takes
        // a new snapshot.
        if let held, let all = try? Self.manifest(destination) {
            st.restored[backupID] = State.Restored(snapshot: record.snapshot, repository: record.repository, secondSnapshot: record.secondSnapshot,
                                                   secondRepository: record.secondRepository ?? s.second,
                                                   manifest: all.filter { held.contains($0.key) })
        } else {
            st.restored[backupID] = nil
        }
        st.offloaded.removeAll { $0.backupID == backupID }
        st.restoring[backupID] = nil
        try save(st)
        return destination
    }

    /// One document of an offloaded binder, into a private temporary folder (`cleanPeeks` removes it a day later).
    public func peek(_ backupID: String, path: String) throws -> URL {
        guard let record = try state().offloaded.first(where: { $0.backupID == backupID }) else { throw Failure(message: "no such offloaded binder") }
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

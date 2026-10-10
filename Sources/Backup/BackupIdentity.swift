import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// A binder's backup id: kept inside the binder, claimed by one folder at a time (docs/backup.md §3).
extension Backup {

    /// A binder's stable backup id, kept inside the binder so it survives a restore elsewhere. One is made only when
    /// none is there (`storedBackupID`).
    public static func backupID(_ folder: URL) throws -> String {
        if let id = try storedBackupID(folder) { return id }
        // Only in a binder folder that is there: a binder moved or deleted since (a queued "back up now"), or on a disk
        // that is away, never gets a skeleton of its old path made for it.
        var info = stat()
        guard stat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw Failure(message: "\(folder.lastPathComponent) is not there any more; nothing was backed up")
        }
        let id = newBackupID()
        try writeBackupID(id, into: folder, creating: true)
        return id
    }

    /// Writes `.sprava/backup-id` through handles to the binder folder and its `.sprava` (`BinderSprava`): a
    /// binder moved away meanwhile, or a link put in place of `.sprava`, fails instead of being written through,
    /// and a new `.sprava` is flushed into the binder before the id counts.
    static func writeBackupID(_ id: String, into folder: URL, creating: Bool) throws {
        guard let sprava = try BinderSprava.open(folder, create: creating) else {
            throw Failure(message: "\(folder.lastPathComponent)'s .sprava is missing; its backup id was not written")
        }
        try sprava.write(Data((id + "\n").utf8), to: "backup-id")
    }

    /// A folder holds another binder's backup id: it was copied, with `.sprava/backup-id`, from a binder that is still
    /// there. It is not backed up, offloaded or forgotten in until it has its own (`giveOwnBackupID`).
    public struct SharedBackupID: Error, CustomStringConvertible {
        public let folder: String
        public let holder: String
        public var description: String {
            "\(URL(fileURLWithPath: folder).lastPathComponent) has the backup id of another binder (\(holder)), so its backups would mix "
                + "with that binder's; nothing was changed. If it is a copy, give it its own backup id"
        }
    }

    /// The backup id `folder` holds, checked against the folder the records name for it, which becomes `folder` when
    /// it is free. A copy of a binder carries the binder's id; while the binder still holds it at its recorded place,
    /// the copy is refused, so the two never share snapshots under one tag, and forgetting a document in one never
    /// rewrites the other's backups. A binder that moved (nothing holds the id at the recorded place) takes the
    /// record with it. The caller saves `st`.
    ///
    /// An id an offloaded binder, an offload of another folder or a restore into another folder holds is reserved:
    /// that binder's folder is gone or not yet back, so a copy of it would otherwise take the id, and forgetting a
    /// document in the copy would rewrite the offloaded binder's pinned backups.
    func claim(_ folder: URL, _ st: inout State) throws -> String {
        let id = try Self.backupID(folder)
        let here = Self.realPath(folder)
        func other(_ path: String) -> Bool { Self.realPath(URL(fileURLWithPath: path, isDirectory: true)) != here }
        // The binder an offload is taking away still holds its id until it has left (its record is kept first).
        let leaving = st.offloads[id].map { !other($0.path) } ?? false
        if !leaving, let record = st.offloaded.first(where: { $0.backupID == id }) {
            // The folder a restore of it is going into is the binder itself.
            let restoring = st.restoredContents[id]?.path ?? st.restoring[id]
            if restoring.map(other) ?? true { throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: record.originalPath + " (offloaded)") }
        }
        if let job = st.offloads[id], other(job.path) { throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: job.path) }
        if let path = st.restoredContents[id]?.path ?? st.restoring[id], other(path) {
            throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: path)
        }
        // The record moves only once the recorded folder is seen not to hold the id: it is gone, or holds no id or
        // another one. One whose volume or id cannot be read may still hold it, so it keeps it.
        if let recorded = st.binders[id]?.path, Self.realPath(URL(fileURLWithPath: recorded)) != Self.realPath(folder) {
            let recordedURL = URL(fileURLWithPath: recorded, isDirectory: true)
            switch Self.folderEntry(recordedURL) {
            case .unavailable:
                throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: recorded + " (its location is unavailable)")
            case .missing:
                break
            case .present:
                let held: String?
                do { held = try Self.storedBackupID(recordedURL) } catch {
                    throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: recorded + " (its backup id cannot be read)")
                }
                if held == id { throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: recorded) }
            }
        }
        st.binders[id, default: State.BinderRecord()].path = folder.standardizedFileURL.path
        // A folder that holds an id finishes any reassignment that was writing it: the id is no longer pending.
        st.reassigning = st.reassigning.filter { $0.value.id != id }
        return id
    }

    /// Gives a copied binder a backup id of its own, so it is backed up apart from the binder it was copied from.
    /// Refused for the folder the records name as the id's holder, whose snapshots and records the id ties
    /// together, and for a binder an offload is taking away.
    @discardableResult
    public func giveOwnBackupID(_ folder: URL) throws -> String {
        guard let old = try Self.storedBackupID(folder) else { return try Self.backupID(folder) }
        var st = try state()
        // A reassignment that wrote its id and stopped before clearing its record is finished: the folder already
        // holds its own id.
        let here = folder.standardizedFileURL.path
        let key = Self.realPath(folder)
        if st.reassigning[key]?.id == old {
            st.reassigning[key] = nil
            try save(st)
            return old
        }
        if let recorded = st.binders[old]?.path, Self.realPath(URL(fileURLWithPath: recorded)) == Self.realPath(folder) {
            throw Failure(message: "this binder's backups are kept under its backup id; only a copy gets a new one")
        }
        if let job = st.offloads[old], Self.realPath(URL(fileURLWithPath: job.path)) == Self.realPath(folder) {
            throw Failure(message: "this binder is being offloaded; finish or cancel that first")
        }
        if let path = st.restoredContents[old]?.path ?? st.restoring[old], Self.realPath(URL(fileURLWithPath: path)) == Self.realPath(folder) {
            throw Failure(message: "this binder is being restored; finish the restore first")
        }
        // The folder owns the new id before it holds it: a crash between the two leaves a record of an id no folder
        // holds, never an id no record reserves. The reassignment is recorded by the copy's path, so a retry
        // finishes it with the same new id instead of minting another.
        let id: String
        // Only while the pending id is still reserved for this folder: its record may have moved with a folder that
        // already holds it.
        let identity = Self.folderIdentity(folder)
        if let pending = st.reassigning[key], pending.from == old, pending.folder != nil, pending.folder == identity,
           let reserved = st.binders[pending.id]?.path, Self.realPath(URL(fileURLWithPath: reserved)) == key {
            id = pending.id
        } else {
            id = Self.newBackupID()
            st.reassigning[key] = .init(from: old, id: id, folder: identity)
        }
        st.binders[id, default: State.BinderRecord()].path = here
        try save(st)
        step("ownid.recorded")
        try Self.writeBackupID(id, into: folder, creating: false)
        st.reassigning[key] = nil
        try save(st)
        return id
    }

    /// A folder's device and inode, which a move keeps and a replacement at the same path does not.
    static func folderIdentity(_ folder: URL) -> String? {
        var info = stat()
        guard stat(folder.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    static func newBackupID() -> String { UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }

    /// A binder's backup id when it already has one, for pages that only show it (the app's Health page). Never
    /// creates one, and refuses a `.sprava` folder or `backup-id` file that is a symbolic link: nil then.
    public static func existingBackupID(_ folder: URL) -> String? {
        (try? storedBackupID(folder)) ?? nil
    }

    /// The id in `.sprava/backup-id`, nil only when there is none. Anything else that is not a readable id (a link,
    /// a special file, which is read without waiting on it, a file that cannot be read or holds something else)
    /// throws and is left as it is: a new id would cut the binder off from its snapshots and its records.
    static func storedBackupID(_ folder: URL) throws -> String? {
        let unreadable = Failure(message: ".sprava/backup-id cannot be read; nothing was changed")
        let sprava: BinderSprava?
        do { sprava = try BinderSprava.open(folder, create: false) } catch {
            // A binder folder that is not there holds no id.
            var info = stat()
            if lstat(folder.path, &info) != 0, errno == ENOENT { return nil }
            throw unreadable
        }
        guard let sprava else { return nil }
        switch sprava.read("backup-id", limit: 64) {
        case .missing: return nil
        case .ok(let data):
            guard let text = String(data: data, encoding: .utf8), text.wholeMatch(of: /[0-9a-f]{32}\n?/) != nil else { throw unreadable }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .refused, .unreadable: throw unreadable
        }
    }

    enum FolderEntry: Equatable { case present, missing, unavailable }

    /// Whether the binder's final directory entry exists. `fileExists` folds a disconnected volume, an unreadable
    /// parent and a genuinely removed entry into false; an offload may finish only for the last of those. Opening the
    /// immediate parent proves it is available before ENOENT is accepted as a completed move to the Trash.
    ///
    /// A folder whose parent is gone too (an ancestor was moved or deleted) is missing the same way, proven from the
    /// nearest ancestor that opens; a missing volume mount point (`/Volumes/<disk>`, a disk that is away) is not.
    static func folderEntry(_ folder: URL) -> FolderEntry {
        var info = stat()
        if lstat(folder.path, &info) == 0 {
            switch info.st_mode & S_IFMT {
            case S_IFDIR: return .present
            case S_IFLNK:
                // A binder reached through a link: the link's target decides; one that cannot be reached may be on
                // a disk that is away.
                guard stat(folder.path, &info) == 0 else { return .unavailable }
                return info.st_mode & S_IFMT == S_IFDIR ? .present : .missing
            default:
                // A file where the binder was: the binder is not there.
                return .missing
            }
        }
        guard errno == ENOENT || errno == ENOTDIR else { return .unavailable }
        let parent = folder.deletingLastPathComponent()
        if parent.standardizedFileURL.path == "/Volumes" { return .unavailable }
        // The parent is opened through links, as the Shelf allows a binder to be reached through one.
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            guard errno == ENOENT || errno == ENOTDIR, parent.standardizedFileURL.path != "/" else { return .unavailable }
            var entry = stat()
            if lstat(parent.path, &entry) == 0 {
                // A file at the parent's path: the binder cannot be there. A link whose target cannot be opened may
                // lead to a disk that is away, so the binder may still be there.
                return entry.st_mode & S_IFMT == S_IFLNK ? .unavailable : .missing
            }
            return folderEntry(parent) == .missing ? .missing : .unavailable
        }
        defer { close(fd) }
        if fstatat(fd, folder.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 { return .present }
        return errno == ENOENT ? .missing : .unavailable
    }
}

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
        guard lstat(folder.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else {
            throw Failure(message: "\(folder.lastPathComponent) is not there any more; nothing was backed up")
        }
        let id = newBackupID()
        let url = folder.appendingPathComponent(".sprava/backup-id")
        try AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
        try AtomicFile.write(Data((id + "\n").utf8), to: url)
        return id
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
            if Self.folderEntry(recordedURL) == .unavailable {
                throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: recorded + " (its location is unavailable)")
            }
            let held: String?
            do { held = try Self.storedBackupID(recordedURL) } catch {
                throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: recorded + " (its backup id cannot be read)")
            }
            if held == id { throw SharedBackupID(folder: folder.standardizedFileURL.path, holder: recorded) }
        }
        st.binders[id, default: State.BinderRecord()].path = folder.standardizedFileURL.path
        return id
    }

    /// Gives a copied binder a backup id of its own, so it is backed up apart from the binder it was copied from.
    /// Refused for the folder the records name as the id's holder, whose snapshots and records the id ties
    /// together, and for a binder an offload is taking away.
    @discardableResult
    public func giveOwnBackupID(_ folder: URL) throws -> String {
        guard let old = try Self.storedBackupID(folder) else { return try Self.backupID(folder) }
        var st = try state()
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
        // holds, never an id no record reserves.
        let id = Self.newBackupID()
        st.binders[id, default: State.BinderRecord()].path = folder.standardizedFileURL.path
        try save(st)
        step("ownid.recorded")
        try AtomicFile.write(Data((id + "\n").utf8), to: folder.appendingPathComponent(".sprava/backup-id"))
        return id
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
        let sprava = folder.appendingPathComponent(".sprava")
        let url = sprava.appendingPathComponent("backup-id")
        let unreadable = Failure(message: ".sprava/backup-id cannot be read; nothing was changed")
        var st = stat()
        if lstat(sprava.path, &st) != 0 {
            guard errno == ENOENT else { throw unreadable }
            return nil
        }
        guard st.st_mode & S_IFMT == S_IFDIR else { throw unreadable }
        if lstat(url.path, &st) != 0 {
            guard errno == ENOENT else { throw unreadable }
            return nil
        }
        guard case .ok(let data) = SafeFile.read(url, limit: 64), let text = String(data: data, encoding: .utf8),
              text.wholeMatch(of: /[0-9a-f]{32}\n?/) != nil else { throw unreadable }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum FolderEntry: Equatable { case present, missing, unavailable }

    /// Whether the binder's final directory entry exists. `fileExists` folds a disconnected volume, an unreadable
    /// parent and a genuinely removed entry into false; an offload may finish only for the last of those. Opening the
    /// immediate parent proves it is available before ENOENT is accepted as a completed move to the Trash.
    static func folderEntry(_ folder: URL) -> FolderEntry {
        var info = stat()
        if lstat(folder.path, &info) == 0 { return .present }
        guard errno == ENOENT || errno == ENOTDIR else { return .unavailable }
        let parent = folder.deletingLastPathComponent()
        let fd = open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return .unavailable }
        defer { close(fd) }
        if fstatat(fd, folder.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 { return .present }
        return errno == ENOENT ? .missing : .unavailable
    }
}

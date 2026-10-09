import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit

/// Backing up: binder snapshots, Sprava's own state, retention and checks, the iCloud upload status, manifests,
/// the restore drill and the scheduled run (docs/backup.md §3, §8).
extension Backup {
    // MARK: - Snapshots

    static let excludes = [".teka.lock", ".*.tmp", ".DS_Store"]

    /// A binder's stable backup id, kept inside the binder so it survives a restore elsewhere. One is made only when
    /// none is there (`storedBackupID`).
    public static func backupID(_ folder: URL) throws -> String {
        if let id = try storedBackupID(folder) { return id }
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        let url = folder.appendingPathComponent(".sprava/backup-id")
        try AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
        try AtomicFile.write(Data((id + "\n").utf8), to: url)
        return id
    }

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

    /// What every binder write changes: the op log grows and the catalog is replaced (binder-v0 §6.9).
    static func writeMark(_ folder: URL) -> String {
        let log = (try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(".sprava/ops.ndjson").path))?[.size] as? Int
        return "\(log ?? -1) \(DocumentPaths.sha256(of: folder.appendingPathComponent("catalog.json")) ?? "-")"
    }

    @discardableResult
    public func backUp(_ folder: URL, now: Date = Date()) throws -> Restic.BackupResult {
        let id = try Self.backupID(folder)
        var st = try state()
        do {
            let before = Self.writeMark(folder)
            let result = try engine(settings().primary).backup(folder, tags: ["sprava", "binder:\(id)"], excludes: Self.excludes)
            afterSnapshot?()
            var rec = st.binders[id] ?? State.BinderRecord()
            if let snap = result.snapshot { rec.snapshot = snap }
            // restic reads one file at a time, so a write that landed during the run may be only partly in this
            // snapshot. The binder then stays due, and the next run takes another.
            if Self.writeMark(folder) == before { rec.at = ISOTime.string(now) }
            rec.bytes = result.bytes
            rec.error = nil
            st.binders[id] = rec
            try save(st)
            return result
        } catch {
            st.binders[id, default: State.BinderRecord()].error = "\(error)"
            try? save(st)
            throw error
        }
    }

    /// Sprava's own state, minus the backup's cache and run files.
    public func backUpState(now: Date = Date()) throws {
        var st = try state()
        _ = try engine(settings().primary).backup(support, tags: ["sprava", "sprava-state"],
                                                  excludes: Self.excludes + ["backup/cache", "backup/run", "backup/verify", "backup/peek"])
        st.stateSnapshotAt = ISOTime.string(now)
        try save(st)
    }

    /// Weekly forget and prune per binder, by the retention rule; offloaded snapshots are always kept.
    public func applyRetention(now: Date = Date()) throws {
        let s = try settings()
        let r = try engine(s.primary)
        var st = try state()
        for id in st.binders.keys.sorted() {
            try r.forget(tag: "binder:\(id)", keepLast: s.keepLast, keepWithinDays: s.keepWithinDays, keepMonthly: s.keepMonthly, keepYearly: s.keepYearly)
        }
        st.lastForget = ISOTime.string(now)
        try save(st)
    }

    /// Weekly structure check; monthly, one twelfth of the data read back, rotating.
    public func check(readData: Bool, now: Date = Date()) throws {
        var st = try state()
        let r = try engine(settings().primary)
        if readData {
            st.readDataPart = st.readDataPart % 12 + 1
            try r.check(readDataSubset: "\(st.readDataPart)/12")
            st.lastReadData = ISOTime.string(now)
        } else {
            try r.check()
        }
        st.lastCheck = ISOTime.string(now)
        try save(st)
    }

    // MARK: - Is it in iCloud?

    public enum Upload: Equatable, Sendable {
        case notInICloud
        case uploaded
        case waiting(Int)
    }

    /// Whether macOS reports every file of a repository as uploaded to iCloud (docs/backup.md §3.4).
    public static func uploadStatus(of repository: URL) -> Upload {
        let keys: [URLResourceKey] = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: repository, includingPropertiesForKeys: keys) else { return .notInICloud }
        var pending = 0
        var ubiquitous = false
        for case let url as URL in walker {
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            if v.isUbiquitousItem == true {
                ubiquitous = true
                if v.ubiquitousItemIsUploaded != true { pending += 1 }
            }
        }
        if !ubiquitous { return .notInICloud }
        return pending == 0 ? .uploaded : .waiting(pending)
    }

    // MARK: - Manifests

    /// Every entry under `folder` that a snapshot holds, as restic backs it up: a file with its SHA-256, a symbolic
    /// link with its target, a folder as such. A folder that cannot be listed or a file that cannot be read throws:
    /// whatever a manifest left out could leave the Mac while the binder still counts as unchanged.
    static func manifest(_ folder: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        func unreadable(_ rel: String) -> Failure {
            Failure(message: "\(rel.isEmpty ? "the binder" : rel) cannot be read; nothing was removed")
        }
        func walk(_ dir: URL, _ prefix: String) throws {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { throw unreadable(prefix) }
            for name in names.sorted() {
                // The names restic leaves out (`excludes`), wherever they are, and anything inside them.
                if name == ".teka.lock" || name == ".DS_Store" || (name.hasPrefix(".") && name.hasSuffix(".tmp")) { continue }
                let url = dir.appendingPathComponent(name)
                let rel = prefix.isEmpty ? name : prefix + "/" + name
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw unreadable(rel) }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    out[rel] = "folder"
                    try walk(url, rel)
                case S_IFLNK:
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { throw unreadable(rel) }
                    out[rel] = "link " + target
                case S_IFREG:
                    guard let sha = DocumentPaths.sha256(of: url) else { throw unreadable(rel) }
                    out[rel] = sha
                default:
                    out[rel] = "special \(info.st_mode & S_IFMT)"
                }
            }
        }
        try walk(folder, "")
        return out
    }

    /// One digest for a whole manifest, to tell later whether the binder still matches it.
    static func digest(_ manifest: [String: String]) -> String {
        let text = manifest.keys.sorted().map { "\($0)\t\(manifest[$0] ?? "")\n" }.joined()
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Restore drill (§8)

    /// Backs the binder up, restores the snapshot into a private temporary folder, compares, and cleans up.
    public func drill(_ folder: URL, now: Date = Date()) throws {
        let primary = try engine(settings().primary)
        let id = try Self.backupID(folder)
        _ = try primary.backup(folder, tags: ["sprava", "binder:\(id)"], excludes: Self.excludes, skipIfUnchanged: false)
        guard let snap = try primary.snapshots(tag: "binder:\(id)").last?.id else { throw Failure(message: "no snapshot to restore") }
        let target = dir.appendingPathComponent("verify/drill-\(id)", isDirectory: true)
        try? FileManager.default.removeItem(at: target)
        try AtomicFile.makePrivateFolder(target)
        defer { try? FileManager.default.removeItem(at: target) }
        try primary.restore(snap, into: target)
        guard try Self.manifest(target) == Self.manifest(folder) else { throw Failure(message: "the restored copy differs from the binder") }
        var st = try state()
        st.lastDrill = ISOTime.string(now)
        try save(st)
    }

    // MARK: - Scheduled work (docs/backup.md §3.3)

    public struct Maintenance: Sendable, Equatable {
        public var snapshots = 0
        public var unchanged = 0
        public var failed = 0
        public var stateSnapshot = false
        public var retention = false
        public var checked = false
        /// What failed apart from the binders, by name (`backup_settings` or `backup_state` unreadable,
        /// `state_snapshot`, `retention`, `check`, `offload`, `forget`): each also counts in `failed` and stays due, so the next run tries it again.
        public var failedParts: [String] = []
    }

    /// Hourly snapshots of each live binder this Mac manages (skipped when unchanged), Sprava's state daily,
    /// retention and a structure check weekly, a rotating read-back monthly. No binder lock is held through a
    /// restic run, which would hold up approvals for minutes; a write that lands during a run leaves the binder
    /// due, so the next run snapshots it again (`backUp`). Unreadable settings or state stop all of it, as a failure.
    public func maintain(rows: [ShelfRow], deviceID: String, now: Date = Date()) -> Maintenance {
        var m = Maintenance()
        cleanPeeks(now: now)
        func older(_ iso: String?, than seconds: TimeInterval) -> Bool {
            guard let iso, let d = ISOTime.date(iso) else { return true }
            return now.timeIntervalSince(d) > seconds
        }
        func fail(_ part: String) {
            m.failed += 1
            if !m.failedParts.contains(part) { m.failedParts.append(part) }
        }
        guard let configured = try? isConfigured else {
            fail("backup_settings")
            return m
        }
        guard configured else { return m }
        guard let st = try? state() else {
            fail("backup_state")
            return m
        }
        // An offload interrupted after its record was kept is finished here, whatever became of its request.
        for (id, job) in st.offloads where job.stage == "leaving" {
            if (try? continueOffload(id, now: now)) == nil { fail("offload") }
        }
        for row in rows where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            guard let id = try? Self.backupID(row.folder) else {
                m.failed += 1
                continue
            }
            // Only a binder on its way out is left alone. One whose offload failed or waits for iCloud is still live
            // and still changing, so it is backed up as usual; a change starts its offload over anyway.
            if st.offloads[id]?.stage == "leaving" { continue }
            guard older(st.binders[id]?.at, than: 3600) else { continue }
            do {
                let r = try backUp(row.folder, now: now)
                if r.snapshot == nil { m.unchanged += 1 } else { m.snapshots += 1 }
            } catch {
                m.failed += 1
            }
        }
        func due(_ field: (State) -> String?, _ seconds: TimeInterval) -> Bool {
            guard let st = try? state() else { return false }
            return older(field(st), than: seconds)
        }
        // A document deleted for good that a backup still holds is tried again until neither does.
        if st.forgetting.contains(where: { $0.done == nil }), (try? forgetPending(now: now)) != 0 { fail("forget") }
        // Sprava's own state holds the offload records and other recovery state: a failed snapshot of it is a
        // failure like a binder's, and so is a failed retention run. Neither moves its date, so both stay due.
        if due(\.stateSnapshotAt, 86_400) {
            if (try? backUpState(now: now)) != nil { m.stateSnapshot = true } else { fail("state_snapshot") }
        }
        if due(\.lastForget, 7 * 86_400) {
            if (try? applyRetention(now: now)) != nil { m.retention = true } else { fail("retention") }
        }
        if due(\.lastCheck, 7 * 86_400) {
            let readData = due(\.lastReadData, 30 * 86_400)
            if (try? check(readData: readData, now: now)) != nil { m.checked = true } else { fail("check") }
        }
        return m
    }
}

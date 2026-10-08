import Darwin
import Foundation

/// Backup, offload and restore (docs/backup.md). One restic repository in iCloud Drive holds a snapshot per
/// binder and one of Sprava's own state; a second repository elsewhere holds the copies offloading requires.
public struct Backup: Sendable {
    public let support: URL
    public let key: String?
    public let resticBinary: URL?
    /// How an offloaded binder leaves the Mac: the Trash, so nothing is destroyed until the person empties it.
    public let removeFolder: @Sendable (URL) throws -> Void

    public init(support: URL, key: String? = BackupKey.load(), resticBinary: URL? = Restic.locate(),
                removeFolder: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }) {
        self.support = support
        self.key = key
        self.resticBinary = resticBinary
        self.removeFolder = removeFolder
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Open items stand in the way of an offload until the person confirms (decided 2026-10-08).
    public struct NeedsConfirmation: Error, CustomStringConvertible {
        public let openItems: [String]
        public var description: String { "\(openItems.count) open item(s) would stop showing anywhere" }
    }

    // MARK: - Settings and state

    public struct Settings: Codable, Sendable, Equatable {
        public var primary: String?
        public var second: String?
        public var iCloudKeychain = false
        public var resticSHA256: String?
        public var keepLast = 30
        public var keepWithinDays = 90
        public var keepMonthly = 24
        public var keepYearly = 10
        public init() {}
    }

    public struct Offloaded: Codable, Sendable, Equatable {
        public var backupID: String
        public var name: String
        public var originalPath: String
        public var snapshot: String
        public var secondSnapshot: String?
        public var bytes: Int64
        public var at: String
        public var summary: String
        public var documents: [Document]
        public var openItemsConfirmed: Int
        public struct Document: Codable, Sendable, Equatable { public var title: String; public var path: String }
    }

    struct InProgress: Codable, Equatable {
        var path: String
        var stage: String          // snapshotted, verified, waiting_for_upload, copied
        var snapshot: String?
        var secondSnapshot: String?
        var bytes: Int64 = 0
        var openItemsConfirmed = 0
    }

    struct State: Codable {
        var binders: [String: BinderRecord] = [:]
        var stateSnapshotAt: String?
        var lastForget: String?
        var lastCheck: String?
        var lastReadData: String?
        var readDataPart = 0
        var lastDrill: String?
        var offloads: [String: InProgress] = [:]
        var offloaded: [Offloaded] = []
        var restored: [String: Restored] = [:]
        struct BinderRecord: Codable, Equatable {
            var snapshot: String?
            var at: String?
            var bytes: Int64 = 0
            var error: String?
        }
        struct Restored: Codable, Equatable {
            var snapshot: String
            var secondSnapshot: String?
            var manifest: [String: String]
        }
    }

    var dir: URL { support.appendingPathComponent("backup", isDirectory: true) }
    var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }

    public func settings() -> Settings {
        (try? Data(contentsOf: settingsURL)).flatMap { try? JSONDecoder().decode(Settings.self, from: $0) } ?? Settings()
    }

    func save(_ s: Settings) throws {
        try AtomicFile.makePrivateFolder(dir)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(s), to: settingsURL)
    }

    func state() -> State {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func save(_ s: State) throws {
        try AtomicFile.makePrivateFolder(dir)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(s), to: stateURL)
    }

    public var isConfigured: Bool { settings().primary != nil && key != nil }

    /// The default mirror: a folder in the person's iCloud Drive.
    public static var defaultPrimary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Sprava Backup", isDirectory: true)
    }

    func engine(_ path: String?) throws -> Restic {
        guard let path, let key else { throw Failure(message: "backup is not set up") }
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        // Sprava never runs a binary it did not set up (architecture 3.5).
        if let pinned = settings().resticSHA256, Restic.sha256(of: binary) != pinned {
            throw Failure(message: "restic changed since backup was set up; set it up again to trust the new one")
        }
        return Restic(binary: binary, repository: URL(fileURLWithPath: path, isDirectory: true), key: key, support: support)
    }

    // MARK: - Setup

    /// Sets up the mirror at `primary` with the key Sprava holds. An existing repository must open with that key.
    public func setUp(primary: URL, iCloudKeychain: Bool) throws {
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        var s = settings()
        s.primary = primary.standardizedFileURL.path
        s.iCloudKeychain = iCloudKeychain
        s.resticSHA256 = Restic.sha256(of: binary)
        try save(s)
        let r = try engine(s.primary)
        if r.isInitialized() {
            _ = try r.snapshots()   // throws when the key does not open it
        } else {
            try r.initRepository()
        }
    }

    /// The second backup offloading requires: another cloud service's folder or an external disk.
    public func setSecond(_ folder: URL) throws {
        var s = settings()
        let primary = try engine(s.primary)
        s.second = folder.standardizedFileURL.path
        try save(s)
        let second = try engine(s.second)
        if second.isInitialized() { _ = try second.snapshots() } else { try second.initRepository(copyingParametersFrom: (primary.repository, primary.key)) }
    }

    // MARK: - Snapshots

    static let excludes = [".teka.lock", ".*.tmp", ".DS_Store"]

    /// A binder's stable backup id, kept inside the binder so it survives a restore elsewhere.
    public static func backupID(_ folder: URL) throws -> String {
        let url = folder.appendingPathComponent(".sprava/backup-id")
        if let text = try? String(contentsOf: url, encoding: .utf8), text.wholeMatch(of: /[0-9a-f]{32}\n?/) != nil {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let id = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        try AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
        try AtomicFile.write(Data((id + "\n").utf8), to: url)
        return id
    }

    @discardableResult
    public func backUp(_ folder: URL, now: Date = Date()) throws -> Restic.BackupResult {
        let id = try Self.backupID(folder)
        var st = state()
        do {
            let result = try engine(settings().primary).backup(folder, tags: ["sprava", "binder:\(id)"], excludes: Self.excludes)
            var rec = st.binders[id] ?? State.BinderRecord()
            if let snap = result.snapshot { rec.snapshot = snap }
            rec.at = ISOTime.string(now)
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
        _ = try engine(settings().primary).backup(support, tags: ["sprava", "sprava-state"],
                                                  excludes: Self.excludes + ["backup/cache", "backup/run", "backup/verify", "backup/peek"])
        var st = state()
        st.stateSnapshotAt = ISOTime.string(now)
        try save(st)
    }

    /// Weekly forget and prune per binder, by the retention rule; offloaded snapshots are always kept.
    public func applyRetention(now: Date = Date()) throws {
        let s = settings()
        let r = try engine(s.primary)
        for id in state().binders.keys.sorted() {
            try r.forget(tag: "binder:\(id)", keepLast: s.keepLast, keepWithinDays: s.keepWithinDays, keepMonthly: s.keepMonthly, keepYearly: s.keepYearly)
        }
        var st = state()
        st.lastForget = ISOTime.string(now)
        try save(st)
    }

    /// Weekly structure check; monthly, one twelfth of the data read back, rotating.
    public func check(readData: Bool, now: Date = Date()) throws {
        var st = state()
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

    /// Every file under `folder` that a snapshot holds, with its SHA-256.
    static func manifest(_ folder: URL) -> [String: String] {
        var out: [String: String] = [:]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { return out }
        let base = folder.standardizedFileURL.resolvingSymlinksInPath().path
        for case let url as URL in walker {
            let name = url.lastPathComponent
            if name == ".teka.lock" || name == ".DS_Store" || (name.hasPrefix(".") && name.hasSuffix(".tmp")) { continue }
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = url.standardizedFileURL.resolvingSymlinksInPath().path
            let rel = path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
            out[rel] = DocumentPaths.sha256(of: url) ?? "unreadable"
        }
        return out
    }

    // MARK: - Offload (docs/backup.md §6.1)

    public enum OffloadProgress: Equatable, Sendable {
        case waitingForICloud(Int)
        case done(Offloaded)
    }

    /// Offloads a finished binder. Runs every step it can now; when iCloud has not uploaded yet, it stops and
    /// `continueOffloads` finishes later.
    public func offload(_ folder: URL, deviceID: String, confirmOpenItems: Bool, now: Date = Date()) throws -> OffloadProgress {
        let s = settings()
        guard s.primary != nil else { throw Failure(message: "set up backup first") }
        guard s.second != nil else { throw Failure(message: "offloading needs a second backup; choose one in Backup settings") }
        let teka = Teka.read(folder)
        guard teka.isAdopted, Owner.device(of: folder) == deviceID else { throw Failure(message: "this binder is not managed by this Mac") }
        guard !ProposalStore.list(in: folder).contains(where: { $0.0.state == "proposed" }) else {
            throw Failure(message: "cards are waiting for this binder; approve or reject them first")
        }
        for sub in ["intake", "outgoing"] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(sub).path)) ?? []
            if names.contains(where: { !$0.hasPrefix(".") && !["mail", ".env", "state.json", "done"].contains($0) }) {
                throw Failure(message: "files are waiting in \(sub)/; deal with them first")
            }
        }
        let open = teka.items.filter { $0.declaredStatus != .done && !$0.isDismissed }
        if !open.isEmpty, !confirmOpenItems { throw NeedsConfirmation(openItems: open.map(\.title)) }

        let id = try Self.backupID(folder)
        var st = state()
        var job = st.offloads[id] ?? InProgress(path: folder.standardizedFileURL.path, stage: "start")
        if job.stage == "start" {
            // Nothing changed since a restore: the pinned snapshots are still the binder (§6.4), and the earlier
            // offload already recorded the person's confirmation.
            let unchanged = st.restored[id].map { $0.manifest == Self.manifest(folder) } ?? false
            if !open.isEmpty, !unchanged {
                // The person's confirmation goes into the binder's history before the snapshot.
                let entry = JSONObject([(key: "entry", value: .obj([("action", .str("offloaded")),
                                                                    ("title", .string("Offloaded with \(open.count) open item(s), confirmed")),
                                                                    ("date", .string(CalendarDate.today(now: now).description))]))])
                try TekaStore(folder: folder).apply([.init(op: "add_log_entry", args: entry,
                                                           actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
            }
            job.openItemsConfirmed = open.count
            let primary = try engine(s.primary)
            let manifest = Self.manifest(folder)
            if unchanged, let restored = st.restored[id] {
                job.snapshot = restored.snapshot
                job.secondSnapshot = restored.secondSnapshot
                job.stage = restored.secondSnapshot == nil ? "verified" : "copied"
            } else {
                let result = try primary.backup(folder, tags: ["sprava", "binder:\(id)", "offloaded"], excludes: Self.excludes, skipIfUnchanged: false)
                guard let snap = result.snapshot else { throw Failure(message: "the snapshot was not written") }
                job.snapshot = snap
                job.bytes = result.bytes
                job.stage = "snapshotted"
                st.offloads[id] = job
                try save(st)
                // Verify by restoring into a private temporary folder and comparing every file.
                let verify = dir.appendingPathComponent("verify/\(id)", isDirectory: true)
                try? FileManager.default.removeItem(at: verify)
                try AtomicFile.makePrivateFolder(verify)
                defer { try? FileManager.default.removeItem(at: verify) }
                try primary.restore(snap, into: verify)
                let restored = Self.manifest(verify)
                guard restored == manifest else {
                    let missing = Set(manifest.keys).subtracting(restored.keys).count
                    let differ = manifest.filter { restored[$0.key] != nil && restored[$0.key] != $0.value }.count
                    throw Failure(message: "the snapshot does not match the binder (\(missing) missing, \(differ) different); nothing was removed")
                }
                job.stage = "verified"
            }
            st.offloads[id] = job
            try save(st)
        }
        return try continueOffload(id, now: now)
    }

    func continueOffload(_ id: String, now: Date) throws -> OffloadProgress {
        let s = settings()
        var st = state()
        guard var job = st.offloads[id] else { throw Failure(message: "no offload in progress") }
        let primary = try engine(s.primary)
        if job.stage == "verified" || job.stage == "waiting_for_upload" {
            if case .waiting(let n) = Self.uploadStatus(of: primary.repository) {
                job.stage = "waiting_for_upload"
                st.offloads[id] = job
                try save(st)
                return .waitingForICloud(n)
            }
            let second = try engine(s.second)
            if job.secondSnapshot == nil {
                try second.copy(job.snapshot!, from: primary)
                let copies = try second.snapshots(tag: "binder:\(id)")
                guard let copy = copies.last else { throw Failure(message: "the copy to the second backup did not appear") }
                try? second.addTag("offloaded", to: copy.id)
                job.secondSnapshot = copy.id
            }
            job.stage = "copied"
            st.offloads[id] = job
            try save(st)
        }
        guard job.stage == "copied", let snap = job.snapshot else { throw Failure(message: "offload stopped at \(job.stage)") }
        let folder = URL(fileURLWithPath: job.path, isDirectory: true)
        let teka = Teka.read(folder)
        let record = Offloaded(
            backupID: id, name: teka.name, originalPath: job.path, snapshot: snap, secondSnapshot: job.secondSnapshot,
            bytes: job.bytes, at: ISOTime.string(now),
            summary: teka.catalog?["meta"]?["description"]?.stringValue ?? "",
            documents: (teka.catalog?["documents"]?.arrayValue ?? []).compactMap { d in
                guard let p = d["path"]?.stringValue else { return nil }
                return .init(title: d["title"]?.stringValue ?? p, path: p)
            },
            openItemsConfirmed: job.openItemsConfirmed)
        // The hub stops showing it, as for a binder at disclosure none.
        if HubLane.isSafeSegment(teka.name), let target = try? HubLane.spoolFile(HubLane.spoolRoot().appendingPathComponent("inbox"), teka.name, ".agenda.json") {
            try? FileManager.default.removeItem(at: target)
        }
        // To the Trash, so nothing is destroyed until the person empties it.
        try removeFolder(folder)
        try? ShelfStore(supportDirectory: support).remove(folder)
        st.offloads[id] = nil
        st.restored[id] = nil
        st.offloaded.removeAll { $0.backupID == id }
        st.offloaded.append(record)
        try save(st)
        return .done(record)
    }

    /// Finishes offloads that were waiting for iCloud.
    public func continueOffloads(now: Date = Date()) -> [String: Result<OffloadProgress, Failure>] {
        var out: [String: Result<OffloadProgress, Failure>] = [:]
        for id in state().offloads.keys.sorted() {
            do { out[id] = .success(try continueOffload(id, now: now)) } catch { out[id] = .failure(Failure(message: "\(error)")) }
        }
        return out
    }

    public func offloaded() -> [Offloaded] { state().offloaded }

    public func pendingOffloads() -> [(path: String, stage: String)] { state().offloads.values.map { ($0.path, $0.stage) }.sorted { $0.path < $1.path } }

    // MARK: - Restore (§6.2) and peek (§6.3)

    /// Restores an offloaded binder to its original folder (or `target`), from the mirror, else the second backup.
    public func restore(_ backupID: String, to target: URL? = nil, now: Date = Date()) throws -> URL {
        var st = state()
        guard let record = st.offloaded.first(where: { $0.backupID == backupID }) else { throw Failure(message: "no such offloaded binder") }
        let s = settings()
        let destination = (target ?? URL(fileURLWithPath: record.originalPath, isDirectory: true)).standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDir),
           !((try? FileManager.default.contentsOfDirectory(atPath: destination.path))?.isEmpty ?? true) {
            throw Failure(message: "\(destination.lastPathComponent) already exists there; choose another place")
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            try engine(s.primary).restore(record.snapshot, into: destination)
        } catch {
            guard let second = record.secondSnapshot else { throw error }
            try engine(s.second).restore(second, into: destination)
        }
        try? FileManager.default.removeItem(at: destination.appendingPathComponent(".teka.lock"))
        try? ShelfStore(supportDirectory: support).add(destination)
        st.restored[backupID] = State.Restored(snapshot: record.snapshot, secondSnapshot: record.secondSnapshot, manifest: Self.manifest(destination))
        st.offloaded.removeAll { $0.backupID == backupID }
        try save(st)
        return destination
    }

    /// One document of an offloaded binder, into a private temporary folder.
    public func peek(_ backupID: String, path: String) throws -> URL {
        guard let record = state().offloaded.first(where: { $0.backupID == backupID }) else { throw Failure(message: "no such offloaded binder") }
        guard record.documents.contains(where: { $0.path == path }), DocumentPaths.isSafe(path, forFiling: false) else {
            throw Failure(message: "that document is not in the binder")
        }
        let folder = dir.appendingPathComponent("peek/\(UUID().uuidString.prefix(8))", isDirectory: true)
        try AtomicFile.makePrivateFolder(folder)
        let file = folder.appendingPathComponent((path as NSString).lastPathComponent)
        let s = settings()
        do { try engine(s.primary).dump(record.snapshot, path: "/" + path, to: file) } catch {
            guard let second = record.secondSnapshot else { throw error }
            try engine(s.second).dump(second, path: "/" + path, to: file)
        }
        return file
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
        guard Self.manifest(target) == Self.manifest(folder) else { throw Failure(message: "the restored copy differs from the binder") }
        var st = state()
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
    }

    /// Hourly snapshots of each live binder this Mac manages (skipped when unchanged), Sprava's state daily,
    /// retention and a structure check weekly, a rotating read-back monthly. No binder lock is taken: every file
    /// a binder write touches is replaced by a rename or appended, so a snapshot taken during a write is a state
    /// the write protocol already recovers from after a crash (binder-v0 §6.9).
    public func maintain(rows: [ShelfRow], deviceID: String, now: Date = Date()) -> Maintenance {
        var m = Maintenance()
        guard isConfigured else { return m }
        func older(_ iso: String?, than seconds: TimeInterval) -> Bool {
            guard let iso, let d = ISOTime.date(iso) else { return true }
            return now.timeIntervalSince(d) > seconds
        }
        let st = state()
        for row in rows where row.teka.isAdopted && !row.teka.writesBlocked && Owner.device(of: row.folder) == deviceID {
            guard let id = try? Self.backupID(row.folder) else { continue }
            if st.offloads[id] != nil { continue }
            guard older(st.binders[id]?.at, than: 3600) else { continue }
            do {
                let r = try backUp(row.folder, now: now)
                if r.snapshot == nil { m.unchanged += 1 } else { m.snapshots += 1 }
            } catch {
                m.failed += 1
            }
        }
        if older(state().stateSnapshotAt, than: 86_400), (try? backUpState(now: now)) != nil { m.stateSnapshot = true }
        if older(state().lastForget, than: 7 * 86_400), (try? applyRetention(now: now)) != nil { m.retention = true }
        if older(state().lastCheck, than: 7 * 86_400) {
            let readData = older(state().lastReadData, than: 30 * 86_400)
            if (try? check(readData: readData, now: now)) != nil { m.checked = true } else { m.failed += 1 }
        }
        return m
    }

    // MARK: - Health

    public struct Status: Sendable {
        public var configured: Bool
        public var secondConfigured: Bool
        public var binders: [(id: String, at: String?, error: String?)]
        public var upload: Upload?
        public var lastCheck: String?
        public var lastDrill: String?
        public var offloaded: Int
        public var pending: Int
    }

    public func status(checkUpload: Bool = true) -> Status {
        let s = settings()
        let st = state()
        return Status(configured: s.primary != nil && key != nil, secondConfigured: s.second != nil,
                      binders: st.binders.sorted { $0.key < $1.key }.map { ($0.key, $0.value.at, $0.value.error) },
                      upload: checkUpload ? s.primary.map { Self.uploadStatus(of: URL(fileURLWithPath: $0)) } : nil,
                      lastCheck: st.lastCheck, lastDrill: st.lastDrill, offloaded: st.offloaded.count, pending: st.offloads.count)
    }
}

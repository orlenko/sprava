import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
import Hub
import Shelf
import SpravaKit

/// Backup, offload and restore (docs/backup.md). One restic repository in iCloud Drive holds a snapshot per
/// binder and one of Sprava's own state; a second repository elsewhere holds the copies offloading requires.
public struct Backup: Sendable {
    public let support: URL
    public let key: String?
    public let resticBinary: URL?
    /// How an offloaded binder leaves the Mac: the Trash, so nothing is destroyed until the person empties it.
    public let removeFolder: @Sendable (URL) throws -> Void
    /// The hub's spool, where an offloaded binder's slice is removed.
    public let hubSpool: URL
    /// Whether iCloud has uploaded a repository (`uploadStatus(of:)`; tests pass their own).
    public let uploadCheck: @Sendable (URL) -> Upload
    /// Runs right after restic has read a binder; tests use it to land a write during a snapshot.
    var afterSnapshot: (@Sendable () -> Void)?

    public init(support: URL, key: String? = BackupKey.load(), resticBinary: URL? = Restic.locate(),
                removeFolder: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                hubSpool: URL = HubLane.spoolRoot(), uploadCheck: @escaping @Sendable (URL) -> Upload = { Backup.uploadStatus(of: $0) }) {
        self.support = support
        self.key = key
        self.resticBinary = resticBinary
        self.removeFolder = removeFolder
        self.hubSpool = hubSpool
        self.uploadCheck = uploadCheck
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
        /// The mirror `snapshot` is in, since the mirror may change later (nil in older records).
        public var repository: String?
        public var secondSnapshot: String?
        /// The repository `secondSnapshot` is in, since the second backup may change later (nil in older records).
        public var secondRepository: String?
        public var bytes: Int64
        public var at: String
        public var summary: String
        public var documents: [Document]
        public var openItemsConfirmed: Int
        public struct Document: Codable, Sendable, Equatable { public var title: String; public var path: String }
    }

    struct InProgress: Codable, Equatable {
        var path: String
        var stage: String          // start, snapshotted, verified, waiting_for_upload, copied, leaving
        var snapshot: String?
        /// The mirror `snapshot` is in: a job whose mirror the person has since replaced starts over.
        var repository: String?
        var secondSnapshot: String?
        var secondRepository: String?
        var bytes: Int64 = 0
        var openItemsConfirmed = 0
        /// The digest of the manifest the snapshot was verified against (`digest(_:)`).
        var manifestSHA: String?
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
        /// Restores under way, by backup id: the destination, so an interrupted restore can be resumed (§6.2).
        var restoring: [String: String] = [:]
        struct BinderRecord: Codable, Equatable {
            var snapshot: String?
            var at: String?
            var bytes: Int64 = 0
            var error: String?
        }
        struct Restored: Codable, Equatable {
            var snapshot: String
            /// The mirror `snapshot` is in; "Offload again" reuses it only while that is still the mirror (nil: never).
            var repository: String?
            var secondSnapshot: String?
            var secondRepository: String?
            var manifest: [String: String]
        }
    }

    package var dir: URL { support.appendingPathComponent("backup", isDirectory: true) }
    package var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }

    /// The backup settings. Only a missing file is "not set up"; a file that exists but cannot be read or decoded
    /// throws, so backups never stop in silence and nothing saves over the person's choices (the second backup,
    /// retention).
    public func settings() throws -> Settings {
        var info = stat()
        if lstat(settingsURL.path, &info) != 0 {
            guard errno == ENOENT else { throw Failure(message: "backup settings cannot be read; nothing was changed (\(settingsURL.path))") }
            return Settings()
        }
        guard let data = try? Data(contentsOf: settingsURL), let s = try? JSONDecoder().decode(Settings.self, from: data) else {
            throw Failure(message: "backup settings are unreadable; nothing was changed (\(settingsURL.path))")
        }
        return s
    }

    func save(_ s: Settings) throws {
        try AtomicFile.makePrivateFolder(dir)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(s), to: settingsURL)
    }

    /// The backup's records. A missing file is a fresh state; a file that exists but cannot be read or decoded
    /// throws, so nothing ever saves over it: `offloaded` is the only way back to an offloaded binder. Only a missing
    /// directory entry is fresh: a link to a place that is away now (an unmounted disk) is unreadable, not empty.
    func state() throws -> State {
        do { return try StateFile.read(State.self, from: stateURL) ?? State() } catch {
            throw Failure(message: "backup state is unreadable; nothing was changed (\(stateURL.path))")
        }
    }

    func save(_ s: State) throws {
        try AtomicFile.makePrivateFolder(dir)
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(s), to: stateURL)
    }

    /// Throws when the settings cannot be read (`settings()`), which is not the same as not set up.
    public var isConfigured: Bool { get throws { try settings().primary != nil && key != nil } }

    /// The default mirror: a folder in the person's iCloud Drive.
    public static var defaultPrimary: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/Sprava Backup", isDirectory: true)
    }

    /// restic for the repository at `path`, pinned by the saved settings, or by `candidate` before they are saved.
    func engine(_ path: String?, settings candidate: Settings? = nil) throws -> Restic {
        guard let path, let key else { throw Failure(message: "backup is not set up") }
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        // Sprava never runs a binary it did not set up (architecture 3.5).
        if let pinned = try (candidate ?? settings()).resticSHA256, Restic.sha256(of: binary) != pinned {
            throw Failure(message: "restic changed since backup was set up; set it up again to trust the new one")
        }
        return Restic(binary: binary, repository: URL(fileURLWithPath: path, isDirectory: true), key: key, support: support)
    }

    // MARK: - Setup

    /// Sets up the mirror at `primary` with the key Sprava holds. An existing repository must open with that key.
    /// The settings name it only once it opens, so a failed change leaves the working mirror in place. Settings that
    /// cannot be read are never saved over. A mirror in or around the second backup is refused.
    public func setUp(primary: URL, iCloudKeychain: Bool) throws {
        var s = try settings()
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        s.primary = primary.standardizedFileURL.path
        s.iCloudKeychain = iCloudKeychain
        s.resticSHA256 = Restic.sha256(of: binary)
        // A new mirror must not share a fate with the second backup already chosen (§5), as setSecond requires.
        if let second = s.second { try Self.refuseSharedFate(URL(fileURLWithPath: second, isDirectory: true), primary: primary) }
        let r = try engine(s.primary, settings: s)
        if r.isInitialized() {
            _ = try r.snapshots()   // throws when the key does not open it
        } else {
            try r.initRepository()
        }
        try save(s)
    }

    /// The second backup offloading requires: another cloud service's folder or an external disk. It must not
    /// share a fate with the mirror (§5): not the mirror's folder, not in or around it, and not in iCloud Drive.
    public func setSecond(_ folder: URL) throws {
        var s = try settings()
        guard let primaryPath = s.primary else { throw Failure(message: "set up backup first") }
        try Self.refuseSharedFate(folder, primary: URL(fileURLWithPath: primaryPath, isDirectory: true))
        let primary = try engine(s.primary)
        s.second = folder.standardizedFileURL.path
        let second = try engine(s.second, settings: s)
        if second.isInitialized() { _ = try second.snapshots() } else { try second.initRepository(copyingParametersFrom: (primary.repository, primary.key)) }
        try save(s)
    }

    /// A path with symbolic links resolved, also for a folder not created yet (through its nearest existing parent).
    static func realPath(_ url: URL) -> String {
        var existing = url.standardizedFileURL
        var rest: [String] = []
        while !FileManager.default.fileExists(atPath: existing.path), existing.path != "/" {
            rest.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        return rest.reduce(existing.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
    }

    static func refuseSharedFate(_ second: URL, primary: URL) throws {
        let a = realPath(second), b = realPath(primary)
        if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
            throw Failure(message: "the second backup must be a folder of its own, not the iCloud mirror or a folder in or around it")
        }
        let iCloud = realPath(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents", isDirectory: true))
        if a == iCloud || a.hasPrefix(iCloud + "/") {
            throw Failure(message: "the second backup cannot be in iCloud Drive: losing the account would lose both copies; choose an external disk or another cloud service's folder")
        }
    }

    /// The same check on the saved settings, before an offload counts the two repositories as independent copies.
    func refuseSharedFate(_ s: Settings) throws {
        guard let primary = s.primary, let second = s.second else { return }
        try Self.refuseSharedFate(URL(fileURLWithPath: second, isDirectory: true), primary: URL(fileURLWithPath: primary, isDirectory: true))
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

    /// A binder's backup id when it already has one, for pages that only show it (the app's Health page). Never
    /// creates one, and refuses a `.sprava` folder or `backup-id` file that is a symbolic link: nil then.
    public static func existingBackupID(_ folder: URL) -> String? {
        let sprava = folder.appendingPathComponent(".sprava")
        var st = stat()
        guard lstat(sprava.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        guard case .ok(let data) = SafeFile.read(sprava.appendingPathComponent("backup-id"), limit: 64),
              let text = String(data: data, encoding: .utf8), text.wholeMatch(of: /[0-9a-f]{32}\n?/) != nil else { return nil }
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

    // MARK: - Offload (docs/backup.md §6.1)

    public enum OffloadProgress: Equatable, Sendable {
        case waitingForICloud(Int)
        case done(Offloaded)
    }

    /// Offloads a finished binder. Runs every step it can now; when iCloud has not uploaded yet, it stops, and the
    /// queued request runs it again later.
    public func offload(_ folder: URL, deviceID: String, confirmOpenItems: Bool, now: Date = Date()) throws -> OffloadProgress {
        let s = try settings()
        guard s.primary != nil else { throw Failure(message: "set up backup first") }
        guard s.second != nil else { throw Failure(message: "offloading needs a second backup; choose one in Backup settings") }
        // An offload that stopped after its folder went to the Trash only has its records left to finish.
        if !FileManager.default.fileExists(atPath: folder.path),
           let leaving = try state().offloads.first(where: { $0.value.path == folder.standardizedFileURL.path && $0.value.stage == "leaving" }) {
            return try continueOffload(leaving.key, now: now)
        }
        try refuseSharedFate(s)
        let teka = Teka.read(folder)
        guard teka.isAdopted, Owner.device(of: folder) == deviceID else { throw Failure(message: "this binder is not managed by this Mac") }
        // Its hub slice is named by its catalog, so a binder whose name differs from its folder's (an outside edit may
        // have given it another binder's name) or cannot be read is put right first (`removeHubSlice`).
        guard !teka.federationBlocked else {
            throw Failure(message: "this binder needs attention (its name or its catalog); put it right before offloading")
        }
        guard !ProposalStore.list(in: folder).contains(where: { $0.0.state == "proposed" }) else {
            throw Failure(message: "cards are waiting for this binder; approve or reject them first")
        }
        // Nothing may wait in intake/ or outgoing/. In intake/, `_converted/` is regenerable text, and `mail/` is
        // looked into: its messages and their attachment folders wait like any file, while a mail monitor's `.env`
        // and `state.json` are never filed (binder-v0 §3.3).
        func waiting(_ sub: String, except: Set<String>) -> Bool {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(sub).path)) ?? []
            return names.contains { !$0.hasPrefix(".") && !except.contains($0) }
        }
        if waiting("intake", except: ["mail", "_converted"]) || waiting("intake/mail", except: ["state.json"]) {
            throw Failure(message: "files are waiting in intake/; deal with them first")
        }
        if waiting("outgoing", except: []) { throw Failure(message: "files are waiting in outgoing/; deal with them first") }
        let open = teka.items.filter { $0.declaredStatus != .done && !$0.isDismissed }
        if !open.isEmpty, !confirmOpenItems { throw NeedsConfirmation(openItems: open.map(\.title)) }

        let id = try Self.backupID(folder)
        var st = try state()
        var job = st.offloads[id] ?? InProgress(path: folder.standardizedFileURL.path, stage: "start")
        // The binder stays writable while an offload waits for iCloud, which can take hours. One that changed since
        // its snapshot was verified (or never got that far) starts over, so what leaves the Mac is what the backups hold.
        // So does one whose snapshot is in a mirror the person has since replaced.
        if try job.stage == "snapshotted" || (job.stage != "start" && (job.manifestSHA != Self.digest(Self.manifest(folder)) || job.repository != s.primary)) {
            if job.stage == "leaving" { st.offloaded.removeAll { $0.backupID == id } }
            job = InProgress(path: job.path, stage: "start")
        }
        if job.stage == "start" {
            // Nothing changed since a restore: the pinned snapshots are still the binder (§6.4), and the earlier
            // offload already recorded the person's confirmation. Only while the mirror is the one the pinned snapshot
            // is in, and still holds it: a mirror the person has since replaced does not, so it is taken again.
            let primary = try engine(s.primary)
            let current = try Self.manifest(folder)
            let baseline = st.restored[id].flatMap { $0.repository != nil && $0.repository == s.primary && $0.manifest == current ? $0 : nil }
            let unchanged = try baseline.map { b in try primary.snapshots(tag: "binder:\(id)").contains { $0.id == b.snapshot } } ?? false
            if !open.isEmpty, !unchanged {
                // The person's confirmation goes into the binder's history before the snapshot.
                let entry = JSONObject([(key: "entry", value: .obj([("action", .str("offloaded")),
                                                                    ("title", .string("Offloaded with \(open.count) open item(s), confirmed")),
                                                                    ("date", .string(CalendarDate.today(now: now).description))]))])
                try TekaStore(folder: folder).apply([.init(op: "add_log_entry", args: entry,
                                                           actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
            }
            job.openItemsConfirmed = open.count
            let manifest = try Self.manifest(folder)
            job.manifestSHA = Self.digest(manifest)
            job.repository = s.primary
            if unchanged, let restored = st.restored[id] {
                job.snapshot = restored.snapshot
                // A copy in a second backup the person has since replaced, or no longer in it, does not count; it is
                // copied again.
                let copyHolds = try restored.secondSnapshot.map { copy in
                    try restored.secondRepository == s.second && engine(s.second).snapshots(tag: "binder:\(id)").contains { $0.id == copy }
                } ?? false
                job.secondSnapshot = copyHolds ? restored.secondSnapshot : nil
                job.secondRepository = copyHolds ? restored.secondRepository : nil
                job.stage = copyHolds ? "copied" : "verified"
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
                let restored = try Self.manifest(verify)
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
        let s = try settings()
        var st = try state()
        guard var job = st.offloads[id] else { throw Failure(message: "no offload in progress") }
        let folder = URL(fileURLWithPath: job.path, isDirectory: true)
        if job.stage == "leaving" { return try leave(id, folder: folder, &st) }
        // The settings may have changed while the offload waited. A snapshot in a mirror the person has since
        // replaced is not in the backups any more; a copy in a replaced second backup is made again; and two
        // repositories that now share a fate are not two copies.
        try refuseSharedFate(s)
        guard job.repository != nil, job.repository == s.primary else {
            st.offloads[id] = nil
            try save(st)
            throw Failure(message: "the mirror changed during the offload; nothing was removed. Offload again to back up into the new one")
        }
        if job.secondSnapshot != nil, job.secondRepository != s.second {
            job.secondSnapshot = nil
            job.secondRepository = nil
            if job.stage == "copied" { job.stage = "verified" }
        }
        let primary = try engine(s.primary)
        if job.stage == "verified" || job.stage == "waiting_for_upload" {
            if case .waiting(let n) = uploadCheck(primary.repository) {
                job.stage = "waiting_for_upload"
                st.offloads[id] = job
                try save(st)
                return .waitingForICloud(n)
            }
            try refuseIfChanged(id, folder: folder, job, &st)
            let second = try engine(s.second)
            if job.secondSnapshot == nil {
                try second.copy(job.snapshot!, from: primary)
                let copies = try second.snapshots(tag: "binder:\(id)")
                guard let copy = copies.last else { throw Failure(message: "the copy to the second backup did not appear") }
                try? second.addTag("offloaded", to: copy.id)
                job.secondSnapshot = copy.id
                job.secondRepository = s.second
            }
            job.stage = "copied"
            st.offloads[id] = job
            try save(st)
        }
        guard job.stage == "copied", let snap = job.snapshot else { throw Failure(message: "offload stopped at \(job.stage)") }
        try refuseIfChanged(id, folder: folder, job, &st)
        let teka = Teka.read(folder)
        let record = Offloaded(
            backupID: id, name: teka.name, originalPath: job.path, snapshot: snap, repository: job.repository,
            secondSnapshot: job.secondSnapshot, secondRepository: job.secondRepository, bytes: job.bytes, at: ISOTime.string(now),
            summary: teka.catalog?["meta"]?["description"]?.stringValue ?? "",
            documents: (teka.catalog?["documents"]?.arrayValue ?? []).compactMap { d in
                guard let p = d["path"]?.stringValue else { return nil }
                return .init(title: d["title"]?.stringValue ?? p, path: p)
            },
            openItemsConfirmed: job.openItemsConfirmed)
        // The hub stops showing it, as for a binder at disclosure none.
        try removeHubSlice(teka)
        // The record is kept before the folder goes, so a failure from here on can be finished, never lost.
        job.stage = "leaving"
        st.offloads[id] = job
        st.offloaded.removeAll { $0.backupID == id }
        st.offloaded.append(record)
        try save(st)
        return try leave(id, folder: folder, &st)
    }

    /// The last step: the folder goes to the Trash, so nothing is destroyed until the person empties it, and the
    /// Shelf forgets it. Runs again after an interruption, from the record kept before.
    func leave(_ id: String, folder: URL, _ st: inout State) throws -> OffloadProgress {
        guard var job = st.offloads[id], let record = st.offloaded.first(where: { $0.backupID == id }) else {
            throw Failure(message: "the offload's record is missing; nothing was removed")
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            // The last comparison and the move to the Trash run under the binder's write lock, so no approval can
            // land between them and leave with the folder while neither backup holds it.
            var removal: Error?
            try TekaStore(folder: folder).withLock {
                try refuseIfChanged(id, folder: folder, job, &st)
                do { try removeFolder(folder) } catch { removal = error }
            }
            if let error = removal {
                st.offloaded.removeAll { $0.backupID == id }
                job.stage = "copied"
                st.offloads[id] = job
                try? save(st)
                throw error
            }
        }
        try? ShelfStore(supportDirectory: support).remove(folder)
        st.offloads[id] = nil
        st.restored[id] = nil
        try save(st)
        return .done(record)
    }

    /// Stops an offload whose binder changed after its snapshot was verified: the job starts over next time.
    func refuseIfChanged(_ id: String, folder: URL, _ job: InProgress, _ st: inout State) throws {
        guard job.manifestSHA != Self.digest(try Self.manifest(folder)) else { return }
        st.offloads[id] = nil
        st.offloaded.removeAll { $0.backupID == id }
        try save(st)
        throw Failure(message: "the binder changed during the offload; nothing was removed. Offload again to back up the change")
    }

    /// Removes the binder's slice from the hub's spool. The slice is named by the catalog only for a binder that
    /// passes the hub's checks (its name is its folder's, as `HubLane.withdraw` requires); any other is refused, never
    /// guessed at, since the name might be another binder's slice. Only a slice that is already gone counts as
    /// removed: one that cannot be checked or removed (a spool that cannot be searched) stops the offload, which is
    /// retried, rather than leaving it on the hub with nothing to remove it later.
    func removeHubSlice(_ teka: Teka) throws {
        guard !teka.federationBlocked else {
            throw Failure(message: "this binder needs attention (its name or its catalog); it was not taken off the hub, and nothing was removed")
        }
        let target = try HubLane.spoolFile(hubSpool.appendingPathComponent("inbox"), teka.name, ".agenda.json")
        guard unlink(target.path) == 0 || errno == ENOENT else {
            let code = errno
            let reason = String(cString: strerror(code))
            throw Failure(message: "could not take the binder off the hub (\(reason)); the offload will retry")
        }
    }

    /// Finishes offloads that were waiting for iCloud.
    public func continueOffloads(now: Date = Date()) -> [String: Result<OffloadProgress, Failure>] {
        var out: [String: Result<OffloadProgress, Failure>] = [:]
        let ids: [String]
        do { ids = try state().offloads.keys.sorted() } catch { return ["state": .failure(Failure(message: "\(error)"))] }
        for id in ids {
            do { out[id] = .success(try continueOffload(id, now: now)) } catch { out[id] = .failure(Failure(message: "\(error)")) }
        }
        return out
    }

    public func offloaded() throws -> [Offloaded] { try state().offloaded }

    public func pendingOffloads() throws -> [(path: String, stage: String)] {
        try state().offloads.values.map { ($0.path, $0.stage) }.sorted { $0.path < $1.path }
    }

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
        try? ShelfStore(supportDirectory: support).add(destination)
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
        /// `state_snapshot`, `retention`, `check`, `offload`): each also counts in `failed` and stays due, so the next run tries it again.
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
        func due(_ field: (State) -> String?, _ seconds: TimeInterval) -> Bool {
            guard let st = try? state() else { return false }
            return older(field(st), than: seconds)
        }
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
        /// Set when the backup's state cannot be read; nothing else is shown from it then.
        public var stateError: String?
        /// Set when the backup settings cannot be read: backup then counts as neither set up nor ready for setup.
        public var settingsError: String?
    }

    public func status(checkUpload: Bool = true) -> Status {
        var s = Settings()
        var settingsError: String?
        do { s = try settings() } catch { settingsError = "\(error)" }
        var st = State()
        var stateError: String?
        do { st = try state() } catch { stateError = "\(error)" }
        return Status(configured: s.primary != nil && key != nil, secondConfigured: s.second != nil,
                      binders: st.binders.sorted { $0.key < $1.key }.map { ($0.key, $0.value.at, $0.value.error) },
                      upload: checkUpload ? s.primary.map { uploadCheck(URL(fileURLWithPath: $0)) } : nil,
                      lastCheck: st.lastCheck, lastDrill: st.lastDrill, offloaded: st.offloaded.count, pending: st.offloads.count,
                      stateError: stateError, settingsError: settingsError)
    }
}

// Missing keys take their defaults, so a field added later never makes an older state or settings file unreadable.

extension Backup.Settings {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        primary = try c.decodeIfPresent(String.self, forKey: .primary)
        second = try c.decodeIfPresent(String.self, forKey: .second)
        iCloudKeychain = try c.decodeIfPresent(Bool.self, forKey: .iCloudKeychain) ?? false
        resticSHA256 = try c.decodeIfPresent(String.self, forKey: .resticSHA256)
        keepLast = try c.decodeIfPresent(Int.self, forKey: .keepLast) ?? 30
        keepWithinDays = try c.decodeIfPresent(Int.self, forKey: .keepWithinDays) ?? 90
        keepMonthly = try c.decodeIfPresent(Int.self, forKey: .keepMonthly) ?? 24
        keepYearly = try c.decodeIfPresent(Int.self, forKey: .keepYearly) ?? 10
    }
}

extension Backup.State {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        binders = try c.decodeIfPresent([String: BinderRecord].self, forKey: .binders) ?? [:]
        stateSnapshotAt = try c.decodeIfPresent(String.self, forKey: .stateSnapshotAt)
        lastForget = try c.decodeIfPresent(String.self, forKey: .lastForget)
        lastCheck = try c.decodeIfPresent(String.self, forKey: .lastCheck)
        lastReadData = try c.decodeIfPresent(String.self, forKey: .lastReadData)
        readDataPart = try c.decodeIfPresent(Int.self, forKey: .readDataPart) ?? 0
        lastDrill = try c.decodeIfPresent(String.self, forKey: .lastDrill)
        offloads = try c.decodeIfPresent([String: Backup.InProgress].self, forKey: .offloads) ?? [:]
        offloaded = try c.decodeIfPresent([Backup.Offloaded].self, forKey: .offloaded) ?? []
        restored = try c.decodeIfPresent([String: Restored].self, forKey: .restored) ?? [:]
        restoring = try c.decodeIfPresent([String: String].self, forKey: .restoring) ?? [:]
    }
}

extension Backup.State.BinderRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
        at = try c.decodeIfPresent(String.self, forKey: .at)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        error = try c.decodeIfPresent(String.self, forKey: .error)
    }
}

extension Backup.InProgress {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        stage = try c.decode(String.self, forKey: .stage)
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
        repository = try c.decodeIfPresent(String.self, forKey: .repository)
        secondSnapshot = try c.decodeIfPresent(String.self, forKey: .secondSnapshot)
        secondRepository = try c.decodeIfPresent(String.self, forKey: .secondRepository)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        openItemsConfirmed = try c.decodeIfPresent(Int.self, forKey: .openItemsConfirmed) ?? 0
        manifestSHA = try c.decodeIfPresent(String.self, forKey: .manifestSHA)
    }
}

extension Backup.Offloaded {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        backupID = try c.decode(String.self, forKey: .backupID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        originalPath = try c.decode(String.self, forKey: .originalPath)
        snapshot = try c.decode(String.self, forKey: .snapshot)
        repository = try c.decodeIfPresent(String.self, forKey: .repository)
        secondSnapshot = try c.decodeIfPresent(String.self, forKey: .secondSnapshot)
        secondRepository = try c.decodeIfPresent(String.self, forKey: .secondRepository)
        bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
        at = try c.decodeIfPresent(String.self, forKey: .at) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        documents = try c.decodeIfPresent([Document].self, forKey: .documents) ?? []
        openItemsConfirmed = try c.decodeIfPresent(Int.self, forKey: .openItemsConfirmed) ?? 0
    }
}

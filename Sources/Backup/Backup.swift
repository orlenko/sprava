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
    /// Runs at each durable step boundary of a multi-step operation, named; tests take an image of the disk there,
    /// as a crash would leave it, and run the operation again from that image.
    var atStep: (@Sendable (String) -> Void)?

    func step(_ name: String) { atStep?(name) }

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
        /// The second backup's own structure check, kept apart so a second backup that is away stays due.
        var lastSecondCheck: String?
        var lastReadData: String?
        var readDataPart = 0
        var lastDrill: String?
        var offloads: [String: InProgress] = [:]
        var offloaded: [Offloaded] = []
        var restored: [String: Restored] = [:]
        /// Restores under way, by backup id: the destination, so an interrupted restore can be resumed (§6.2).
        var restoring: [String: String] = [:]
        /// Restores whose files are all in place and verified, by backup id. From here a retry only finishes the
        /// bookkeeping and never restores files again: the binder may already be live, and changed since.
        var restoredContents: [String: RestoredContents] = [:]
        /// Rewrites under way, journaled before restic runs: `rewrite --forget` deletes the original snapshots before
        /// Sprava can rename them in its records, so a rewrite cut off is reconciled through the new snapshots'
        /// `original` ids (`reconcileRewrites`).
        var rewrites: [Rewrite] = []
        /// Documents deleted for good that the backups are to forget, waiting or done (`forgetDocument`).
        var forgetting: [Forgetting] = []
        /// Tombstones of finished forgetting requests no longer shown: which deletion, in which binder, at which path.
        var forgotten: [Forgotten] = []
        struct Forgotten: Codable, Equatable {
            var request: String
            var backupID: String
            var path: String
            var done: String
        }
        struct BinderRecord: Codable, Equatable {
            /// The folder that holds this backup id. A copy of the folder carries the same id; while both are there,
            /// neither backup nor forgetting runs for the copy (`claim`).
            var path: String?
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
            /// The offloaded snapshot's size, so "Offload again" records it rather than nothing.
            var bytes: Int64?
        }
        struct RestoredContents: Codable, Equatable {
            var path: String
            /// The baseline a later offload compares with, taken right after restic verified the files.
            var baseline: Restored?
            /// The private folder the files were restored and verified in, while they wait to be moved to `path`;
            /// nil once they are there (and in older records, which restored in place).
            var staging: String?
        }
        struct Rewrite: Codable, Equatable {
            var repository: String
            var tag: String
            /// The snapshots carrying `tag` before the rewrite ran.
            var before: [String]
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
        /// Documents deleted for good: when the backups stopped holding each, or why they still do.
        public var forgetting: [Forgetting] = []
        /// The second backup's last structure check (nil: none yet, or no second backup).
        public var lastSecondCheck: String? = nil
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
                      stateError: stateError, settingsError: settingsError, forgetting: st.forgetting,
                      lastSecondCheck: st.lastSecondCheck)
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
        lastSecondCheck = try c.decodeIfPresent(String.self, forKey: .lastSecondCheck)
        lastReadData = try c.decodeIfPresent(String.self, forKey: .lastReadData)
        readDataPart = try c.decodeIfPresent(Int.self, forKey: .readDataPart) ?? 0
        lastDrill = try c.decodeIfPresent(String.self, forKey: .lastDrill)
        offloads = try c.decodeIfPresent([String: Backup.InProgress].self, forKey: .offloads) ?? [:]
        offloaded = try c.decodeIfPresent([Backup.Offloaded].self, forKey: .offloaded) ?? []
        restored = try c.decodeIfPresent([String: Restored].self, forKey: .restored) ?? [:]
        restoring = try c.decodeIfPresent([String: String].self, forKey: .restoring) ?? [:]
        restoredContents = try c.decodeIfPresent([String: RestoredContents].self, forKey: .restoredContents) ?? [:]
        rewrites = try c.decodeIfPresent([Rewrite].self, forKey: .rewrites) ?? []
        forgetting = try c.decodeIfPresent([Backup.Forgetting].self, forKey: .forgetting) ?? []
        forgotten = try c.decodeIfPresent([Forgotten].self, forKey: .forgotten) ?? []
    }
}

extension Backup.State.BinderRecord {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path)
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

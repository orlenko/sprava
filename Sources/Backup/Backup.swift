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
    /// Whether a second repository is on an independent destination: an external volume or a supported non-iCloud
    /// file-provider root. Tests substitute this because their repositories deliberately live on one temporary disk.
    let secondLocationCheck: @Sendable (URL) -> Bool
    /// Runs right after restic has read a binder; tests use it to land a write during a snapshot.
    var afterSnapshot: (@Sendable () -> Void)?
    /// Runs at each durable step boundary of a multi-step operation, named; tests take an image of the disk there,
    /// as a crash would leave it, and run the operation again from that image.
    var atStep: (@Sendable (String) -> Void)?
    /// Flushes the parent after a restored directory is renamed into place. Tests replace it to prove state is not
    /// advanced when the durability barrier fails.
    var flushRestoreParent: @Sendable (URL) throws -> Void

    func step(_ name: String) { atStep?(name) }

    public init(support: URL, key: String? = BackupKey.load(), resticBinary: URL? = Restic.locate(),
                removeFolder: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
                hubSpool: URL = HubLane.spoolRoot(), uploadCheck: @escaping @Sendable (URL) -> Upload = { Backup.uploadStatus(of: $0) }) {
        self.init(support: support, key: key, resticBinary: resticBinary, removeFolder: removeFolder, hubSpool: hubSpool,
                  uploadCheck: uploadCheck, secondLocationCheck: { Backup.isIndependentSecondLocation($0) })
    }

    /// Test seam for repositories that deliberately share a temporary volume. Production callers always use the
    /// public initializer and the real independent-destination check.
    init(support: URL, key: String?, resticBinary: URL? = Restic.locate(),
         removeFolder: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) },
         hubSpool: URL = HubLane.spoolRoot(), uploadCheck: @escaping @Sendable (URL) -> Upload,
         secondLocationCheck: @escaping @Sendable (URL) -> Bool) {
        self.support = support
        self.key = key
        self.resticBinary = resticBinary
        self.removeFolder = removeFolder
        self.hubSpool = hubSpool
        self.uploadCheck = uploadCheck
        self.secondLocationCheck = secondLocationCheck
        flushRestoreParent = { try AtomicFile.flushFolder($0, step: "flush restored binder's parent") }
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
        /// The binder folder's own permissions and extended attributes, which its snapshots do not hold; a restore
        /// puts them back (nil in older records).
        public var rootMetadata: RootMetadata? = nil
        public struct Document: Codable, Sendable, Equatable { public var title: String; public var path: String }
    }

    struct InProgress: Codable, Equatable {
        var path: String
        var stage: String          // start, snapshotted, verified, waiting_for_upload, copied, leaving, abandoning
        var snapshot: String?
        /// The mirror `snapshot` is in: a job whose mirror the person has since replaced starts over.
        var repository: String?
        var secondSnapshot: String?
        var secondRepository: String?
        var bytes: Int64 = 0
        var openItemsConfirmed = 0
        /// The digest of the manifest the snapshot was verified against (`digest(_:)`).
        var manifestSHA: String?
        /// The binder folder's own metadata as it was then; a change to it is a change to the binder.
        var root: RootMetadata?
        /// Set once a snapshot of Sprava's state holding the offload record is in the mirror (`leave`), so a retry
        /// while iCloud uploads it only waits, and adds no snapshot of its own for iCloud to upload in turn.
        var stateSaved = false
        /// The restored baseline's old retention pins are gone. Saved before the live folder leaves, so a retry never
        /// needs an old, now-disconnected repository after the binder has already moved to the Trash.
        var oldPinsRemoved = false
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
        /// The second backup's read-back rotation advances only when that repository succeeds.
        var lastSecondReadData: String?
        var secondReadDataPart = 0
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
            /// Every repository that may hold this binder's snapshots. Kept after destinations and offload records
            /// change, so expunging a document can remove it from every old copy too.
            var repositories: [String] = []
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
            /// The binder folder's own metadata as the restore left it (`RootMetadata.entry`); nil: never unchanged.
            var rootEntry: String?
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
            /// The journal has been snapshotted into the iCloud mirror. It may still be waiting for upload.
            var stateSaved: Bool? = nil
            /// Which mirror holds that state snapshot. A mirror change requires a new checkpoint before rewriting.
            var stateRepository: String? = nil
            /// `rewrite --forget` may have begun. Explicitly false means it is still waiting for the journal upload;
            /// nil is an older journal, which was always written immediately before the rewrite.
            var started: Bool? = nil
        }
    }

    package var dir: URL { support.appendingPathComponent("backup", isDirectory: true) }
    package var settingsURL: URL { dir.appendingPathComponent("settings.json") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }

    /// The backup settings. Only a missing file is "not set up"; a file that exists but cannot be read or decoded
    /// throws, so backups never stop in silence and nothing saves over the person's choices (the second backup,
    /// retention).
    public func settings() throws -> Settings {
        let data: Data
        switch SafeFile.read(settingsURL, limit: 1024 * 1024) {
        case .missing:
            // SafeFile also reports ENOTDIR as missing. Only an actually absent settings entry is fresh; a regular
            // file where backup/ should be is damaged state and must stop maintenance rather than disable it quietly.
            var info = stat()
            guard lstat(settingsURL.path, &info) != 0, errno == ENOENT else {
                throw Failure(message: "backup settings cannot be read; nothing was changed (\(settingsURL.path))")
            }
            return Settings()
        case .ok(let read):
            data = read
        case .refused, .unreadable:
            throw Failure(message: "backup settings cannot be read; nothing was changed (\(settingsURL.path))")
        }
        guard let s = try? JSONDecoder().decode(Settings.self, from: data) else {
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
        // Unlike small settings, this state contains complete manifests for restored binders. Keep a defensive cap,
        // but one large enough for many legitimate manifests written by `save(State)` itself.
        switch SafeFile.read(stateURL, limit: 256 * 1024 * 1024) {
        case .missing:
            // SafeFile also maps ENOTDIR to missing. Damaged parent state is never a fresh backup state.
            var info = stat()
            guard lstat(stateURL.path, &info) != 0, errno == ENOENT else {
                throw Failure(message: "backup state is unreadable; nothing was changed (\(stateURL.path))")
            }
            return State()
        case .ok(let data):
            guard let state = try? JSONDecoder().decode(State.self, from: data) else {
                throw Failure(message: "backup state is unreadable; nothing was changed (\(stateURL.path))")
            }
            return state
        case .refused, .unreadable:
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
        return Restic(binary: binary, repository: URL(fileURLWithPath: path, isDirectory: true), key: key, support: support,
                      expectedSHA256: try (candidate ?? settings()).resticSHA256)
    }

    // MARK: - Setup

    /// Sets up the mirror at `primary` with the key Sprava holds. An existing repository must open with that key.
    /// The settings name it only once it opens, so a failed change leaves the working mirror in place. Settings that
    /// cannot be read are never saved over. A mirror in or around the second backup is refused.
    public func setUp(primary: URL, iCloudKeychain: Bool) throws {
        var s = try settings()
        let oldPrimary = s.primary
        guard let binary = resticBinary else { throw Failure(message: "restic is missing from this installation") }
        s.primary = primary.standardizedFileURL.path
        s.iCloudKeychain = iCloudKeychain
        // The pin is what keeps every later run to this restic (`engine`): a binary that cannot be read for it is refused.
        guard let digest = Restic.sha256(of: binary) else {
            throw Failure(message: "restic cannot be read to check it (\(binary.path)); nothing was changed")
        }
        s.resticSHA256 = digest
        // A new mirror must not share a fate with the second backup already chosen (§5), as setSecond requires.
        if let second = s.second { try refuseSharedFate(URL(fileURLWithPath: second, isDirectory: true), primary: primary) }
        let r = try engine(s.primary, settings: s)
        if r.isInitialized() {
            _ = try r.snapshots()   // throws when the key does not open it
        } else {
            try r.initRepository()
        }
        guard uploadCheck(r.repository) != .notInICloud else {
            throw Failure(message: "the backup mirror must be in iCloud Drive; nothing was changed")
        }
        // States written before repository history was recorded know their last ordinary snapshot only through the
        // old setting. Preserve that destination before replacing it. Saving this first is harmless if saving the
        // setting then fails; the old repository really may hold those snapshots.
        if let oldPrimary, oldPrimary != s.primary {
            var st = try state()
            // Older drills and interrupted first backups may have written snapshots without recording their ids, so
            // every claimed binder is a possible owner in the old repository.
            for id in Array(st.binders.keys) {
                st.rememberRepositories([oldPrimary], for: id)
            }
            // Record the candidate before copying. If migration is interrupted after restic writes but before its id
            // is recorded, document expunging still discovers that repository later.
            for record in st.offloaded {
                st.rememberRepositories([s.primary], for: record.backupID)
            }
            try save(st)
            step("primary.migration.recorded")

            // An offloaded binder has no live folder to back up into the replacement later. Copy every pinned
            // snapshot now, using either its old mirror or its independently recorded second copy as the source,
            // then restore and compare it before making the new mirror active.
            for i in st.offloaded.indices {
                let record = st.offloaded[i]
                let choices: [(String?, String?)] = [
                    (record.repository ?? oldPrimary, record.snapshot),
                    (record.secondRepository ?? s.second, record.secondSnapshot),
                    // A previous attempt may have copied either source and stopped before updating the record.
                    (s.primary, record.snapshot),
                    (s.primary, record.secondSnapshot),
                ]
                var source: (Restic, Restic.Snapshot, String)?
                for (repository, snapshot) in choices {
                    guard let repository, let snapshot, let candidate = try? engine(repository, settings: s),
                          let found = try? candidate.snapshots(tag: "binder:\(record.backupID)").first(where: {
                              $0.id == snapshot && $0.tags.contains("offloaded")
                          }),
                          let manifest = try? restoredManifest(found.id, from: candidate,
                                                               id: "primary-source-\(record.backupID)")
                    else { continue }
                    source = (candidate, found, Self.digest(manifest))
                    break
                }
                guard let (sourceRepository, sourceSnapshot, expected) = source else {
                    throw Failure(message: "neither pinned copy of \(record.name) can be read; the mirror was not changed")
                }
                if Self.realPath(sourceRepository.repository) != Self.realPath(r.repository) {
                    try r.copy(sourceSnapshot.id, from: sourceRepository)
                    step("primary.migration.copied")
                }
                let candidates = try r.snapshots(tag: "binder:\(record.backupID)")
                var verified: Restic.Snapshot?
                for candidate in candidates.sorted(by: { ($0.id == sourceSnapshot.id) && ($1.id != sourceSnapshot.id) })
                    where candidate.tags.contains("offloaded") {
                    if let manifest = try? restoredManifest(candidate.id, from: r, id: "primary-copy-\(record.backupID)"),
                       Self.digest(manifest) == expected {
                        verified = candidate
                        break
                    }
                }
                guard let copy = verified else {
                    throw Failure(message: "the pinned copy of \(record.name) could not be verified in the new mirror; the mirror was not changed")
                }
                st.offloaded[i].snapshot = copy.id
                st.offloaded[i].repository = s.primary
                if st.binders[record.backupID]?.snapshot == record.snapshot {
                    st.binders[record.backupID]?.snapshot = copy.id
                }
            }
            try save(st)
            step("primary.migration.finished")

            if !st.offloaded.isEmpty {
                // The repository must also carry the only catalog of those offloaded binders before the setting
                // points at it. A crash after this checkpoint can recover both their data and their records.
                _ = try r.backup(support, tags: ["sprava", "sprava-state"], excludes: Self.excludes + stateExcludes())
                step("primary.migration.state")
            }
        }
        try save(s)
    }

    /// The second backup offloading requires: another cloud service's folder or an external disk. It must not
    /// share a fate with the mirror (§5): not the mirror's folder, not in or around it, and not in iCloud Drive.
    public func setSecond(_ folder: URL) throws {
        var s = try settings()
        guard let primaryPath = s.primary else { throw Failure(message: "set up backup first") }
        let oldSecond = s.second
        try refuseSharedFate(folder, primary: URL(fileURLWithPath: primaryPath, isDirectory: true))
        let primary = try engine(s.primary)
        s.second = folder.standardizedFileURL.path
        let second = try engine(s.second, settings: s)
        if second.isInitialized() { _ = try second.snapshots() } else { try second.initRepository(copyingParametersFrom: (primary.repository, primary.key)) }
        if oldSecond != s.second {
            var st = try state()
            // A copy must never land in a repository that document expunging cannot discover. Record every possible
            // destination before the first copy; a path that ultimately receives nothing is harmless history.
            for record in st.offloaded {
                st.rememberRepositories([s.second], for: record.backupID)
            }
            if let oldSecond {
                // Older states may name the former second only in settings. Preserve it before migration can fail.
                for id in Array(st.binders.keys) {
                    st.rememberRepositories([oldSecond], for: id)
                }
            }
            try save(st)
            step("second.migration.recorded")
            // An offloaded binder has no live copy on this Mac. Before the setting can leave its former second
            // repository behind, copy every such pinned snapshot from its recorded mirror into the replacement and
            // read it back. A retired or disconnected old second disk is therefore not needed for the migration.
            for i in st.offloaded.indices {
                let record = st.offloaded[i]
                let source = try engine(record.repository ?? primaryPath)
                let tagged = try source.snapshots(tag: "binder:\(record.backupID)")
                guard let original = tagged.first(where: { $0.id == record.snapshot }), original.tags.contains("offloaded") else {
                    throw Failure(message: "the pinned mirror snapshot for \(record.name) is missing; the second backup was not changed")
                }
                let expected = try Self.digest(restoredManifest(original.id, from: source, id: "second-source-\(record.backupID)"))
                try second.copy(original.id, from: source)
                step("second.migration.copied")
                let candidates = try second.snapshots(tag: "binder:\(record.backupID)")
                var verified: Restic.Snapshot?
                for candidate in candidates.reversed() where candidate.tags.contains("offloaded") {
                    if let manifest = try? restoredManifest(candidate.id, from: second, id: "second-copy-\(record.backupID)"),
                       Self.digest(manifest) == expected {
                        verified = candidate
                        break
                    }
                }
                guard let copy = verified else {
                    throw Failure(message: "the pinned copy of \(record.name) could not be verified in the new second backup; the setting was not changed")
                }
                st.offloaded[i].secondSnapshot = copy.id
                st.offloaded[i].secondRepository = s.second
            }
            try save(st)
        }
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

    /// A supported independent destination: any folder below macOS's File Provider root for non-iCloud services,
    /// or a folder whose nearest existing ancestor is on a non-internal volume. An arbitrary folder on the startup
    /// disk is not a second backup: losing the Mac would lose both repositories.
    static func isIndependentSecondLocation(_ url: URL) -> Bool {
        let destination = realPath(url)
        let providers = realPath(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/CloudStorage", isDirectory: true))
        if destination.hasPrefix(providers + "/") {
            // The first component is the provider's macOS-managed root. Requiring it to exist prevents a made-up
            // `CloudStorage/Foo` path from being created as an ordinary local folder and mistaken for a synced copy.
            let relative = destination.dropFirst(providers.count + 1)
            guard let providerName = relative.split(separator: "/").first else { return false }
            var provider = stat()
            let root = URL(fileURLWithPath: providers, isDirectory: true).appendingPathComponent(String(providerName), isDirectory: true)
            return lstat(root.path, &provider) == 0 && provider.st_mode & S_IFMT == S_IFDIR
        }

        var existing = URL(fileURLWithPath: destination, isDirectory: true)
        var info = stat()
        while lstat(existing.path, &info) != 0, existing.path != "/" {
            existing.deleteLastPathComponent()
        }
        guard lstat(existing.path, &info) == 0,
              let values = try? existing.resourceValues(forKeys: [.volumeIsInternalKey]),
              let internalVolume = values.volumeIsInternal else { return false }
        return !internalVolume
    }

    func refuseSharedFate(_ second: URL, primary: URL) throws {
        let a = Self.realPath(second), b = Self.realPath(primary)
        if a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") {
            throw Failure(message: "the second backup must be a folder of its own, not the iCloud mirror or a folder in or around it")
        }
        let iCloud = Self.realPath(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents", isDirectory: true))
        if a == iCloud || a.hasPrefix(iCloud + "/") {
            throw Failure(message: "the second backup cannot be in iCloud Drive: losing the account would lose both copies; choose an external disk or another cloud service's folder")
        }
        guard secondLocationCheck(second) else {
            throw Failure(message: "the second backup must be on an external disk or in another cloud service's folder; a folder on this Mac is not an independent copy")
        }
    }

    /// The same check on the saved settings, before an offload counts the two repositories as independent copies.
    func refuseSharedFate(_ s: Settings) throws {
        guard let primary = s.primary, let second = s.second else { return }
        try refuseSharedFate(URL(fileURLWithPath: second, isDirectory: true), primary: URL(fileURLWithPath: primary, isDirectory: true))
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
        lastSecondReadData = try c.decodeIfPresent(String.self, forKey: .lastSecondReadData)
        secondReadDataPart = try c.decodeIfPresent(Int.self, forKey: .secondReadDataPart) ?? 0
        lastDrill = try c.decodeIfPresent(String.self, forKey: .lastDrill)
        offloads = try c.decodeIfPresent([String: Backup.InProgress].self, forKey: .offloads) ?? [:]
        offloaded = try c.decodeIfPresent([Backup.Offloaded].self, forKey: .offloaded) ?? []
        restored = try c.decodeIfPresent([String: Restored].self, forKey: .restored) ?? [:]
        restoring = try c.decodeIfPresent([String: String].self, forKey: .restoring) ?? [:]
        restoredContents = try c.decodeIfPresent([String: RestoredContents].self, forKey: .restoredContents) ?? [:]
        rewrites = try c.decodeIfPresent([Rewrite].self, forKey: .rewrites) ?? []
        forgetting = try c.decodeIfPresent([Backup.Forgetting].self, forKey: .forgetting) ?? []
        forgotten = try c.decodeIfPresent([Forgotten].self, forKey: .forgotten) ?? []
        // Fold every repository named by older state into the durable per-binder history before its transient record
        // can later be replaced or removed.
        for record in offloaded {
            rememberRepositories([record.repository, record.secondRepository], for: record.backupID)
        }
        for (id, job) in offloads {
            rememberRepositories([job.repository, job.secondRepository], for: id)
        }
        for (id, record) in restored {
            rememberRepositories([record.repository, record.secondRepository], for: id)
        }
        for (id, contents) in restoredContents {
            rememberRepositories([contents.baseline?.repository, contents.baseline?.secondRepository], for: id)
        }
        for request in forgetting {
            rememberRepositories(request.scopes.map { Optional($0.repository) }, for: request.backupID)
        }
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
        repositories = try c.decodeIfPresent([String].self, forKey: .repositories) ?? []
    }
}

extension Backup.State {
    mutating func rememberRepositories(_ repositories: [String?], for id: String) {
        var record = binders[id] ?? BinderRecord()
        for repository in repositories.compactMap({ $0 }) where !record.repositories.contains(repository) {
            record.repositories.append(repository)
        }
        binders[id] = record
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
        root = try c.decodeIfPresent(Backup.RootMetadata.self, forKey: .root)
        stateSaved = try c.decodeIfPresent(Bool.self, forKey: .stateSaved) ?? false
        oldPinsRemoved = try c.decodeIfPresent(Bool.self, forKey: .oldPinsRemoved) ?? false
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
        rootMetadata = try c.decodeIfPresent(Backup.RootMetadata.self, forKey: .rootMetadata)
    }
}

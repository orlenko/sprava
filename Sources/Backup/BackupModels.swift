import CryptoKit
import Foundation
import SpravaKit

extension Backup {
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
        var stage: String
        var snapshot: String?
        /// The mirror `snapshot` is in: a job whose mirror the person has since replaced starts over.
        var repository: String?
        var secondSnapshot: String?
        var secondRepository: String?
        var bytes: Int64 = 0
        var openItemsConfirmed = 0
        /// The ids of the open items the person confirmed, so one that is new by the time the binder leaves, even
        /// in place of one closed meanwhile, needs confirming too.
        var confirmedItems: [String]?
        /// The digest of the manifest the snapshot was verified against (`digest(_:)`).
        var manifestSHA: String?
        /// The already-pinned snapshots when a new offload snapshot was about to be written. If the process stops
        /// after restic commits but before its id is saved, the new pin is the set difference and can be recovered.
        var pinsBeforeWrite: [String]?
        /// The same for the copy into the second backup (`secondRepository`), saved before `restic copy` runs, so a
        /// copy that landed before its id was saved is found, or unpinned when the offload is abandoned.
        var secondPinsBefore: [String]?
        /// The binder folder's own metadata as it was then; a change to it is a change to the binder.
        var root: RootMetadata?
        /// Set once a snapshot of Sprava's state holding the offload record is in the mirror (`leave`), so a retry
        /// while iCloud uploads it only waits, and adds no snapshot of its own for iCloud to upload in turn.
        var stateSaved = false
        /// The restored baseline's old retention pins are gone. Saved before the live folder leaves, so a retry never
        /// needs an old, now-disconnected repository after the binder has already moved to the Trash.
        var oldPinsRemoved = false
        /// The binder folder itself (links resolved), saved before it goes to the Trash: a retry knows it went, and
        /// takes it off the Shelf, also when the path the offload has was a link now gone.
        var leavingTarget: String?
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
        /// A drill of the second backup, kept apart: it says nothing about restoring from the mirror.
        var lastSecondDrill: String?
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
        /// Reassignments under way (`giveOwnBackupID`), by the copy's resolved path: the id it held and the new one,
        /// recorded before the new one is written, so a retry finishes it instead of minting another. Several copies
        /// of one binder each keep their own.
        var reassigning: [String: Reassignment] = [:]

        struct Reassignment: Codable, Equatable {
            var from: String
            var id: String
            /// The copy's folder ("device:inode"): a retry reuses the id only for that same folder, never for another
            /// put at its path after it moved away.
            var folder: String?
        }
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

    /// The binder folder's own permission bits and extended attributes, which a restore reapplies.
    public struct RootMetadata: Codable, Equatable, Sendable {
        public var mode: Int
        public var attributes: [String: Data]

        /// How the change checks compare it, as `manifest` does an entry's metadata.
        var entry: String {
            var hasher = SHA256()
            for name in attributes.keys.sorted() {
                let value = attributes[name] ?? Data()
                hasher.update(data: Data(name.utf8) + [0] + withUnsafeBytes(of: UInt64(value.count).bigEndian) { Data($0) } + value)
            }
            return "mode:" + String(mode, radix: 8) + (attributes.isEmpty ? "" : " xattr:" + hasher.finalize().map { String(format: "%02x", $0) }.joined())
        }
    }

    public struct Forgetting: Codable, Sendable, Equatable {
        public var backupID: String
        /// The document's path inside the binder ("documents/invented.pdf").
        public var path: String
        public var at: String
        /// When no repository held it any more; nil while it waits.
        public var done: String?
        /// Why the last attempt failed; it is tried again at the next scheduled run.
        public var error: String?
        /// The moment of the request on this Mac's clock, which also dates restic's snapshots.
        public var requested: Double?
        /// Each repository that may hold the binder's snapshots, with the snapshots the request covers there.
        public var scopes: [Scope] = []
        /// The caller's id for this deletion; later deletions at the same path receive a different id.
        public var request: String?

        public struct Scope: Codable, Sendable, Equatable {
            public var repository: String
            public var snapshots: [String]
            public var done: Bool
            public var error: String?
        }

        init(backupID: String, path: String, at: String, requested: Double?, scopes: [Scope], request: String) {
            self.backupID = backupID
            self.path = path
            self.at = at
            self.requested = requested
            self.scopes = scopes
            self.request = request
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            backupID = try c.decode(String.self, forKey: .backupID)
            path = try c.decode(String.self, forKey: .path)
            at = try c.decode(String.self, forKey: .at)
            done = try c.decodeIfPresent(String.self, forKey: .done)
            error = try c.decodeIfPresent(String.self, forKey: .error)
            requested = try c.decodeIfPresent(Double.self, forKey: .requested)
            scopes = try c.decodeIfPresent([Scope].self, forKey: .scopes) ?? []
            request = try c.decodeIfPresent(String.self, forKey: .request)
        }

        /// The latest snapshot time the request covers.
        var cutoff: Date? { requested.map { Date(timeIntervalSince1970: $0) } ?? ISOTime.date(at) }
    }
}

// Missing keys take their defaults, so a field added later never makes older settings or state unreadable.
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
        lastSecondDrill = try c.decodeIfPresent(String.self, forKey: .lastSecondDrill)
        offloads = try c.decodeIfPresent([String: Backup.InProgress].self, forKey: .offloads) ?? [:]
        offloaded = try c.decodeIfPresent([Backup.Offloaded].self, forKey: .offloaded) ?? []
        restored = try c.decodeIfPresent([String: Restored].self, forKey: .restored) ?? [:]
        restoring = try c.decodeIfPresent([String: String].self, forKey: .restoring) ?? [:]
        restoredContents = try c.decodeIfPresent([String: RestoredContents].self, forKey: .restoredContents) ?? [:]
        rewrites = try c.decodeIfPresent([Rewrite].self, forKey: .rewrites) ?? []
        forgetting = try c.decodeIfPresent([Backup.Forgetting].self, forKey: .forgetting) ?? []
        forgotten = try c.decodeIfPresent([Forgotten].self, forKey: .forgotten) ?? []
        reassigning = try c.decodeIfPresent([String: Reassignment].self, forKey: .reassigning) ?? [:]
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

    mutating func rememberRepositories(_ repositories: [String?], for id: String) {
        var record = binders[id] ?? BinderRecord()
        for repository in repositories.compactMap({ $0 }) where !record.repositories.contains(repository) {
            record.repositories.append(repository)
        }
        binders[id] = record
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
        confirmedItems = try c.decodeIfPresent([String].self, forKey: .confirmedItems)
        manifestSHA = try c.decodeIfPresent(String.self, forKey: .manifestSHA)
        pinsBeforeWrite = try c.decodeIfPresent([String].self, forKey: .pinsBeforeWrite)
        secondPinsBefore = try c.decodeIfPresent([String].self, forKey: .secondPinsBefore)
        root = try c.decodeIfPresent(Backup.RootMetadata.self, forKey: .root)
        stateSaved = try c.decodeIfPresent(Bool.self, forKey: .stateSaved) ?? false
        oldPinsRemoved = try c.decodeIfPresent(Bool.self, forKey: .oldPinsRemoved) ?? false
        leavingTarget = try c.decodeIfPresent(String.self, forKey: .leavingTarget)
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

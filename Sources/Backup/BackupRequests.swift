import Foundation
import SpravaKit

/// Offload, a restore drill and "back up now" take minutes, so the app queues them and the runtime's backup job runs
/// them one at a time, off the command queue (architecture 2.1: the command queue never waits on slow work). The
/// queue is held in `backup/backup.sqlite` (decisions.md A13): each read-change-write is one StateStore transaction,
/// so writers in different threads and processes cannot lose each other's requests. Links and damaged state are
/// refused and left as they are.
public struct BackupRequests: Sendable {
    public let support: URL
    public init(support: URL) { self.support = support }

    static let schema = StateStore.Schema(version: 1, statements: [])
    static func databaseURL(_ support: URL) -> URL { support.appendingPathComponent("backup/backup.sqlite") }

    /// The kinds a request may be. Restore and peek join with their slices.
    public static let kinds: Set<String> = ["offload", "drill", "backup_now"]
    /// States a request has left for good; it is kept a day so the app can show how it ended.
    static let finished: Set<String> = ["done", "failed", "needs_confirmation"]
    static let pending: Set<String> = ["queued", "running", "waiting_for_icloud"]

    public struct Request: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String              // offload, drill, backup_now
        public var binder: String?           // the binder folder's path
        public var repository: String?       // a drill's repository, primary or second (nil is primary)
        public var confirmOpenItems = false
        public var confirmationDigest: String?
        public var state = "queued"          // queued, running, waiting_for_icloud, done, failed, needs_confirmation
        public var message: String?
        /// The offloaded binder's backup id, once it left.
        public var backupID: String?
        public var at: String

        public init(id: String, kind: String, binder: String? = nil, repository: String? = nil, confirmOpenItems: Bool = false, confirmationDigest: String? = nil,
                    state: String = "queued", message: String? = nil, backupID: String? = nil, at: String) {
            self.id = id
            self.kind = kind
            self.binder = binder
            self.repository = repository
            self.confirmOpenItems = confirmOpenItems
            self.confirmationDigest = confirmationDigest
            self.state = state
            self.message = message
            self.backupID = backupID
            self.at = at
        }
    }

    /// The backup target owns this database. A read or write failure never starts the queue over.
    func access<T>(write: Bool, _ body: (Transaction) throws -> T) throws -> T {
        do {
            let store = try StateStore.open(Self.databaseURL(support), schema: Self.schema)
            return try write ? store.write(body) : store.read(body)
        } catch let failure as Backup.Failure {
            throw failure
        } catch {
            throw Backup.Failure(message: "the backup queue cannot be read or saved; nothing was changed")
        }
    }

    func requests(_ transaction: Transaction) throws -> [Request] {
        try transaction.document([Request].self, key: "requests") ?? []
    }

    /// Missing state is empty; existing state that cannot be opened or decoded throws.
    public func all() throws -> [Request] {
        try access(write: false) { try requests($0) }
    }

    func save(_ list: [Request], in transaction: Transaction, now: Date) throws {
        // Finished requests are kept for a day so the app can show how they ended.
        let cutoff = now.addingTimeInterval(-86_400)
        let kept = list.filter { !Self.finished.contains($0.state) || (ISOTime.date($0.at) ?? now) > cutoff }
        try transaction.setDocument(kept, key: "requests")
    }

    /// Queues a request, or returns the same one already waiting or running.
    @discardableResult
    public func enqueue(_ r: Request, now: Date = Date()) throws -> Request {
        guard Self.kinds.contains(r.kind) else { throw Backup.Failure(message: "unknown backup request") }
        return try access(write: true) { transaction in
            var list = try requests(transaction)
            if let same = list.first(where: { $0.kind == r.kind && $0.binder == r.binder && $0.repository == r.repository
                && Self.pending.contains($0.state) }) { return same }
            list.append(r)
            try save(list, in: transaction, now: now)
            return r
        }
    }

    /// Changes one request. A queue that cannot be read is left as it is; a change that cannot be saved throws, as
    /// does a request no longer in the queue: a transition that did not land must never pass for one that did.
    public func update(_ id: String, now: Date = Date(), _ change: (inout Request) -> Void) throws {
        try access(write: true) { transaction in
            var list = try requests(transaction)
            guard let i = list.firstIndex(where: { $0.id == id }) else { throw Backup.Failure(message: "the request is no longer queued") }
            change(&list[i])
            try save(list, in: transaction, now: now)
        }
    }

    /// At the runtime's start nothing is running, so a request left "running" was cut off by a crash or a restart. It
    /// is marked failed, not run again, so a request that brings the runtime down cannot do so in a loop; an offload
    /// keeps its progress in the backup's state and resumes when the person asks again.
    public func recoverInterrupted(now: Date = Date()) throws {
        try access(write: true) { transaction in
            var list = try requests(transaction)
            var changed = false
            for i in list.indices where list[i].state == "running" {
                list[i].state = "failed"
                list[i].message = "interrupted when Sprava stopped; ask again to continue"
                list[i].at = ISOTime.string(now)
                changed = true
            }
            if changed { try save(list, in: transaction, now: now) }
        }
    }

    /// The next request to run: a queued one first; else a waiting offload is retried, since iCloud may have caught up,
    /// the one retried longest ago first, so several waiting offloads take turns.
    public func next() throws -> Request? {
        let list = try all()
        return list.first { $0.state == "queued" }
            ?? list.filter { $0.state == "waiting_for_icloud" }
            .min { (ISOTime.date($0.at) ?? .distantPast) < (ISOTime.date($1.at) ?? .distantPast) }
    }

    /// Runs one request with `backup`; the runtime calls this off the command queue. It throws, without running the
    /// request, when the queue cannot record it as running; and when the queue cannot record how it ended, so the
    /// request does not sit "running" unnoticed (`recoverInterrupted` marks it failed at the next start).
    /// `nameCollides` is the offload's question (`HubLane.collidingFolders`).
    public func run(_ r: Request, backup: Backup, deviceID: String, nameCollides: (URL) -> Bool, now: Date = Date(),
                    finishedAt: (() -> Date)? = nil) throws {
        try update(r.id, now: now) { $0.state = "running"; $0.at = ISOTime.string(now) }
        var outcome: (inout Request) -> Void
        do {
            guard let path = r.binder else { throw Backup.Failure(message: "the request names no binder") }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            switch r.kind {
            case "offload":
                switch try backup.offload(folder, deviceID: deviceID, confirmOpenItems: r.confirmOpenItems && r.confirmationDigest != nil,
                                          reviewedDigest: r.confirmOpenItems ? r.confirmationDigest : nil,
                                          nameCollides: nameCollides, now: now) {
                case .waitingForICloud(let n):
                    outcome = { $0.state = "waiting_for_icloud"; $0.message = n == 0
                        ? "waiting for iCloud to answer the upload check"
                        : "waiting for iCloud to upload \(n) file(s)" }
                case .done(let record):
                    outcome = { $0.state = "done"; $0.message = "offloaded \(record.name)"; $0.backupID = record.backupID }
                }
            case "drill":
                guard let choice = Backup.DrillRepository(rawValue: r.repository ?? "primary") else {
                    throw Backup.Failure(message: "unknown drill repository")
                }
                try backup.drill(folder, repository: choice, now: now)
                outcome = { $0.state = "done"; $0.message = "the restore drill passed" }
            case "backup_now":
                try backup.backUp(folder, now: now)
                outcome = { $0.state = "done"; $0.message = "backed up" }
            default:
                throw Backup.Failure(message: "unknown backup request")
            }
        } catch let e as Backup.NeedsConfirmation {
            outcome = { $0.state = "needs_confirmation"; $0.message = e.openItems.joined(separator: "\n"); $0.confirmationDigest = e.digest }
        } catch {
            outcome = { $0.state = "failed"; $0.message = "\(error)" }
        }
        // A waiting offload is retried after the others (`next`); a finished request stays visible for a day from when
        // the work ended, not from when it began.
        let ended = finishedAt?() ?? Date()
        try update(r.id, now: ended) {
            outcome(&$0)
            $0.at = ISOTime.string(ended)
        }
    }
}

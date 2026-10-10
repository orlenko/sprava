import Darwin
import Foundation
import SpravaKit

/// Offload, restore, a drill and "back up now" take minutes, so the app queues them and the runtime's backup job
/// runs them one at a time, off the command queue (architecture 2.1: the command queue never waits on slow work).
public struct BackupRequests: Sendable {
    public let support: URL
    let lockTimeout: TimeInterval
    public init(support: URL) { self.support = support; lockTimeout = 3 }
    init(support: URL, lockTimeout: TimeInterval) { self.support = support; self.lockTimeout = lockTimeout }

    public struct Request: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String              // offload, restore, drill, backup_now
        public var binder: String?           // a binder folder path, for offload, drill, backup_now
        public var backupID: String?         // an offloaded binder, for restore
        public var target: String?
        public var repository: String?       // primary or second, for a drill (nil is primary)
        public var confirmOpenItems = false
        public var state = "queued"          // queued, running, waiting_for_icloud, done, failed, needs_confirmation
        public var message: String?
        public var at: String

        package init(id: String, kind: String, binder: String? = nil, backupID: String? = nil, target: String? = nil, repository: String? = nil,
                     confirmOpenItems: Bool = false, state: String = "queued", message: String? = nil, at: String) {
            self.id = id
            self.kind = kind
            self.binder = binder
            self.backupID = backupID
            self.target = target
            self.repository = repository
            self.confirmOpenItems = confirmOpenItems
            self.state = state
            self.message = message
            self.at = at
        }
    }

    package var url: URL { support.appendingPathComponent("backup/requests.json") }
    var lockURL: URL { support.appendingPathComponent("backup/requests.lock") }

    static let lock = NSLock()

    /// Every read-modify-write of requests.json holds this lock: the backup job and the command queue both write
    /// it, from different threads, and a lost update could leave a request "running" for ever. Another process that
    /// writes the file takes the same file lock; one that cannot be taken throws, and nothing is changed.
    func locked<T>(_ body: () throws -> T) throws -> T {
        guard Self.lock.lock(before: Date().addingTimeInterval(lockTimeout)) else {
            throw Backup.Failure(message: "the backup queue's lock cannot be taken within \(lockTimeout) seconds; nothing was changed")
        }
        defer { Self.lock.unlock() }
        try? AtomicFile.makePrivateFolder(lockURL.deletingLastPathComponent())
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Backup.Failure(message: "the backup queue's lock cannot be opened; nothing was changed") }
        defer { close(fd) }
        let deadline = ProcessInfo.processInfo.systemUptime + lockTimeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == EWOULDBLOCK || code == EAGAIN else {
                throw Backup.Failure(message: "the backup queue's lock cannot be taken; nothing was changed")
            }
            guard ProcessInfo.processInfo.systemUptime < deadline else {
                throw Backup.Failure(message: "the backup queue's lock cannot be taken within \(lockTimeout) seconds; nothing was changed")
            }
            usleep(10_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// The queue. Only a missing file is empty; one that cannot be read or decoded throws, so nothing ever saves
    /// over the restores, backups and waiting offloads it holds.
    public func all() throws -> [Request] {
        try StateFile.read([Request].self, from: url) ?? []
    }

    func save(_ list: [Request]) throws {
        try AtomicFile.makePrivateFolder(url.deletingLastPathComponent())
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Finished requests are kept for a day so the app can show how they ended.
        let cutoff = Date().addingTimeInterval(-86_400)
        let kept = list.filter { r in !["done", "failed"].contains(r.state) || (ISOTime.date(r.at) ?? Date()) > cutoff }
        try AtomicFile.write(try e.encode(kept), to: url)
    }

    @discardableResult
    public func enqueue(_ r: Request) throws -> Request {
        try locked {
            var list = try all()
            if let same = list.first(where: { $0.kind == r.kind && $0.binder == r.binder && $0.backupID == r.backupID && $0.repository == r.repository
                && ["queued", "running", "waiting_for_icloud"].contains($0.state) }) { return same }
            list.append(r)
            try save(list)
            return r
        }
    }

    /// Changes one request. A queue that cannot be read is left as it is, and a change that cannot be saved throws,
    /// as does a request no longer in the queue: a transition that did not land must never pass for one that did.
    public func update(_ id: String, _ change: (inout Request) -> Void) throws {
        try locked {
            var list = try all()
            guard let i = list.firstIndex(where: { $0.id == id }) else { throw Backup.Failure(message: "the request is no longer queued") }
            change(&list[i])
            try save(list)
        }
    }

    /// At runtime start nothing is running, so a request left "running" was cut off by a crash or a restart. It is
    /// marked failed, not run again, so a request that brings the runtime down cannot do so in a loop; an offload
    /// keeps its progress in the backup's state and resumes when the person asks again.
    public func recoverInterrupted(now: Date = Date()) throws {
        try locked {
            var list = try all()
            var changed = false
            for i in list.indices where list[i].state == "running" {
                list[i].state = "failed"
                list[i].message = "interrupted when Sprava stopped; ask again to continue"
                list[i].at = ISOTime.string(now)
                changed = true
            }
            if changed { try save(list) }
        }
    }

    /// The next request to run: a queued one first; else a waiting offload is retried, since iCloud may have caught
    /// up, the one retried longest ago first, so several waiting offloads take turns.
    public func next() throws -> Request? {
        let list = try all()
        return list.first { $0.state == "queued" }
            ?? list.filter { $0.state == "waiting_for_icloud" }.min { (ISOTime.date($0.at) ?? .distantPast) < (ISOTime.date($1.at) ?? .distantPast) }
    }

    /// Runs one request with the given backup; the runtime calls this off the command queue. It throws, without
    /// running the request, when the queue cannot record it as running; and when the queue cannot record how it
    /// ended, so the request does not sit "running" unnoticed (`recoverInterrupted` marks it failed at the next start).
    public func run(_ r: Request, backup: Backup, deviceID: String, now: Date = Date(), finishedAt: Date? = nil) throws {
        try update(r.id) { $0.state = "running"; $0.at = ISOTime.string(now) }
        let outcome: (inout Request) -> Void
        do {
            switch r.kind {
            case "offload":
                guard let path = r.binder else { throw Backup.Failure(message: "no binder") }
                switch try backup.offload(URL(fileURLWithPath: path, isDirectory: true), deviceID: deviceID, confirmOpenItems: r.confirmOpenItems, now: now) {
                case .waitingForICloud(let n):
                    outcome = { $0.state = "waiting_for_icloud"; $0.message = "waiting for iCloud to upload \(n) file(s)"; $0.at = ISOTime.string(now) }
                case .done(let record):
                    outcome = { $0.state = "done"; $0.message = "offloaded \(record.name)"; $0.backupID = record.backupID }
                }
            case "restore":
                guard let id = r.backupID else { throw Backup.Failure(message: "no binder") }
                let url = try backup.restore(id, to: r.target.map { URL(fileURLWithPath: $0, isDirectory: true) }, now: now)
                outcome = { $0.state = "done"; $0.message = "restored"; $0.binder = url.path }
            case "drill":
                guard let path = r.binder else { throw Backup.Failure(message: "no binder") }
                let repository: Backup.DrillRepository
                if let requested = r.repository {
                    guard let choice = Backup.DrillRepository(rawValue: requested) else {
                        throw Backup.Failure(message: "unknown drill repository")
                    }
                    repository = choice
                } else { repository = .primary }
                try backup.drill(URL(fileURLWithPath: path, isDirectory: true), repository: repository, now: now)
                outcome = { $0.state = "done"; $0.message = "the restore drill passed" }
            case "backup_now":
                guard let path = r.binder else { throw Backup.Failure(message: "no binder") }
                try backup.backUp(URL(fileURLWithPath: path, isDirectory: true), now: now)
                outcome = { $0.state = "done"; $0.message = "backed up" }
            default:
                throw Backup.Failure(message: "unknown request")
            }
        } catch let e as Backup.NeedsConfirmation {
            outcome = { $0.state = "needs_confirmation"; $0.message = e.openItems.prefix(20).joined(separator: "\n") }
        } catch {
            outcome = { $0.state = "failed"; $0.message = "\(error)" }
        }
        // The day for which a terminal result remains visible begins when the work ends, not when it began.
        let ended = ISOTime.string(finishedAt ?? Date())
        try update(r.id) {
            outcome(&$0)
            if ["done", "failed", "needs_confirmation"].contains($0.state) { $0.at = ended }
        }
    }
}

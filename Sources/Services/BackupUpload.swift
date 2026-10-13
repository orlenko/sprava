import Backup
import Foundation
import SpravaKit

/// Whether iCloud has uploaded the backup mirror (docs/backup.md §3.4), as it was last read, in
/// `runtime/services.sqlite` (decisions.md A13). Reading it walks the whole repository and asks macOS about each file, which stalls
/// when iCloud does, so only the backup job starts it, on a thread of its own (`BackupUploadCheck`). `backup_status`
/// runs on the command queue, which approvals, MCP calls and captures share, and answers with this record and its
/// time, never with a walk.
public struct BackupUpload: Codable, Sendable, Equatable {
    /// The mirror it describes: a result for another folder (setup chose a new one) is not shown.
    public var repository: String
    /// "uploaded", "waiting" or "not_in_icloud".
    public var state: String
    public var waiting: Int?
    public var at: String

    /// How long a result stands before the backup job, which every tick starts, has the mirror read again when it
    /// has written nothing to it.
    public static let recheck: TimeInterval = 600

    static func store(_ support: URL) throws -> StateStore {
        try StateStore.open(support.appendingPathComponent("runtime/services.sqlite"),
                            schema: .init(version: 1, statements: []))
    }

    func save(support: URL) throws {
        try Self.store(support).write { try $0.setDocument(self, key: "backup-upload") }
    }

    init(repository: String, upload: Backup.Upload, at: Date) {
        self.repository = repository
        self.at = ISOTime.string(at)
        switch upload {
        case .uploaded: state = "uploaded"
        case .waiting(let n): state = "waiting"; waiting = n
        case .notInICloud: state = "not_in_icloud"
        case .notChecked: state = "not_checked"
        }
    }

    /// The stored result for `repository`; nil when there is none for it, or it cannot be read (the next check
    /// replaces it).
    public static func last(support: URL, repository: String) -> BackupUpload? {
        guard let record = try? store(support).read({ try $0.document(BackupUpload.self, key: "backup-upload") }),
              record.repository == repository else { return nil }
        return record
    }

    /// As the backup status shows it.
    public var text: String {
        switch state {
        case "uploaded": "uploaded"
        case "not_checked": "not checked yet"
        case "waiting": "waiting for iCloud: \(waiting ?? 0) file(s)"
        default: "not in iCloud"
        }
    }

    /// Whether the stored result for `primary` stands at `now`: younger than `recheck`, and not dated after `now` (the
    /// clock was set back).
    static func stands(support: URL, primary: String, now: Date) -> Bool {
        guard let last = last(support: support, repository: primary), let at = ISOTime.date(last.at) else { return false }
        return at <= now && now.timeIntervalSince(at) < recheck
    }
}

/// The upload check on a thread of its own, never inside the backup job: the walk stalls when iCloud does, the runtime
/// runs the backup job one at a time with no watchdog budget, and a job held by the walk would hold up every scheduled
/// backup and queued request after it. The job starts a check and returns without waiting; at most one runs at a time
/// for a support folder. One that has run past `deadline`, or reads a mirror setup has since replaced, is abandoned:
/// the next job may start another, and the abandoned one's result, if it ever comes, is dropped. A thread held by
/// a stalled iCloud stays held, at most one per `deadline`.
final class BackupUploadCheck: @unchecked Sendable {
    private let lock = NSLock()
    /// The check in flight, with the job's time when it began.
    private var current: (id: UUID, repository: String, began: Date)?
    /// A job wrote to the mirror while a check was in flight, so its result is already old.
    private var wroteSince = false
    /// Left by each check when it ends, abandoned or not; tests wait on it.
    let ended = DispatchGroup()

    private static let guardLock = NSLock()
    nonisolated(unsafe) private static var checks: [String: BackupUploadCheck] = [:]

    /// The check for one support folder, the same for every caller in this process.
    static func of(_ support: URL) -> BackupUploadCheck {
        guardLock.lock()
        defer { guardLock.unlock() }
        let key = support.standardizedFileURL.path
        if let held = checks[key] { return held }
        let made = BackupUploadCheck()
        checks[key] = made
        return made
    }

    /// How long a check may run before the next job gives up on it. A walk takes seconds to a minute when iCloud
    /// answers; well past that, so a slow one is not run twice at once.
    static let deadline: TimeInterval = 1800

    enum Start: Equatable { case stands, inFlight, started(abandoned: Bool) }

    /// The backup job's step: starts a check of `primary` dated `now` when no result for it is stored, when this run
    /// (or one while the last check ran) wrote to it, or when the stored one no longer `stands`; never while another
    /// check of it is in flight within its deadline.
    func start(_ backup: Backup, primary: String, wrote: Bool, now: Date, log: @escaping @Sendable (String) -> Void) -> Start {
        lock.lock()
        defer { lock.unlock() }
        var abandoned = false
        if let c = current {
            if c.repository == primary, c.began <= now, now.timeIntervalSince(c.began) < Self.deadline {
                if wrote { wroteSince = true }
                return .inFlight
            }
            current = nil
            abandoned = true
        }
        if !wrote, !wroteSince, BackupUpload.stands(support: backup.support, primary: primary, now: now) { return .stands }
        let id = UUID()
        current = (id, primary, now)
        wroteSince = false
        ended.enter()
        Thread.detachNewThread { [self] in
            let upload = backup.uploadCheck(URL(fileURLWithPath: primary, isDirectory: true))
            finish(id, BackupUpload(repository: primary, upload: upload, at: now), backup: backup, log: log)
            ended.leave()
        }
        return .started(abandoned: abandoned)
    }

    /// Stores a check's result, unless it was abandoned (a newer check started, or none is wanted) or setup has
    /// chosen another mirror since it began.
    private func finish(_ id: UUID, _ record: BackupUpload, backup: Backup, log: @Sendable (String) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard current?.id == id else { return log("backup upload_dropped reason=abandoned") }
        current = nil
        guard (try? backup.settings().primary) == record.repository else { return log("backup upload_dropped reason=mirror_changed") }
        do {
            try record.save(support: backup.support)
            log("backup upload=\(record.state) waiting=\(record.waiting ?? 0)")
        } catch {
            log("backup upload_unsaved")
        }
    }
}

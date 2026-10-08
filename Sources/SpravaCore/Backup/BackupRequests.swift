import Foundation

/// Offload, restore, a drill and "back up now" take minutes, so the app queues them and the runtime's backup job
/// runs them one at a time, off the command queue (architecture 2.1: the command queue never waits on slow work).
public struct BackupRequests: Sendable {
    public let support: URL
    public init(support: URL) { self.support = support }

    public struct Request: Codable, Sendable, Equatable {
        public var id: String
        public var kind: String              // offload, restore, drill, backup_now
        public var binder: String?           // a binder folder path, for offload, drill, backup_now
        public var backupID: String?         // an offloaded binder, for restore
        public var target: String?
        public var confirmOpenItems = false
        public var state = "queued"          // queued, running, waiting_for_icloud, done, failed, needs_confirmation
        public var message: String?
        public var at: String
    }

    var url: URL { support.appendingPathComponent("backup/requests.json") }

    public func all() -> [Request] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([Request].self, from: $0) } ?? []
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
        var list = all()
        if let same = list.first(where: { $0.kind == r.kind && $0.binder == r.binder && $0.backupID == r.backupID
            && ["queued", "running", "waiting_for_icloud"].contains($0.state) }) { return same }
        list.append(r)
        try save(list)
        return r
    }

    public func update(_ id: String, _ change: (inout Request) -> Void) {
        var list = all()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        change(&list[i])
        try? save(list)
    }

    /// The next request to run: a waiting offload is retried too, since iCloud may have caught up.
    public func next() -> Request? {
        all().first { $0.state == "queued" } ?? all().first { $0.state == "waiting_for_icloud" }
    }

    /// Runs one request with the given backup; the runtime calls this off the command queue.
    public func run(_ r: Request, backup: Backup, deviceID: String, now: Date = Date()) {
        update(r.id) { $0.state = "running"; $0.at = ISOTime.string(now) }
        do {
            switch r.kind {
            case "offload":
                guard let path = r.binder else { throw Backup.Failure(message: "no binder") }
                switch try backup.offload(URL(fileURLWithPath: path, isDirectory: true), deviceID: deviceID, confirmOpenItems: r.confirmOpenItems, now: now) {
                case .waitingForICloud(let n):
                    update(r.id) { $0.state = "waiting_for_icloud"; $0.message = "waiting for iCloud to upload \(n) file(s)" }
                    return
                case .done(let record):
                    update(r.id) { $0.state = "done"; $0.message = "offloaded \(record.name)"; $0.backupID = record.backupID }
                }
            case "restore":
                guard let id = r.backupID else { throw Backup.Failure(message: "no binder") }
                let url = try backup.restore(id, to: r.target.map { URL(fileURLWithPath: $0, isDirectory: true) }, now: now)
                update(r.id) { $0.state = "done"; $0.message = "restored"; $0.binder = url.path }
            case "drill":
                guard let path = r.binder else { throw Backup.Failure(message: "no binder") }
                try backup.drill(URL(fileURLWithPath: path, isDirectory: true), now: now)
                update(r.id) { $0.state = "done"; $0.message = "the restore drill passed" }
            case "backup_now":
                guard let path = r.binder else { throw Backup.Failure(message: "no binder") }
                try backup.backUp(URL(fileURLWithPath: path, isDirectory: true), now: now)
                update(r.id) { $0.state = "done"; $0.message = "backed up" }
            default:
                throw Backup.Failure(message: "unknown request")
            }
        } catch let e as Backup.NeedsConfirmation {
            update(r.id) { $0.state = "needs_confirmation"; $0.message = e.openItems.prefix(20).joined(separator: "\n") }
        } catch {
            update(r.id) { $0.state = "failed"; $0.message = "\(error)" }
        }
    }
}

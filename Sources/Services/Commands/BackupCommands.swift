import Backup
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The backup commands (docs/backup.md): status, setup, the second copy, queued requests and peeking into a snapshot.
extension Commands {
    static let backupCommands: [String: Handler] = [
        "backup_status": { c, _, r, now, today in try c.backupStatus(r, now: now, today: today) },
        "backup_new_key": { c, _, r, now, today in try c.backupNewKey(r, now: now, today: today) },
        // The person chose to use an existing key after all: the key created for them is forgotten.
        "backup_forget_new_key": { _, _, _, _, _ in BackupKey.clearPending(); return JSONObject() },
        "backup_setup": { c, _, r, now, today in try c.backupSetup(r, now: now, today: today) },
        "backup_second": { c, _, r, now, today in try c.backupSecond(r, now: now, today: today) },
        "backup_request": { c, _, r, now, today in try c.backupRequest(r, now: now, today: today) },
        "peek": { c, _, r, now, today in try c.peek(r, now: now, today: today) },
    ]

    func backupStatus(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let backup = Backup(support: support)
        // Settings that cannot be read are reported, never shown as "not set up": the setup offered then would
        // save over them.
        let s = try backup.settings()
        let st = backup.status()
        let rows = ShelfStore(supportDirectory: support).rows()
        // Read only, and never through a link: a status never makes a binder's backup id.
        let names = Dictionary(rows.compactMap { row in Backup.existingBackupID(row.folder).map { ($0, row.name) } },
                               uniquingKeysWith: { a, _ in a })
        // Folders on the Shelf that hold the same backup id: one was copied from the other with its `.sprava`, and the
        // copy is not backed up until it has an id of its own (Backup.SharedBackupID).
        let held = Dictionary(grouping: rows.compactMap { row in Backup.existingBackupID(row.folder).map { (id: $0, row: row) } },
                              by: \.id)
        let shared: [JSONValue] = held.keys.sorted().flatMap { id -> [JSONValue] in
            let holders = held[id] ?? []
            guard Set(holders.map { $0.row.folder.standardizedFileURL.path }).count > 1 else { return [] }
            return holders.map { .obj([("backup_id", .string(id)), ("name", .string($0.row.name)),
                                       ("folder", .string($0.row.folder.standardizedFileURL.path))]) }
        }
        var upload: JSONValue = .null
        switch st.upload {
        case .uploaded?: upload = .str("uploaded")
        case .waiting(let n)?: upload = .string("waiting for iCloud: \(n) file(s)")
        case .notInICloud?: upload = .str("not in iCloud")
        case nil: break
        }
        return JSONObject([
            (key: "configured", value: .bool(st.configured)), (key: "second", value: .bool(st.secondConfigured)),
            (key: "primary", value: s.primary.map(JSONValue.string) ?? .null), (key: "second_path", value: s.second.map(JSONValue.string) ?? .null),
            (key: "pending_key", value: .bool(BackupKey.loadPending() != nil)),
            (key: "upload", value: upload), (key: "last_check", value: st.lastCheck.map(JSONValue.string) ?? .null),
            (key: "last_drill", value: st.lastDrill.map(JSONValue.string) ?? .null),
            (key: "last_second_check", value: st.lastSecondCheck.map(JSONValue.string) ?? .null),
            (key: "shared_backup_ids", value: .array(shared)),
            (key: "binders", value: .array(st.binders.map { b in .obj([("name", .string(names[b.id] ?? "a binder not on the Shelf")),
                                                                        ("at", b.at.map(JSONValue.string) ?? .null),
                                                                        ("error", b.error.map(JSONValue.string) ?? .null)]) })),
            (key: "offloaded", value: .array(try backup.offloaded().map { o in .obj([
                ("id", .string(o.backupID)), ("name", .string(o.name)), ("bytes", .int(Int(o.bytes))), ("at", .string(o.at)),
                ("documents", .array(o.documents.map { .obj([("title", .string($0.title)), ("path", .string($0.path))]) }))]) })),
            (key: "requests", value: .array(try BackupRequests(support: support).all().map { r in .obj([
                ("id", .string(r.id)), ("kind", .string(r.kind)), ("state", .string(r.state)),
                ("binder", r.binder.map(JSONValue.string) ?? .null), ("message", r.message.map(JSONValue.string) ?? .null)]) })),
        ])
    }

    func backupNewKey(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // Step 1 of setup: a key the person saves, then types back (docs/backup.md §4).
        let key = BackupKey.generate()
        try BackupKey.storePending(key)
        return JSONObject([(key: "key", value: .string(key))])
    }

    func backupSetup(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // Step 2: the typed key (a new one confirmed, or an existing one brought from another Mac).
        guard case .string(let typed)? = r["key"], case .string(let primaryPath)? = r["primary"], primaryPath.hasPrefix("/") else {
            throw Failure(message: "backup_setup needs key and primary")
        }
        let key: String
        if let pending = BackupKey.loadPending() {
            guard BackupKey.normalize(typed) == BackupKey.normalize(pending) else { throw Failure(message: "that is not the key shown; check it and type it again") }
            key = pending
        } else {
            key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let icloud = r["icloud_keychain"] == .bool(true)
        try Backup(support: support, key: key).setUp(primary: URL(fileURLWithPath: primaryPath, isDirectory: true), iCloudKeychain: icloud)
        try BackupKey.store(key, inICloudKeychain: icloud)
        BackupKey.clearPending()
        return JSONObject()
    }

    func backupSecond(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        guard case .string(let path)? = r["folder"], path.hasPrefix("/") else { throw Failure(message: "backup_second needs folder") }
        try Backup(support: support).setSecond(URL(fileURLWithPath: path, isDirectory: true))
        return JSONObject()
    }

    func backupRequest(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // Offload, restore, drill or back up now: queued for the runtime's backup job.
        guard case .string(let kind)? = r["kind"], ["offload", "restore", "drill", "backup_now"].contains(kind) else {
            throw Failure(message: "backup_request needs kind")
        }
        var binderPath: String?
        if kind != "restore" {
            let f = try folder(r)
            if Owner.device(of: f) != deviceID { throw Failure(message: "this binder is not managed by this Mac") }
            binderPath = f.path
        }
        let req = BackupRequests.Request(id: UUIDv7.make(now: now), kind: kind, binder: binderPath, backupID: r["backup_id"]?.stringValue,
                                         target: r["target"]?.stringValue, confirmOpenItems: r["confirm_open_items"] == .bool(true),
                                         at: ISOTime.string(now))
        let queued = try BackupRequests(support: support).enqueue(req)
        return JSONObject([(key: "request", value: .string(queued.id))])
    }

    func peek(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        guard case .string(let id)? = r["backup_id"], case .string(let path)? = r["path"] else { throw Failure(message: "peek needs backup_id and path") }
        let file = try Backup(support: support).peek(id, path: path)
        return JSONObject([(key: "file", value: .string(file.path))])
    }
}

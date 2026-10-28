import Backup
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// The backup commands (docs/backup.md): status, the key and setup, the second backup, and the requests the
/// runtime's backup job runs one at a time (offload, a restore drill, back up now). Restore, peek and forgetting
/// join with their slices.
extension Commands {
    static let backupCommands: [String: Handler] = [
        "backup_status": { c, _, _, _, _ in try c.backupStatus() },
        "backup_new_key": { _, _, _, _, _ in try Commands.backupNewKey() },
        "backup_setup": { c, _, r, _, _ in try c.backupSetup(r) },
        "backup_second": { c, _, r, _, _ in try c.backupSecond(r) },
        "backup_request": { c, _, r, now, _ in try c.backupRequest(r, now: now) },
    ]

    static func optional(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }

    func backupStatus() throws -> JSONObject {
        let backup = Backup(support: support)
        // Settings that cannot be read are reported, never shown as "not set up": the setup offered then would save
        // over them.
        let s = try backup.settings()
        // Never the upload walk here: this runs on the command queue, and the walk stalls when iCloud does. The backup
        // job reads it and stores it (`BackupUpload`).
        let st = backup.status(checkUpload: false)
        // Read only, and never through a link: a status never makes a binder's backup id.
        let names = Dictionary(ShelfStore(supportDirectory: support).rows().compactMap { row in
            Backup.existingBackupID(row.folder).map { ($0, row.name) }
        }, uniquingKeysWith: { a, _ in a })
        var upload: JSONValue = .null, uploadCheckedAt: JSONValue = .null
        if let primary = s.primary {
            let last = BackupUpload.last(support: support, repository: primary)
            upload = .string(last?.text ?? "not checked yet")
            uploadCheckedAt = Self.optional(last?.at)
        }
        return JSONObject([
            (key: "configured", value: .bool(st.configured)), (key: "second", value: .bool(st.secondConfigured)),
            (key: "primary", value: Self.optional(s.primary)), (key: "second_path", value: Self.optional(s.second)),
            (key: "pending_key", value: .bool(BackupKey.loadPending() != nil)), (key: "upload", value: upload),
            // An unattended read that found no key: after an update of an ad-hoc build, or with the Keychain locked.
            // Set up (a mirror and a pinned restic on record) but with no key, which `configured` also requires.
            (key: "key_unavailable", value: .bool(s.primary != nil && s.resticSHA256 != nil && backup.key == nil)),
            (key: "icloud_keychain", value: .bool(s.iCloudKeychain)),
            (key: "icloud_keychain_unchecked", value: .bool(s.iCloudKeychainUnchecked == true)),
            (key: "upload_checked_at", value: uploadCheckedAt),
            (key: "last_check", value: Self.optional(st.lastCheck)), (key: "last_second_check", value: Self.optional(st.lastSecondCheck)),
            (key: "last_drill", value: Self.optional(st.lastDrill)), (key: "state_error", value: Self.optional(st.stateError)),
            (key: "binders", value: .array(st.binders.map { b in .obj([("name", .string(names[b.id] ?? "a binder not on the Shelf")),
                                                                        ("at", Self.optional(b.at)), ("error", Self.optional(b.error))]) })),
            (key: "offloaded", value: .array(try backup.offloaded().map { o in .obj([
                ("id", .string(o.backupID)), ("name", .string(o.name)), ("bytes", .int(Int(o.bytes))), ("at", .string(o.at)),
                ("documents", .array(o.documents.map { .obj([("title", .string($0.title)), ("path", .string($0.path))]) }))]) })),
            (key: "requests", value: .array(try BackupRequests(support: support).all().map { r in .obj([
                ("id", .string(r.id)), ("kind", .string(r.kind)), ("state", .string(r.state)), ("binder", Self.optional(r.binder)),
                ("message", Self.optional(r.message)), ("confirmation_digest", Self.optional(r.confirmationDigest)), ("at", .string(r.at))]) })),
        ])
    }

    /// Step 1 of setup: a key the person saves, then types back (docs/backup.md §4).
    static func backupNewKey() throws -> JSONObject {
        let key = BackupKey.generate()
        try BackupKey.storePending(key)
        return JSONObject([(key: "key", value: .string(key))])
    }

    /// Step 2: the typed key, a new one confirmed or one brought from another Mac, and the mirror.
    func backupSetup(_ r: JSONObject) throws -> JSONObject {
        guard case .string(let typed)? = r["key"], case .string(let primaryPath)? = r["primary"], primaryPath.hasPrefix("/") else {
            throw Failure(message: "backup_setup needs key and primary")
        }
        try refuseBackupRepositoryOverlap(URL(fileURLWithPath: primaryPath))
        let key: String
        if let pending = BackupKey.loadPending() {
            guard BackupKey.normalize(typed) == BackupKey.normalize(pending) else {
                throw Failure(message: "that is not the key shown; check it and type it again")
            }
            key = pending
        } else {
            key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let icloud = r["icloud_keychain"] == .bool(true)
        // Refused before setup saves the choice: a refused opt-in left on record would make every later try fail too.
        if icloud, !BackupKey.iCloudKeychainAvailable() {
            throw Failure(message: "iCloud Keychain is unavailable in this development build; keep the key yourself. Nothing was changed.")
        }
        let backup = Backup(support: support, key: key)
        // One change of the backup's state at a time with the backup job (`BackupStateLock`). The repository opens with
        // this key before anything is saved, so a wrong key changes nothing; this is also how a key re-entered after an
        // update is checked. iCloud Keychain counts as unchecked until a store reaches it.
        try BackupStateLock.of(support).command {
            try BackupUploadGate.bounded(backup).setUp(primary: URL(fileURLWithPath: primaryPath, isDirectory: true), iCloudKeychain: icloud)
            try backup.recordICloudKeychainChecked(false)
        }
        let stored = try BackupKey.store(key, inICloudKeychain: icloud)
        if stored.cloudChecked { try BackupStateLock.of(support).command { try backup.recordICloudKeychainChecked(true) } }
        try BackupKey.clearPending()
        return JSONObject([(key: "icloud_keychain_unchecked", value: .bool(!stored.cloudChecked))])
    }

    func backupSecond(_ r: JSONObject) throws -> JSONObject {
        guard case .string(let path)? = r["folder"], path.hasPrefix("/") else { throw Failure(message: "backup_second needs folder") }
        try refuseBackupRepositoryOverlap(URL(fileURLWithPath: path))
        try BackupStateLock.of(support).command {
            try BackupUploadGate.bounded(Backup(support: support)).setSecond(URL(fileURLWithPath: path, isDirectory: true))
        }
        return JSONObject()
    }

    private func refuseBackupRepositoryOverlap(_ repository: URL) throws {
        let shelf = ShelfStore(supportDirectory: support)
        let picked = try shelf.readFolders()
        let registry = try shelf.registryForShelf()
        let registered = (registry?.entries ?? []).compactMap { entry in
            entry.workingDir.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        }
        try Backup.refuseRepositoryOverlap(repository, binders: picked + registered)
    }

    /// Queued for the runtime's backup job; the same request already waiting is answered with its id.
    func backupRequest(_ r: JSONObject, now: Date) throws -> JSONObject {
        guard case .string(let kind)? = r["kind"], BackupRequests.kinds.contains(kind) else {
            throw Failure(message: "backup_request needs kind: offload, drill or backup_now")
        }
        let f = try folder(r)
        guard Owner.device(of: f) == deviceID else { throw Failure(message: "this binder is not managed by this Mac") }
        var repository: String?
        if kind == "drill", case .string(let choice)? = r["repository"] {
            guard Backup.DrillRepository(rawValue: choice) != nil else { throw Failure(message: "repository must be primary or second") }
            repository = choice
        }
        let confirmed = r["confirm_open_items"] == .bool(true)
        let digest = r["confirmation_digest"]?.stringValue
        guard !confirmed || digest != nil else { throw Failure(message: "review the open items again before confirming offload") }
        let request = BackupRequests.Request(id: UUIDv7.make(now: now), kind: kind, binder: f.path, repository: repository,
                                             confirmOpenItems: confirmed, confirmationDigest: digest, at: ISOTime.string(now))
        let queued = try BackupRequests(support: support).enqueue(request, now: now)
        return JSONObject([(key: "request", value: .string(queued.id))])
    }
}

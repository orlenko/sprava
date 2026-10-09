import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit

/// Publishing and withdrawing a binder's agenda slice on the spool (binder-v0 §8.1, §8.2), and the hub pass that
/// drains, then publishes.
extension HubLane {
    /// Checks that a spool folder is a real folder of this user, not writable by others, and not a symlink.
    static func checkFolder(_ url: URL, create: Bool) throws {
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard create, errno == ENOENT else { throw TekaStore.Refused(reason: "\(url.lastPathComponent)/ cannot be read") }
            guard mkdir(url.path, 0o700) == 0 else { throw TekaStore.Refused(reason: "cannot create \(url.lastPathComponent)/") }
            return
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw TekaStore.Refused(reason: "\(url.lastPathComponent)/ is not a folder") }
        guard info.st_uid == getuid(), info.st_mode & 0o022 == 0 else {
            throw TekaStore.Refused(reason: "\(url.lastPathComponent)/ belongs to someone else or is writable by others")
        }
    }

    /// Removes a slice from the spool. Only a slice that is already gone is fine; any other failure is reported,
    /// so a slice the person withdrew never stays on the hub unnoticed.
    static func removeSlice(_ target: URL) throws {
        guard unlink(target.path) == 0 || errno == ENOENT else {
            throw TekaStore.Refused(reason: "the slice on the spool could not be removed")
        }
    }

    /// The cursors only when they are this binder's own: `.sprava` a real folder and `cursors.json` a regular file
    /// in it, never reached through a link to another binder's.
    static func ownCursors(_ folder: URL) -> Cursors? {
        var info = stat()
        guard lstat(folder.appendingPathComponent(".sprava").path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              lstat(cursorsURL(folder).path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? readCursors(folder)
    }

    /// The disclosure the person last confirmed, for a binder whose catalog cannot be read. An op log that cannot
    /// be read fails closed (`none`), as in `PrivacyRatchet.view`.
    static func confirmedDisclosure(_ folder: URL) -> String {
        guard let ops = try? TekaStore(folder: folder).readOpLog().ops else { return "none" }
        return PrivacyRatchet.confirmed(opLog: ops)?.disclosure ?? "full"
    }

    /// Withdraws a binder's slice, whatever else is wrong with the binder. The spool file is never named by the
    /// catalog alone: a binder that passes every check publishes under its own name, which is also its folder's;
    /// one that does not (an outside edit may have renamed it to another binder) withdraws only the slice Sprava
    /// recorded writing for it in its own cursors. So does one whose name collides with another binder's
    /// (`recordedOnly`): the shared name may be the other's slice. Returns false when no slice can be identified
    /// that safely.
    static func withdraw(_ teka: Teka, inbox: URL, recordedOnly: Bool = false) throws -> Bool {
        let own = ownCursors(teka.folder)
        let byRecord = recordedOnly || teka.federationBlocked
        let name: String
        if !byRecord {
            name = teka.name
        } else if let own, own.sliceHash != nil {
            // Cursors written before the name was recorded: a slice is published only under the folder's name.
            name = own.sliceName ?? teka.folder.lastPathComponent
        } else {
            return false
        }
        try removeSlice(try spoolFile(inbox, name, ".agenda.json"))
        guard var cursors = byRecord ? own : try readCursors(teka.folder) else { return true }
        if !byRecord { try removeFormerSlice(cursors, teka: teka, inbox: inbox) }
        cursors.sliceHash = nil
        cursors.sliceName = nil
        try saveCursors(cursors, teka.folder)
        return true
    }

    /// The canonical hash of a slice on the spool, `generated` left out; nil when it cannot be read as JSON. Only a
    /// regular file is read, never through a link, so a FIFO there cannot stall the publish.
    static func sliceHash(at url: URL) -> String? {
        guard case .ok(let data) = SafeFile.read(url), let value = try? JSONParser.parse(data).value else { return nil }
        return try? Canonical.hash(stripGenerated(value))
    }

    /// After a rename the slice Sprava recorded writing under the former name goes, before anything is published or
    /// withdrawn under the new one, so its contents never stay on the hub (binder-v0 §8.3). It goes when the name is
    /// one of the binder's former names or the file is still the one Sprava wrote; a file another program wrote
    /// under a name the binder no longer lists may be another binder's now, and stays.
    static func removeFormerSlice(_ cursors: Cursors, teka: Teka, inbox: URL) throws {
        guard let former = cursors.sliceName, former != teka.name, cursors.sliceHash != nil else { return }
        let url = try spoolFile(inbox, former, ".agenda.json")
        let listed = (teka.catalog?["meta"]?["former_names"]?.arrayValue ?? []).contains { $0["name"]?.stringValue == former }
        if listed || sliceHash(at: url) == cursors.sliceHash { try removeSlice(url) }
    }

    /// Publishes one adopted binder (binder-v0 §8.1, §8.2). Never creates the spool root. The level used is the
    /// narrower of the catalog's and the one the person confirmed (the privacy ratchet, architecture 4.5). At
    /// disclosure `none` the slice is removed; levels `title` and `kind` are not published in the MVP, so their
    /// slice is withdrawn too. A withdrawal comes before the checks that only publishing needs (`withdraw`). A
    /// binder whose name collides with another's (`nameCollides`, from `collidingFolders`) never publishes, but its
    /// withdrawal still runs, by the slice its own cursors recorded.
    ///
    /// The binder lock is held from the reading of the catalog, the privacy state and the cursors through the
    /// writing of the slice and the cursors (binder-v0 §4.9), so a publish that read before a narrowing can never
    /// write after the withdrawal that narrowing caused. A binder whose lock cannot be taken at all (a damaged lock
    /// or `.sprava`) still withdraws, without it; it never publishes. A lock another program holds too long may be
    /// a publish that read the wider level: a withdrawal beside it could be undone by that publish's write, so it
    /// waits for the lock, and the publish fails saying so until then.
    public static func publish(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(), force: Bool = false,
                               nameCollides: Bool = false) throws -> PublishResult {
        try publish(folder, root: root, now: now, force: force, nameCollides: nameCollides, lockTimeout: 10)
    }

    /// `publish`, with how long to wait for the binder lock; tests shorten it.
    static func publish(_ folder: URL, root: URL, now: Date, force: Bool, nameCollides: Bool,
                        lockTimeout: TimeInterval) throws -> PublishResult {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { return .noSpool }
        try checkFolder(root, create: false)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try checkFolder(inbox, create: true)

        // The lock file is made only in a binder Sprava adopted.
        guard Teka.read(folder).isAdopted else { return .notPublished("not adopted") }
        var locked = false
        do {
            return try TekaStore(folder: folder).withLock(timeout: lockTimeout) {
                locked = true
                let teka = Teka.read(folder)
                guard teka.isAdopted else { return .notPublished("not adopted") }
                return try withdrawIfNarrowed(teka, inbox: inbox, nameCollides: nameCollides)
                    ?? publishLocked(teka, inbox: inbox, now: now, force: force, nameCollides: nameCollides)
            }
        } catch where !locked {
            let teka = Teka.read(folder)
            if error is TekaStore.Busy {
                guard disclosure(teka) != "full" else { throw error }
                throw TekaStore.Refused(reason: "another program holds the binder lock; the slice is withdrawn once it is free")
            }
            guard let withdrawn = try withdrawIfNarrowed(teka, inbox: inbox, nameCollides: nameCollides) else { throw error }
            return withdrawn
        }
    }

    /// The level a publish uses: the narrower of the catalog's and the confirmed one. A stamped catalog without a
    /// valid `meta.disclosure` has no level that says what may leave it (binder-v0 §4.2), so it counts as `none`
    /// and its slice is withdrawn, as one with an unknown level is; lifeproj's "absent is full" is for unstamped
    /// catalogs only.
    static func disclosure(_ teka: Teka) -> String {
        guard let catalog = teka.catalog else { return confirmedDisclosure(teka.folder) }
        let meta = catalog["meta"]
        if meta?["format"] != nil, !["full", "title", "kind", "none"].contains(meta?["disclosure"]?.stringValue ?? "") { return "none" }
        return PrivacyRatchet.view(folder: teka.folder, catalog: catalog).disclosure
    }

    /// A narrowing takes effect at once: the slice goes before any check that refuses publishing (a broken stamp, a
    /// linked DASHBOARD.md, an unreadable catalog) can keep it on the hub. Nil at disclosure `full`.
    static func withdrawIfNarrowed(_ teka: Teka, inbox: URL, nameCollides: Bool) throws -> PublishResult? {
        let level = disclosure(teka)
        guard level != "full" else { return nil }
        guard try withdraw(teka, inbox: inbox, recordedOnly: nameCollides) else { return .notPublished("the binder needs attention") }
        return level == "none" ? .removed
            : .notPublished("disclosure \(level) is not published in this version; the slice was withdrawn")
    }

    /// The publish proper, at disclosure `full`, under the binder lock.
    static func publishLocked(_ teka: Teka, inbox: URL, now: Date, force: Bool, nameCollides: Bool) throws -> PublishResult {
        let folder = teka.folder
        guard let catalog = teka.catalog else { return .notPublished("not adopted") }
        guard !teka.federationBlocked else { return .notPublished("the binder needs attention") }
        guard !nameCollides else { return .notPublished("another binder has the same name") }
        let target = try spoolFile(inbox, teka.name, ".agenda.json")
        let privacy = PrivacyRatchet.view(folder: folder, catalog: catalog)
        var cursors = try readCursors(folder)

        // Someone else published this binder since our last write, or removed or damaged the slice: say so, then
        // publish over it. After a rename there is nothing under the new name to compare yet.
        var targetCurrent = false
        var overwritten = false
        if let last = cursors.sliceHash, (cursors.sliceName ?? teka.name) == teka.name {
            let hash = sliceHash(at: target)
            targetCurrent = hash == last
            overwritten = hash != last
        }

        // Items closed since the last publish are shown once more with status done, so the hub drops them; the
        // next publish leaves them out. The first publish takes the log as found as its baseline. A
        // `closed-duplicate` entry closes its `item` (binder-v0 §6.8); each id shows once.
        let log = catalog["processing_log"]?.arrayValue ?? []
        if cursors.sliceHash == nil && cursors.lastLogCount == 0 { cursors.lastLogCount = log.count }
        var closedKeys = Set<String>()
        let newClosures: [(id: JSONValue, entry: JSONObject)] = log.dropFirst(min(cursors.lastLogCount, log.count)).compactMap { entry in
            guard case .object(let e) = entry else { return nil }
            let id: JSONValue?
            switch e["action"]?.stringValue {
            case "done"?, "dropped"?: id = e["id"]
            case "closed-duplicate"?: id = e["item"]
            default: id = nil
            }
            guard let id, closedKeys.insert((try? Canonical.serialize(id)) ?? idText(id)).inserted else { return nil }
            return (id, e)
        }
        // Only the id and the redaction are read from a closure: a closed item publishes nothing else (binder-v0
        // §8.2), so a tag or title an outside edit gave it before it closed never reaches the hub.
        let closedOnce: [JSONObject] = newClosures.map { id, e in
            var item = JSONObject()
            item.set("id", id)
            if e["final"]?["redact"] == .bool(true) { item.set("redact", .bool(true)) }
            return item
        }

        // Items published redacted stay redacted unless the person lifted it with an op since then; a redaction an
        // outside edit removed stays until the person approves the privacy card (architecture 4.5). This covers the
        // items closed once as well as the open ones, for their ids. An aborted op lifts nothing,
        // as in `PrivacyRatchet.confirmed` (binder-v0 §6.9).
        let ops = (try? TekaStore(folder: folder).readOpLog().ops) ?? []
        let aborted = Set(ops.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        var lifted = Set<String>()
        for op in ops.dropFirst(min(cursors.opCount ?? 0, ops.count)) where op["op"] == .str("update_item")
            && op["actor"]?["kind"] == .str("user") && !aborted.contains(op["id"]?.stringValue ?? "") {
            let unset = op["args"]?["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if unset.contains("redact") || op["args"]?["set"]?["redact"] == .bool(false), let id = op["args"]?["id"] {
                lifted.insert((try? Canonical.serialize(id)) ?? "")
            }
        }
        let keepRedacted = Set(cursors.redacted ?? []).subtracting(lifted).union(privacy.redacted)
        let key = try sliceKey(folder)
        let (slice, ids) = try project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: closedOnce,
                                       key: key, now: now, alsoRedact: keepRedacted, keepTitles: privacy.titles,
                                       lastSeen: cursors.published)
        let hash = try Canonical.hash(stripGenerated(slice))
        if !force, targetCurrent, hash == cursors.sliceHash { return .unchanged }
        try removeFormerSlice(cursors, teka: teka, inbox: inbox)
        try AtomicFile.write(Data(JSONWriter.pretty(slice).utf8), to: target)
        cursors.sliceHash = hash
        cursors.sliceName = teka.name
        cursors.published.merge(ids) { _, new in new }
        cursors.closedOnce = newClosures.map { (try? Canonical.serialize($0.id)) ?? "" }
        cursors.lastLogCount = log.count
        cursors.opCount = ops.count
        let items = catalog["open_items"]?.arrayValue ?? []
        cursors.redacted = items.compactMap { it -> String? in
            guard let id = it["id"], let k = try? Canonical.serialize(id) else { return nil }
            return it["redact"] == .bool(true) || keepRedacted.contains(k) ? k : nil
        }
        try saveCursors(cursors, folder)
        return .published(items: slice["items"]?.arrayValue?.count ?? 0, overwrittenByOther: overwritten)
    }

    /// One binder's hub pass, as the runtime runs it: drain, then publish.
    public struct SyncResult {
        public var drained: DrainResult?
        public var drainError: Error?
        public var published: PublishResult?
        public var publishError: Error?
        /// The binder's name collides with another's: it neither drained nor published, which is a failure.
        public var nameCollides = false
        public var failed: Bool { drainError != nil || publishError != nil || nameCollides }
    }

    /// Drains, then publishes. Publishing never waits on the drain: an outbox that cannot be drained must not keep
    /// a slice the person narrowed or withdrew on the hub, and the projection reads only the binder, never the
    /// outbox. A drain failure is reported beside whatever the publish did. `afterDrain` sees a drain that worked.
    /// Two binders under one name would share a spool file (binder-v0 §3.1): one that collides (`nameCollides`)
    /// neither drains nor publishes, yet a narrowing still withdraws the slice it recorded writing (`publish`).
    public static func sync(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(), nameCollides: Bool = false,
                            afterDrain: (DrainResult) -> Void = { _ in }) -> SyncResult {
        var out = SyncResult()
        out.nameCollides = nameCollides
        if !nameCollides {
            do {
                let drained = try drain(folder, root: root, now: now)
                out.drained = drained
                afterDrain(drained)
            } catch {
                out.drainError = error
            }
        }
        do { out.published = try publish(folder, root: root, now: now, nameCollides: nameCollides) } catch { out.publishError = error }
        return out
    }
}

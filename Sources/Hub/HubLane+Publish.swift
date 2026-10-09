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
    /// or `.sprava`) still withdraws, without it, when its disclosure narrowed or its slice shows more than it allows
    /// now (an item redacted since, for example); it never publishes. A lock another program holds too long may be
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
            // Narrowed means a lower disclosure, or a slice that shows more than the binder allows now (`showsMore`),
            // such as an item redacted since the last publish.
            let teka = Teka.read(folder)
            if error is TekaStore.Busy {
                guard disclosure(teka) != "full" || (try? showsMore(teka, inbox: inbox)) == true else { throw error }
                throw TekaStore.Refused(reason: "another program holds the binder lock; the slice is withdrawn once it is free")
            }
            if let withdrawn = try withdrawIfNarrowed(teka, inbox: inbox, nameCollides: nameCollides) { return withdrawn }
            guard try withdrawIfShowingMore(teka, inbox: inbox, nameCollides: nameCollides) else { throw error }
            let why = (error as? TekaStore.Refused)?.reason ?? String(describing: error)
            throw TekaStore.Refused(reason: "the binder lock cannot be taken (\(why)); \(withdrawnNote)")
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

    static let withdrawnNote = "the slice was withdrawn, since it showed more than the binder now allows"

    /// The publish proper, at disclosure `full`, under the binder lock. When it fails or is refused, the slice on the
    /// spool is withdrawn if it shows more than the binder now allows (`showsMore`): a narrowing never waits for a
    /// publish that a broken item, a blocked binder or a failed write keeps from happening.
    static func publishLocked(_ teka: Teka, inbox: URL, now: Date, force: Bool, nameCollides: Bool) throws -> PublishResult {
        let result: PublishResult
        do {
            result = try publishChecked(teka, inbox: inbox, now: now, force: force, nameCollides: nameCollides)
        } catch {
            guard (try? withdrawIfShowingMore(teka, inbox: inbox, nameCollides: nameCollides)) == true else { throw error }
            throw TekaStore.Refused(reason: "\((error as? TekaStore.Refused)?.reason ?? String(describing: error)); \(withdrawnNote)")
        }
        if case .notPublished(let why) = result, (try? withdrawIfShowingMore(teka, inbox: inbox, nameCollides: nameCollides)) == true {
            return .notPublished("\(why); \(withdrawnNote)")
        }
        return result
    }

    /// What a publish projects with, worked out from the catalog, the privacy ratchet, the cursors and the op log.
    struct Plan {
        var closures: [(id: JSONValue, entry: JSONObject)]
        /// The items closed since the last publish, as `project` takes them: the id, and `redact` from the closure.
        var closedOnce: [JSONObject]
        var keepRedacted: Set<String>
        var allowTags: [String: Set<String>]
        /// The `slice_title` the person confirmed for each item that has one: all a redacted item may show as its title.
        var confirmedTitles: [String: JSONValue]
        var logCount: Int
        var opCount: Int
    }

    static func plan(_ catalog: JSONObject, folder: URL, cursors: Cursors, privacy: PrivacyRatchet.View) -> Plan {
        // Items closed since the last publish are shown once more with status done, so the hub drops them; the
        // next publish leaves them out. The first publish takes the log as found as its baseline. A
        // `closed-duplicate` entry closes its `item` (binder-v0 §6.8); each id shows once.
        let log = catalog["processing_log"]?.arrayValue ?? []
        let baseline = cursors.sliceHash == nil && cursors.lastLogCount == 0 ? log.count : cursors.lastLogCount
        var closedKeys = Set<String>()
        let closures: [(id: JSONValue, entry: JSONObject)] = log.dropFirst(min(baseline, log.count)).compactMap { entry in
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
        let closedOnce: [JSONObject] = closures.map { id, e in
            var item = JSONObject()
            item.set("id", id)
            if e["final"]?["redact"] == .bool(true) { item.set("redact", .bool(true)) }
            return item
        }

        // Items published redacted stay redacted unless the person lifted it with an op since then; a redaction an
        // outside edit removed stays until the person approves the privacy card (architecture 4.5). This covers the
        // items closed once as well as the open ones, for their ids. A redacted item shows only the tags the person
        // confirmed: for an item the privacy ratchet knows (from adoption, an op of Sprava's or an outside edit it
        // recorded), the tags it confirmed, so nothing about publication history, the first one included, loosens
        // them; for one it does not know yet (an outside addition no write of Sprava's has recorded), the tags the hub
        // already saw for it and the ones the person set since, or its tags as found when the hub never saw it, its
        // first sight. An aborted op lifts and sets nothing, as in `PrivacyRatchet.confirmed` (binder-v0 §6.9).
        let ops = (try? TekaStore(folder: folder).readOpLog().ops) ?? []
        let aborted = Set(ops.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        var lifted = Set<String>()
        var userTags: [String: Set<String>] = [:]
        for op in ops.dropFirst(min(cursors.opCount ?? 0, ops.count)) where op["op"] == .str("update_item")
            && op["actor"]?["kind"] == .str("user") && !aborted.contains(op["id"]?.stringValue ?? "") {
            guard let id = op["args"]?["id"], let k = try? Canonical.serialize(id) else { continue }
            let unset = op["args"]?["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if unset.contains("redact") || op["args"]?["set"]?["redact"] == .bool(false) { lifted.insert(k) }
            if let tags = op["args"]?["set"]?["tags"]?.arrayValue {
                userTags[k, default: []].formUnion(tags.compactMap { try? Canonical.serialize($0) })
            }
        }
        let confirmed = PrivacyRatchet.confirmed(opLog: ops)
        let known = confirmed?.known ?? []
        var allowTags: [String: Set<String>] = [:]
        for (k, seen) in cursors.tags ?? [:] where !known.contains(k) { allowTags[k] = Set(seen).union(userTags[k] ?? []) }
        for k in known { allowTags[k] = Set((confirmed?.tags[k] ?? []).compactMap { try? Canonical.serialize($0) }) }
        return Plan(closures: closures, closedOnce: closedOnce,
                    keepRedacted: Set(cursors.redacted ?? []).subtracting(lifted).union(privacy.redacted),
                    allowTags: allowTags, confirmedTitles: confirmed?.sliceTitles ?? [:], logCount: log.count,
                    opCount: ops.count)
    }

    static func publishChecked(_ teka: Teka, inbox: URL, now: Date, force: Bool, nameCollides: Bool) throws -> PublishResult {
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

        let plan = plan(catalog, folder: folder, cursors: cursors, privacy: privacy)
        let key = try sliceKey(folder)
        let projection = try projection(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: plan.closedOnce,
                                        key: key, now: now, alsoRedact: plan.keepRedacted, keepTitles: privacy.titles,
                                        confirmedTitles: plan.confirmedTitles, lastSeen: cursors.published,
                                        allowTags: plan.allowTags, strict: true)
        let slice = projection.slice
        let hash = try Canonical.hash(stripGenerated(slice))
        let unchanged = !force && targetCurrent && hash == cursors.sliceHash
        if !unchanged {
            try removeFormerSlice(cursors, teka: teka, inbox: inbox)
            try AtomicFile.write(Data(JSONWriter.pretty(slice).utf8), to: target)
        }
        // The cursors are kept even when the slice is unchanged: the redactions it kept and the ops it read are what
        // the next publish starts from, so a lift it consumed is never applied again to a redaction made since.
        let before = cursors
        cursors.sliceHash = hash
        cursors.sliceName = teka.name
        cursors.published.merge(projection.ids) { _, new in new }
        cursors.closedOnce = plan.closures.map { (try? Canonical.serialize($0.id)) ?? "" }
        cursors.lastLogCount = plan.logCount
        cursors.opCount = plan.opCount
        cursors.tags = projection.tags
        let items = catalog["open_items"]?.arrayValue ?? []
        cursors.redacted = items.compactMap { it -> String? in
            guard let id = it["id"], let k = try? Canonical.serialize(id) else { return nil }
            return it["redact"] == .bool(true) || plan.keepRedacted.contains(k) ? k : nil
        }
        if cursors != before { try saveCursors(cursors, folder) }
        return unchanged ? .unchanged : .published(items: slice["items"]?.arrayValue?.count ?? 0, overwrittenByOther: overwritten)
    }

    /// Withdraws the slice when it shows more than the binder now allows; true when it did.
    static func withdrawIfShowingMore(_ teka: Teka, inbox: URL, nameCollides: Bool) throws -> Bool {
        guard try showsMore(teka, inbox: inbox) else { return false }
        return try withdraw(teka, inbox: inbox, recordedOnly: nameCollides)
    }

    /// Whether the slice Sprava last wrote shows more than the binder allows now, judged against a projection made
    /// without the checks that only publishing needs: an open item that is gone or shown as `done`, a title, party or
    /// link that differs, or a tag no longer shown. An item left in `open_items` with status `done` is judged the
    /// same way (it may stay done); only the rows shown once for closed items, which carry nothing but their id, are
    /// passed over. Nothing recorded, or nothing readable on the spool, shows
    /// nothing. A catalog that cannot be read, or whose `open_items` or `processing_log` is not a list, has no items
    /// to judge against: the last slice stays, as for any refused publish (a narrowed disclosure is withdrawn before
    /// this, by `withdrawIfNarrowed`).
    static func showsMore(_ teka: Teka, inbox: URL) throws -> Bool {
        let cursors = try readCursors(teka.folder)
        guard cursors.sliceHash != nil else { return false }
        let url = try spoolFile(inbox, cursors.sliceName ?? teka.folder.lastPathComponent, ".agenda.json")
        guard case .ok(let data) = SafeFile.read(url), let shown = try? JSONParser.parse(data).value else { return false }
        guard let catalog = teka.catalog else { return false }
        guard let key = try existingSliceKey(teka.folder) else { return true }
        let privacy = PrivacyRatchet.view(folder: teka.folder, catalog: catalog)
        let plan = plan(catalog, folder: teka.folder, cursors: cursors, privacy: privacy)
        guard let allowed = try? projection(catalog: catalog, folderName: teka.folder.lastPathComponent, closedOnce: plan.closedOnce,
                                            key: key, now: Date(), alsoRedact: plan.keepRedacted, keepTitles: privacy.titles,
                                            confirmedTitles: plan.confirmedTitles, lastSeen: cursors.published,
                                            allowTags: plan.allowTags, strict: false) else { return false }
        var open: [String: JSONValue] = [:]
        var any: [String: JSONValue] = [:]
        for it in allowed.slice["items"]?.arrayValue ?? [] {
            guard let id = it["id"]?.stringValue else { continue }
            if any[id] == nil { any[id] = it }
            if it["status"] != .str("done"), open[id] == nil { open[id] = it }
        }
        // A row shown once for an item closed (`project`'s `closedOnce`) carries only the id the hub already saw. Any
        // other row with status `done` is an item an outside edit left in `open_items` as done, published with its
        // title, party, link and tags like an open one, and judged like one.
        let closedIDs = Set(cursors.closedOnce.compactMap { cursors.published[$0] })
        func closure(_ row: JSONValue) -> Bool {
            guard let id = row["id"]?.stringValue, closedIDs.contains(id) else { return false }
            return row["status"] == .str("done") && row["title"] == .str("[closed]") && row["tags"] == .array([])
                && row["waiting_on"] == .null && row["link"] == .null
        }
        for old in shown["items"]?.arrayValue ?? [] where !closure(old) {
            let done = old["status"] == .str("done")
            guard let id = old["id"]?.stringValue, let now = done ? any[id] : open[id] else { return true }
            if ["title", "waiting_on", "link"].contains(where: { old[$0] != now[$0] }) { return true }
            let tags = Set(now["tags"]?.arrayValue ?? [])
            if !(old["tags"]?.arrayValue ?? []).allSatisfy(tags.contains) { return true }
        }
        return false
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

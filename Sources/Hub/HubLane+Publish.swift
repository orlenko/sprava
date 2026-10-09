import BinderFormat
import BinderStore
import Darwin
import Foundation
import SpravaKit

/// Publishing a binder's agenda slice on the spool (binder-v0 §8.1, §8.2), withdrawing it when the binder narrowed
/// (the withdrawal itself is in `HubLane+Withdraw.swift`), and the hub pass that drains, then publishes.
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
        if lstat(root.path, &rootInfo) != 0, errno == ENOENT { return .noSpool }
        try checkFolder(root, create: false)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try checkFolder(inbox, create: true)

        // The lock file is made only in a binder Sprava adopted. One that no longer reads as adopted (its op log
        // missing or cut short) has no privacy state to publish by, so a slice its own cursors recorded is withdrawn,
        // by that record, while it is still the one Sprava wrote.
        let found = Teka.read(folder)
        guard found.isAdopted else {
            guard let own = ownCursors(folder), !recordedSlices(own, folder: folder).isEmpty,
                  try withdraw(found, inbox: inbox, recordedOnly: true) else {
                return .notPublished("not adopted")
            }
            return .notPublished("not adopted; the slice Sprava wrote was withdrawn")
        }
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
        let baseline = recordedSlices(cursors, folder: folder).isEmpty && cursors.lastLogCount == 0 ? log.count : cursors.lastLogCount
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

    /// `beforeSliceWrite` and `afterSliceWrite` are for tests: they run where a publish may be cut off.
    static func publishChecked(_ teka: Teka, inbox: URL, now: Date, force: Bool, nameCollides: Bool,
                               beforeSliceWrite: () throws -> Void = {}, afterSliceWrite: () throws -> Void = {}) throws -> PublishResult {
        let folder = teka.folder
        guard let catalog = teka.catalog else { return .notPublished("not adopted") }
        guard !teka.federationBlocked else { return .notPublished("the binder needs attention") }
        guard !nameCollides else { return .notPublished("another binder has the same name") }
        let target = try spoolFile(inbox, teka.name, ".agenda.json")
        let privacy = PrivacyRatchet.view(folder: folder, catalog: catalog)
        // A publish cut off after it recorded its pending slice is settled before that record is read or replaced.
        let onDisk = try readCursors(folder)
        var cursors = reconciled(onDisk, folder: folder, inbox: inbox)

        // Someone else published this binder since our last write, or removed or damaged the slice: say so, then
        // publish over it. After a rename there is nothing under the new name to compare yet. A slice rewritten with
        // the same items differs only in its `generated` stamp.
        let found = sliceOnSpool(at: target)
        let mine = recordedSlices(cursors, folder: folder).filter { $0.name == teka.name }
        let targetCurrent = mine.contains { found?.hash == $0.hash && ($0.generated == nil || found?.generated == $0.generated) }
        let overwritten = !mine.isEmpty && !targetCurrent

        let plan = plan(catalog, folder: folder, cursors: cursors, privacy: privacy)
        let key = try sliceKey(folder)
        let projection = try projection(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: plan.closedOnce,
                                        key: key, now: now, alsoRedact: plan.keepRedacted, keepTitles: privacy.titles,
                                        confirmedTitles: plan.confirmedTitles, lastSeen: cursors.published,
                                        allowTags: plan.allowTags, strict: true)
        let slice = projection.slice
        let hash = try Canonical.hash(stripGenerated(slice))
        let unchanged = !force && targetCurrent && found?.hash == hash
        // The cursors are kept even when the slice is unchanged: the redactions it kept and the ops it read are what
        // the next publish starts from, so a lift it consumed is never applied again to a redaction made since.
        cursors.opCount = plan.opCount
        cursors.tags = projection.tags
        let items = catalog["open_items"]?.arrayValue ?? []
        cursors.redacted = items.compactMap { it -> String? in
            guard let id = it["id"], let k = try? Canonical.serialize(id) else { return nil }
            return it["redact"] == .bool(true) || plan.keepRedacted.contains(k) ? k : nil
        }
        let published = cursors.published.merging(projection.ids) { _, new in new }
        let closedOnce = plan.closures.map { (try? Canonical.serialize($0.id)) ?? "" }
        if !unchanged {
            // What the slice hides, and which slice it is, are durable before the slice is: a publish cut off after its
            // write must not leave cursors that would let the next one lift a redaction this slice showed
            // (architecture 4.5), nor a slice a withdrawal cannot recognise as Sprava's.
            try removeFormerSlice(cursors, teka: teka, inbox: inbox, now: now)
            // `reconciled` cleared any earlier pending record, so none is overwritten unsettled here.
            cursors.pending = .init(name: teka.name, hash: hash, generated: slice["generated"]?.stringValue,
                                    lastLogCount: plan.logCount, closedOnce: closedOnce, published: published)
            try saveCursors(cursors, folder)
            try beforeSliceWrite()
            try AtomicFile.write(Data(JSONWriter.pretty(slice).utf8), to: target)
            try afterSliceWrite()
        }
        let privacySaved = unchanged ? onDisk : cursors
        cursors.sliceHash = hash
        cursors.sliceName = teka.name
        cursors.pending = nil
        // Cursors written before the stamp was recorded take it from the slice they match, so a rewrite that changes
        // only the stamp is noticed from now on.
        if !unchanged { cursors.generated = slice["generated"]?.stringValue } else if cursors.generated == nil { cursors.generated = found?.generated }
        cursors.published = published
        cursors.closedOnce = closedOnce
        cursors.lastLogCount = plan.logCount
        if cursors != privacySaved { try saveCursors(cursors, folder) }
        return unchanged ? .unchanged : .published(items: slice["items"]?.arrayValue?.count ?? 0, overwrittenByOther: overwritten)
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

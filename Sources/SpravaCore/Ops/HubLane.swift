import CryptoKit
import Darwin
import Foundation

/// The federation profile, narrowed for the MVP (binder-v0 §8; mvp.md feature 7): Sprava publishes an adopted
/// binder's agenda slice with lifeproj's exact projection, and drains the hub's completions with lifeproj's
/// semantics plus the safer acknowledgement of §8.3.
public enum HubLane {
    // MARK: - The spool (binder-v0 §8.1)

    /// `$OSAVUL_SPOOL`, else `$XDG_DATA_HOME/osavul`, else `~/.local/share/osavul`, as lifeproj resolves it.
    public static func spoolRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let s = environment["OSAVUL_SPOOL"], !s.isEmpty { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if let x = environment["XDG_DATA_HOME"], !x.isEmpty {
            return URL(fileURLWithPath: (x as NSString).expandingTildeInPath).appendingPathComponent("osavul")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/osavul")
    }

    /// A binder name usable as one file name in the spool: no separators, not a dot name, no control characters.
    public static func isSafeSegment(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 200 && !name.hasPrefix(".") && !name.contains("/") && !name.contains(":")
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }

    /// The spool file for a binder, refusing any name that would land outside `dir`.
    static func spoolFile(_ dir: URL, _ name: String, _ suffix: String) throws -> URL {
        guard isSafeSegment(name) else { throw TekaStore.Refused(reason: "the binder name cannot be used as a spool file name") }
        let url = dir.appendingPathComponent(name + suffix)
        guard url.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path else {
            throw TekaStore.Refused(reason: "the binder name cannot be used as a spool file name")
        }
        return url
    }

    /// A binder name as the spool compares it: NFC, then case folded (APFS is case-insensitive by default).
    static func foldedName(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The folders whose binder names collide with another known binder's, after case folding and NFC, unexpired
    /// former names included (binder-v0 §3.1). None of them publishes or drains: they would share one spool file.
    /// A former name without a readable `until` counts as unexpired.
    public static func collidingFolders(_ rows: [ShelfRow], today: CalendarDate) -> Set<String> {
        var byName: [String: Set<String>] = [:]
        for row in rows where row.teka.catalog != nil {
            var names = [row.teka.name]
            for former in row.teka.catalog?["meta"]?["former_names"]?.arrayValue ?? [] {
                guard let name = former["name"]?.stringValue else { continue }
                if let until = former["until"]?.stringValue.flatMap({ CalendarDate.strict(String($0.prefix(10))) }), until < today { continue }
                names.append(name)
            }
            for name in Set(names.map(foldedName)) { byName[name, default: []].insert(row.folder.standardizedFileURL.path) }
        }
        return Set(byName.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    public enum PublishResult: Equatable {
        case noSpool
        case unchanged
        case published(items: Int, overwrittenByOther: Bool)
        case removed
        case notPublished(String)
    }

    struct Cursors: Codable {
        var sliceHash: String?
        /// Canonical id text -> the slice id the hub last saw.
        var published: [String: String] = [:]
        /// Items closed since the last publish, shown once with status `done` so the hub drops them
        /// (mvp.md feature 7; architecture 13, item 35).
        var closedOnce: [String] = []
        var lastLogCount = 0
        /// Items published redacted, by canonical id text, and the op log length at that publish: a redaction is
        /// lifted on the hub only by the person's own op, never by an outside edit (architecture 4.5, 7.3).
        var redacted: [String]? = []
        var opCount: Int? = 0
    }

    static func cursorsURL(_ folder: URL) -> URL { folder.appendingPathComponent(".sprava/cursors.json") }

    /// The cursors, for read-only callers such as the doctor: empty when they cannot be read.
    static func loadCursors(_ folder: URL) -> Cursors { (try? readCursors(folder)) ?? Cursors() }

    /// The cursors for publish and drain. Only a missing file is a fresh start; one that cannot be read or decoded
    /// stops the lane for this binder, because its `redacted` list keeps redactions an outside edit removed.
    static func readCursors(_ folder: URL) throws -> Cursors {
        let url = cursorsURL(folder)
        var info = stat()
        if lstat(url.path, &info) != 0 {
            guard errno == ENOENT else { throw TekaStore.Refused(reason: ".sprava/cursors.json cannot be read") }
            return Cursors()
        }
        guard let data = try? Data(contentsOf: url), let c = try? JSONDecoder().decode(Cursors.self, from: data) else {
            throw TekaStore.Refused(reason: ".sprava/cursors.json cannot be read; it was left as it is")
        }
        return c
    }

    static func saveCursors(_ c: Cursors, _ folder: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(c), to: cursorsURL(folder))
    }

    static func sliceKey(_ folder: URL) throws -> SymmetricKey {
        let url = folder.appendingPathComponent(".sprava/slice-key")
        // A key is made only when there is none: rotating it would change every alias the hub knows (binder-v0 §5.6).
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard let data = try? Data(contentsOf: url), data.count == 32 else {
                throw TekaStore.Refused(reason: ".sprava/slice-key cannot be read or is damaged; it was left as it is")
            }
            return SymmetricKey(data: data)
        }
        guard errno == ENOENT else { throw TekaStore.Refused(reason: ".sprava/slice-key cannot be read") }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        try AtomicFile.write(Data(bytes), to: url)
        return SymmetricKey(data: bytes)
    }

    /// `<binder>-r-` plus 12 hex digits of HMAC-SHA-256 over the id's canonical JSON text (binder-v0 §5.6).
    static func alias(_ id: JSONValue, teka: String, key: SymmetricKey) -> String {
        let text = (try? Canonical.serialize(id)) ?? canonicalText(id)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
        return "\(teka)-r-" + mac.map { String(format: "%02x", $0) }.joined().prefix(12)
    }

    /// lifeproj's `str()` of an id: strings as is, integers in decimal.
    static func idText(_ id: JSONValue) -> String {
        if case .string(let s) = id { return s }
        if case .number(let n) = id { return n.text }
        return canonicalText(id)
    }

    static func isRecommended(_ id: JSONValue, teka: String) -> Bool {
        guard case .string(let s) = id else { return false }
        return s.wholeMatch(of: try! Regex("^\(NSRegularExpression.escapedPattern(for: teka))-\\d{4}-\\d{3,}$")) != nil
    }

    /// The slice id of an item that is not redacted.
    public static func plainSliceID(_ id: JSONValue, teka: String) -> String {
        let text = idText(id)
        return text.hasPrefix("\(teka)-") ? text : "\(teka)-\(text)"
    }

    /// The slice id: prefixed with `<binder>-` unless it already starts with it (lifeproj's plain string test), or an
    /// alias for a redacted item whose id is not in the recommended form (binder-v0 §5.5 at level `full`).
    static func sliceID(_ id: JSONValue, redacted: Bool, teka: String, key: SymmetricKey) -> String {
        if redacted && !isRecommended(id, teka: teka) { return alias(id, teka: teka, key: key) }
        let text = idText(id)
        return text.hasPrefix("\(teka)-") ? text : "\(teka)-\(text)"
    }

    /// The agenda slice at disclosure level `full`: lifeproj's nine keys per item, in order, nothing else
    /// (binder-v0 §8.2; the v1 additions stay off in the MVP). `keepTitles` holds the confirmed hub titles an outside
    /// edit removed or changed, by the id's canonical text; they stand in for the found ones.
    public static func project(catalog: JSONObject, folderName: String, closedOnce: [JSONObject],
                               key: SymmetricKey, now: Date, alsoRedact: Set<String> = [],
                               keepTitles: [String: JSONValue] = [:]) throws -> (slice: JSONValue, ids: [String: String]) {
        let meta = catalog["meta"]?.objectValue ?? JSONObject()
        let teka = meta["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? folderName
        var chapters: [JSONValue]
        switch meta["active_chapters"] ?? meta["current_chapters"] {
        case .string(let s)?: chapters = [.string(s)]
        case .array(let a)?: chapters = a.filter { ItemRules.isTruthy($0) }
        default: chapters = []
        }
        var activeChapter = meta["active_chapter"] ?? .null
        if activeChapter == .null, chapters.count == 1 { activeChapter = chapters[0] }

        let items = (catalog["open_items"]?.arrayValue ?? []).compactMap(\.objectValue)
        // lifeproj validates strictly before publishing, whatever the schema_version.
        let findings = ItemRules.check(items: items.map(JSONValue.object), log: catalog["processing_log"]?.arrayValue ?? [], v0: false)
        if !findings.isEmpty { throw TekaStore.Refused(reason: "open_items fail lifeproj's rules; nothing published") }

        var ids: [String: String] = [:]
        var projected: [JSONValue] = []
        var seen = Set<String>()
        func project(_ it: JSONObject, status: JSONValue? = nil) throws {
            let id = it["id"] ?? .null
            let redacted = it["redact"] == .bool(true) || alsoRedact.contains((try? Canonical.serialize(id)) ?? "")
            let sid = sliceID(id, redacted: redacted, teka: teka, key: key)
            guard seen.insert(sid).inserted else { throw TekaStore.Refused(reason: "two items project to the same slice id") }
            ids[(try? Canonical.serialize(id)) ?? idText(id)] = sid
            let title: JSONValue = keepTitles[(try? Canonical.serialize(id)) ?? ""]
                ?? it["slice_title"].flatMap { ItemRules.isTruthy($0) ? $0 : nil }
                ?? (redacted ? .str("[redacted]") : it["title"] ?? .null)
            projected.append(.obj([
                ("id", .string(sid)), ("title", title), ("status", status ?? it["status"] ?? .null),
                ("priority", it["priority"] ?? .null), ("due", it["due"] ?? .null),
                ("no_deadline", .bool(it["no_deadline"] == .bool(true))), ("tags", it["tags"] ?? .array([])),
                ("waiting_on", redacted ? .str("[party]") : it["waiting_on"] ?? .null),
                ("link", redacted ? .null : it["link"] ?? .null),
            ]))
        }
        for it in items where it["dismissed"] != .bool(true) { try project(it) }
        for it in closedOnce { try project(it, status: .str("done")) }
        let generated = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        let slice = JSONValue.obj([
            ("teka", .string(teka)), ("lifecycle", meta["lifecycle"] ?? .null), ("active_chapter", activeChapter),
            ("active_chapters", .array(chapters)), ("generated", .string(generated)), ("items", .array(projected)),
        ])
        return (slice, ids)
    }

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

    /// Publishes one adopted binder (binder-v0 §8.1, §8.2). Never creates the spool root. The level used is the
    /// narrower of the catalog's and the one the person confirmed (the privacy ratchet, architecture 4.5). At
    /// disclosure `none` the slice is removed; levels `title` and `kind` are not published in the MVP, so their
    /// slice is withdrawn too.
    public static func publish(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(), force: Bool = false) throws -> PublishResult {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { return .noSpool }
        try checkFolder(root, create: false)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try checkFolder(inbox, create: true)

        let teka = Teka.read(folder)
        guard teka.isAdopted, let catalog = teka.catalog else { return .notPublished("not adopted") }
        guard !teka.federationBlocked else { return .notPublished("the binder needs attention") }
        let target = try spoolFile(inbox, teka.name, ".agenda.json")

        let privacy = PrivacyRatchet.view(folder: folder, catalog: catalog)
        let disclosure = privacy.disclosure
        if disclosure != "full" {
            // A narrowing takes effect at once: the slice goes before anything else can fail.
            try removeSlice(target)
            var cursors = try readCursors(folder)
            cursors.sliceHash = nil
            try saveCursors(cursors, folder)
            return disclosure == "none" ? .removed
                : .notPublished("disclosure \(disclosure) is not published in this version; the slice was withdrawn")
        }
        var cursors = try readCursors(folder)

        // Someone else published this binder since our last write, or removed or damaged the slice: say so, then
        // publish over it.
        var targetCurrent = false
        var overwritten = false
        if let last = cursors.sliceHash {
            if let data = try? Data(contentsOf: target), let value = try? JSONParser.parse(data).value,
               let hash = try? Canonical.hash(stripGenerated(value)) {
                targetCurrent = hash == last
                overwritten = hash != last
            } else {
                overwritten = true
            }
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
        let closedOnce: [JSONObject] = newClosures.map { id, e in
            var item = e["final"]?.objectValue ?? JSONObject()
            item.set("id", id)
            item.set("title", e["title"] ?? .str(""))
            if item["priority"] == nil { item.set("priority", .str("normal")) }
            if item["due"] == nil, item["no_deadline"] == nil { item.set("no_deadline", .bool(true)) }
            return item
        }

        // Items published redacted stay redacted unless the person lifted it with an op since then; a redaction an
        // outside edit removed stays until the person approves the privacy card (architecture 4.5). Both this and
        // the confirmed hub titles cover the items closed once as well as the open ones.
        let ops = (try? TekaStore(folder: folder).readOpLog().ops) ?? []
        var lifted = Set<String>()
        for op in ops.dropFirst(min(cursors.opCount ?? 0, ops.count)) where op["op"] == .str("update_item")
            && ["user"].contains(op["actor"]?["kind"]?.stringValue ?? "") {
            let unset = op["args"]?["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if unset.contains("redact") || op["args"]?["set"]?["redact"] == .bool(false), let id = op["args"]?["id"] {
                lifted.insert((try? Canonical.serialize(id)) ?? "")
            }
        }
        let keepRedacted = Set(cursors.redacted ?? []).subtracting(lifted).union(privacy.redacted)
        let key = try sliceKey(folder)
        let (slice, ids) = try project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: closedOnce,
                                       key: key, now: now, alsoRedact: keepRedacted, keepTitles: privacy.titles)
        let hash = try Canonical.hash(stripGenerated(slice))
        if !force, targetCurrent, hash == cursors.sliceHash { return .unchanged }
        try AtomicFile.write(Data(JSONWriter.pretty(slice).utf8), to: target)
        cursors.sliceHash = hash
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
        public var failed: Bool { drainError != nil || publishError != nil }
    }

    /// Drains, then publishes. Publishing never waits on the drain: an outbox that cannot be drained must not keep
    /// a slice the person narrowed or withdrew on the hub, and the projection reads only the binder, never the
    /// outbox. A drain failure is reported beside whatever the publish did. `afterDrain` sees a drain that worked.
    public static func sync(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(),
                            afterDrain: (DrainResult) -> Void = { _ in }) -> SyncResult {
        var out = SyncResult()
        do {
            let drained = try drain(folder, root: root, now: now)
            out.drained = drained
            afterDrain(drained)
        } catch {
            out.drainError = error
        }
        do { out.published = try publish(folder, root: root, now: now) } catch { out.publishError = error }
        return out
    }

    static func stripGenerated(_ slice: JSONValue) -> JSONValue {
        guard case .object(var o) = slice else { return slice }
        o.remove("generated")
        return .object(o)
    }

    // MARK: - Drain (binder-v0 §8.3)

    public struct DrainResult: Equatable {
        public var applied = 0
        public var acknowledged = 0
        public var skipped = 0
        public var waitingForYou = 0
        /// Cards Sprava wrote while absorbing an outside edit, for the caller to trust.
        public var createdProposals: [String] = []
    }

    public static func drain(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(), client: String = "sprava/0.1") throws -> DrainResult {
        var result = DrainResult()
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { return result }
        let teka = Teka.read(folder)
        guard teka.isAdopted, let catalog = teka.catalog, !teka.federationBlocked else { return result }
        let outboxDir = root.appendingPathComponent("outbox", isDirectory: true)
        var info = stat()
        guard lstat(outboxDir.path, &info) == 0 else { return result }
        try checkFolder(outboxDir, create: false)
        let file = try spoolFile(outboxDir, teka.name, ".intake.json")
        // No outbox is nothing to do; an outbox that cannot be read is a failure, so the breaker sees it.
        var fileInfo = stat()
        if lstat(file.path, &fileInfo) != 0 {
            guard errno == ENOENT else { throw TekaStore.Refused(reason: "the outbox cannot be read") }
            return result
        }
        guard let data = try? Data(contentsOf: file) else { throw TekaStore.Refused(reason: "the outbox cannot be read") }
        guard case .object(let outbox) = try JSONParser.parse(data).value else { throw TekaStore.Refused(reason: "outbox is not a JSON object") }
        let completions = (outbox["completions"]?.arrayValue ?? []).compactMap(\.objectValue)
        guard !completions.isEmpty else { return result }

        let teka_ = teka.name
        let key = try sliceKey(folder)
        let cursors = try readCursors(folder)
        let items = (catalog["open_items"]?.arrayValue ?? []).compactMap(\.objectValue)
        let log = catalog["processing_log"]?.arrayValue ?? []

        /// Resolves a completion id: raw id, `<binder>-<raw>`, an alias, then the id last published.
        func resolve(_ cid: String) -> JSONObject? {
            for it in items {
                guard let id = it["id"] else { continue }
                let text = idText(id)
                if text == cid || "\(teka_)-\(text)" == cid || alias(id, teka: teka_, key: key) == cid { return it }
                if cursors.published[(try? Canonical.serialize(id)) ?? ""] == cid { return it }
            }
            return nil
        }

        let actor = JSONObject([(key: "kind", value: .str("external")), (key: "client", value: .string(client)),
                                (key: "origin", value: .str("spool-outbox"))])
        var bodies: [TekaStore.OpBody] = []
        var toAck: [(String, JSONValue?)] = []
        var trial = catalog
        for c in completions {
            guard case .string(let cid)? = c["id"], let action = c["action"]?.stringValue, ["done", "dropped"].contains(action) else {
                result.skipped += 1
                continue
            }
            guard let item = resolve(cid) else {
                // Already closed, for example by an earlier drain whose acknowledgement was lost: an id is never
                // reused, so a completion for a closed id is acknowledged, as lifeproj does by id.
                if log.contains(where: { e in
                    guard let id = e["id"], ["done", "dropped"].contains(e["action"]?.stringValue ?? "") else { return false }
                    let text = idText(id)
                    return text == cid || "\(teka_)-\(text)" == cid || alias(id, teka: teka_, key: key) == cid
                        || cursors.published[(try? Canonical.serialize(id)) ?? ""] == cid
                }) {
                    toAck.append((cid, c["at"]))
                } else {
                    result.skipped += 1
                }
                continue
            }
            if item["recurrence"] != nil {
                // The MVP leaves recurring items to the hub; the completion waits (mvp.md feature 2).
                result.waitingForYou += 1
                continue
            }
            var args = JSONObject()
            args.set("id", item["id"]!)
            let atValue: JSONValue = c["at"].flatMap { $0.stringValue != nil ? $0 : nil } ?? .null
            args.set("closed_at", atValue)
            args.set("source", c["source"].flatMap { $0.stringValue != nil ? $0 : nil } ?? .str("osavul"))
            let op = action == "done" ? "complete" : "drop"
            // Each completion is checked on its own; one bad completion never blocks the others.
            var line = JSONObject()
            line.set("id", .string(UUIDv7.make(now: now)))
            line.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
            line.set("actor", .object(actor))
            line.set("op", .string(op))
            line.set("args", .object(args))
            if let next = try? TransactionGuard.check([line], on: trial) {
                trial = next.catalog
                bodies.append(.init(op: op, args: args, actor: actor))
                toAck.append((cid, c["at"]))
            } else {
                result.skipped += 1
            }
        }
        // The binder lock is held from the write through the acknowledgement (binder-v0 §4.9).
        let store = TekaStore(folder: folder, client: client)
        if !bodies.isEmpty {
            var acknowledged = 0
            try store.apply(bodies, batch: UUIDv7.make(now: now), now: now) {
                acknowledged = try acknowledge(file: file, applied: toAck)
            }
            result.applied = bodies.count
            result.acknowledged = acknowledged
            result.createdProposals = store.createdProposals
        } else if !toAck.isEmpty {
            result.acknowledged = try store.withLock { try acknowledge(file: file, applied: toAck) }
        }
        return result
    }

    /// Steps 1 to 4 of binder-v0 §8.3: re-read, remove only what was applied (by id and at), and rename only when the
    /// file did not change in between; delete the file only when nothing else is in it.
    static func acknowledge(file: URL, applied: [(String, JSONValue?)]) throws -> Int {
        for _ in 0..<5 {
            guard let data = try? Data(contentsOf: file), case .object(var fresh) = try JSONParser.parse(data).value else { return 0 }
            let before = SHA256.hash(data: data)
            let completions = fresh["completions"]?.arrayValue ?? []
            var removed = 0
            let kept = completions.filter { c in
                let match = applied.contains { $0.0 == c["id"]?.stringValue && $0.1 == c["at"] }
                if match { removed += 1 }
                return !match
            }
            fresh.set("completions", .array(kept))
            let onlyKnown = Set(fresh.keys).isSubset(of: ["teka", "generated", "completions", "items", "format_version"])
            let empty = kept.isEmpty && (fresh["items"]?.arrayValue ?? []).isEmpty && onlyKnown
            let again = try? Data(contentsOf: file)
            guard let again, SHA256.hash(data: again) == before else { continue }
            if empty {
                try FileManager.default.removeItem(at: file)
            } else {
                try AtomicFile.write(Data(JSONWriter.pretty(.object(fresh)).utf8), to: file)
            }
            return removed
        }
        throw TekaStore.Refused(reason: "the outbox kept changing; acknowledgement retried later")
    }
}

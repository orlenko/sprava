import CryptoKit
import Darwin
import Foundation

/// The federation profile, narrowed for the MVP (teka-v0 §8; mvp.md feature 7): Sprava publishes an adopted
/// binder's agenda slice with lifeproj's exact projection, and drains the hub's completions with lifeproj's
/// semantics plus the safer acknowledgement of §8.3.
public enum HubLane {
    // MARK: - The spool (teka-v0 §8.1)

    /// `$OSAVUL_SPOOL`, else `$XDG_DATA_HOME/osavul`, else `~/.local/share/osavul`, as lifeproj resolves it.
    public static func spoolRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let s = environment["OSAVUL_SPOOL"], !s.isEmpty { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if let x = environment["XDG_DATA_HOME"], !x.isEmpty {
            return URL(fileURLWithPath: (x as NSString).expandingTildeInPath).appendingPathComponent("osavul")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/osavul")
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
    }

    static func cursorsURL(_ folder: URL) -> URL { folder.appendingPathComponent(".sprava/cursors.json") }

    static func loadCursors(_ folder: URL) -> Cursors {
        (try? Data(contentsOf: cursorsURL(folder))).flatMap { try? JSONDecoder().decode(Cursors.self, from: $0) } ?? Cursors()
    }

    static func saveCursors(_ c: Cursors, _ folder: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(c), to: cursorsURL(folder))
    }

    static func sliceKey(_ folder: URL) throws -> SymmetricKey {
        let url = folder.appendingPathComponent(".sprava/slice-key")
        if let data = try? Data(contentsOf: url), data.count == 32 { return SymmetricKey(data: data) }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        try AtomicFile.write(Data(bytes), to: url)
        return SymmetricKey(data: bytes)
    }

    /// `<teka>-r-` plus 12 hex digits of HMAC-SHA-256 over the id's canonical JSON text (teka-v0 §5.6).
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

    /// The slice id: prefixed with `<teka>-` unless it already starts with it (lifeproj's plain string test), or an
    /// alias for a redacted item whose id is not in the recommended form (teka-v0 §5.5 at level `full`).
    static func sliceID(_ id: JSONValue, redacted: Bool, teka: String, key: SymmetricKey) -> String {
        if redacted && !isRecommended(id, teka: teka) { return alias(id, teka: teka, key: key) }
        let text = idText(id)
        return text.hasPrefix("\(teka)-") ? text : "\(teka)-\(text)"
    }

    /// The agenda slice at disclosure level `full`: lifeproj's nine keys per item, in order, nothing else
    /// (teka-v0 §8.2; the v1 additions stay off in the MVP).
    public static func project(catalog: JSONObject, folderName: String, closedOnce: [JSONObject],
                               key: SymmetricKey, now: Date) throws -> (slice: JSONValue, ids: [String: String]) {
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
            let redacted = it["redact"] == .bool(true)
            let sid = sliceID(id, redacted: redacted, teka: teka, key: key)
            guard seen.insert(sid).inserted else { throw TekaStore.Refused(reason: "two items project to the same slice id") }
            ids[(try? Canonical.serialize(id)) ?? idText(id)] = sid
            let title: JSONValue = it["slice_title"].flatMap { ItemRules.isTruthy($0) ? $0 : nil }
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

    /// Publishes one adopted binder (teka-v0 §8.1, §8.2). Never creates the spool root; at disclosure `none` the
    /// slice is removed. Levels `title` and `kind` are not published in the MVP.
    public static func publish(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(), force: Bool = false) throws -> PublishResult {
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { return .noSpool }
        try checkFolder(root, create: false)
        let inbox = root.appendingPathComponent("inbox", isDirectory: true)
        try checkFolder(inbox, create: true)

        let teka = Teka.read(folder)
        guard teka.isAdopted, let catalog = teka.catalog else { return .notPublished("not adopted") }
        var cursors = loadCursors(folder)
        let target = inbox.appendingPathComponent("\(teka.name).agenda.json")

        // Someone else published this binder since our last write: say so, then publish over it.
        var overwritten = false
        if let data = try? Data(contentsOf: target), let last = cursors.sliceHash,
           let value = try? JSONParser.parse(data).value, let hash = try? Canonical.hash(stripGenerated(value)), hash != last {
            overwritten = true
        }

        let disclosure = catalog["meta"]?["disclosure"]?.stringValue ?? "full"   // a lifeproj catalog publishes at full
        if disclosure == "none" {
            try? FileManager.default.removeItem(at: target)
            cursors.sliceHash = nil
            try saveCursors(cursors, folder)
            return .removed
        }
        guard disclosure == "full" else { return .notPublished("disclosure \(disclosure) is not published in this version") }

        // Items closed since the last publish are shown once more with status done, so the hub drops them; the
        // next publish leaves them out. The first publish takes the log as found as its baseline.
        let log = catalog["processing_log"]?.arrayValue ?? []
        if cursors.sliceHash == nil && cursors.lastLogCount == 0 { cursors.lastLogCount = log.count }
        let newClosures = log.dropFirst(min(cursors.lastLogCount, log.count))
            .filter { $0["id"] != nil && ["done", "dropped"].contains($0["action"]?.stringValue ?? "") }
        let closedOnce: [JSONObject] = newClosures.compactMap { entry in
            guard let id = entry["id"], case .object(let e) = entry else { return nil }
            var item = e["final"]?.objectValue ?? JSONObject()
            item.set("id", id)
            item.set("title", e["title"] ?? .str(""))
            if item["priority"] == nil { item.set("priority", .str("normal")) }
            if item["due"] == nil, item["no_deadline"] == nil { item.set("no_deadline", .bool(true)) }
            return item
        }

        let key = try sliceKey(folder)
        let (slice, ids) = try project(catalog: catalog, folderName: folder.lastPathComponent, closedOnce: closedOnce,
                                       key: key, now: now)
        let hash = try Canonical.hash(stripGenerated(slice))
        if !force, !overwritten, hash == cursors.sliceHash { return .unchanged }
        try AtomicFile.write(Data(JSONWriter.pretty(slice).utf8), to: target)
        cursors.sliceHash = hash
        cursors.published.merge(ids) { _, new in new }
        cursors.closedOnce = newClosures.compactMap { $0["id"].map { (try? Canonical.serialize($0)) ?? "" } }
        cursors.lastLogCount = log.count
        try saveCursors(cursors, folder)
        return .published(items: slice["items"]?.arrayValue?.count ?? 0, overwrittenByOther: overwritten)
    }

    static func stripGenerated(_ slice: JSONValue) -> JSONValue {
        guard case .object(var o) = slice else { return slice }
        o.remove("generated")
        return .object(o)
    }

    // MARK: - Drain (teka-v0 §8.3)

    public struct DrainResult: Equatable {
        public var applied = 0
        public var acknowledged = 0
        public var skipped = 0
        public var waitingForYou = 0
    }

    public static func drain(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(), client: String = "sprava/0.1") throws -> DrainResult {
        var result = DrainResult()
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { return result }
        let teka = Teka.read(folder)
        guard teka.isAdopted, let catalog = teka.catalog else { return result }
        let outboxDir = root.appendingPathComponent("outbox", isDirectory: true)
        var info = stat()
        guard lstat(outboxDir.path, &info) == 0 else { return result }
        try checkFolder(outboxDir, create: false)
        let file = outboxDir.appendingPathComponent("\(teka.name).intake.json")
        guard let data = try? Data(contentsOf: file) else { return result }
        guard case .object(let outbox) = try JSONParser.parse(data).value else { throw TekaStore.Refused(reason: "outbox is not a JSON object") }
        let completions = (outbox["completions"]?.arrayValue ?? []).compactMap(\.objectValue)
        guard !completions.isEmpty else { return result }

        let teka_ = teka.name
        let key = try sliceKey(folder)
        let cursors = loadCursors(folder)
        let items = (catalog["open_items"]?.arrayValue ?? []).compactMap(\.objectValue)
        let log = catalog["processing_log"]?.arrayValue ?? []

        /// Resolves a completion id: raw id, `<teka>-<raw>`, an alias, then the id last published.
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
                // Already closed by an earlier drain that could not acknowledge (same id, closed_at == at).
                let at = c["at"]
                if log.contains(where: { e in e["closed_at"] == at && (e["id"].map { idText($0) == cid || "\(teka_)-\(idText($0))" == cid } ?? false) }) {
                    toAck.append((cid, at))
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
        if !bodies.isEmpty {
            try TekaStore(folder: folder, client: client).apply(bodies, batch: UUIDv7.make(now: now), now: now)
            result.applied = bodies.count
        }
        guard !toAck.isEmpty else { return result }
        result.acknowledged = try acknowledge(file: file, applied: toAck)
        return result
    }

    /// Steps 1 to 4 of teka-v0 §8.3: re-read, remove only what was applied (by id and at), and rename only when the
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

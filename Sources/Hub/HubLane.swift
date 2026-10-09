import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
import Shelf
import SpravaKit

/// The federation profile, narrowed for the MVP (binder-v0 §8; mvp.md feature 7): Sprava publishes an adopted
/// binder's agenda slice with lifeproj's exact projection, and drains the hub's completions with lifeproj's
/// semantics plus the safer acknowledgement of §8.3.
extension HubLane {
    // MARK: - The spool (binder-v0 §8.1)

    /// `$OSAVUL_SPOOL`, else `$XDG_DATA_HOME/osavul`, else `~/.local/share/osavul`, as lifeproj resolves it.
    public static func spoolRoot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let s = environment["OSAVUL_SPOOL"], !s.isEmpty { return URL(fileURLWithPath: (s as NSString).expandingTildeInPath) }
        if let x = environment["XDG_DATA_HOME"], !x.isEmpty {
            return URL(fileURLWithPath: (x as NSString).expandingTildeInPath).appendingPathComponent("osavul")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/osavul")
    }

    /// The spool file for a binder, refusing any name that would land outside `dir`.
    package static func spoolFile(_ dir: URL, _ name: String, _ suffix: String) throws -> URL {
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

    package struct Cursors: Codable {
        package var sliceHash: String?
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
        /// The binder name the slice was last written under, so a withdrawal finds it without trusting the catalog.
        package var sliceName: String?
    }

    static func cursorsURL(_ folder: URL) -> URL { folder.appendingPathComponent(".sprava/cursors.json") }

    /// The cursors, for read-only callers such as the doctor: empty when they cannot be read.
    package static func loadCursors(_ folder: URL) -> Cursors { (try? readCursors(folder)) ?? Cursors() }

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

    static func sliceKeyURL(_ folder: URL) -> URL { folder.appendingPathComponent(".sprava/slice-key") }

    /// The slice key, nil when there is none yet. The drain reads it this way: only a publish, under the binder
    /// lock, makes one, so two programs never make different keys and replace each other's.
    static func existingSliceKey(_ folder: URL) throws -> SymmetricKey? {
        let url = sliceKeyURL(folder)
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            guard errno == ENOENT else { throw TekaStore.Refused(reason: ".sprava/slice-key cannot be read") }
            return nil
        }
        guard let data = try? Data(contentsOf: url), data.count == 32 else {
            throw TekaStore.Refused(reason: ".sprava/slice-key cannot be read or is damaged; it was left as it is")
        }
        return SymmetricKey(data: data)
    }

    /// The slice key, made when there is none; called only under the binder lock.
    static func sliceKey(_ folder: URL) throws -> SymmetricKey {
        let url = sliceKeyURL(folder)
        // A key is made only when there is none: rotating it would change every alias the hub knows (binder-v0 §5.6).
        if let key = try existingSliceKey(folder) { return key }
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

    static func isRecommended(_ id: JSONValue, teka: String) -> Bool {
        guard case .string(let s) = id else { return false }
        return s.wholeMatch(of: try! Regex("^\(NSRegularExpression.escapedPattern(for: teka))-\\d{4}-\\d{3,}$")) != nil
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

        // lifeproj validates strictly before publishing, whatever the schema_version. The collections are checked as
        // found: one an outside edit made something other than a list, or an entry that is not an object, refuses the
        // publish instead of passing as an empty or shorter slice.
        func list(_ key: String) throws -> [JSONValue] {
            switch catalog[key] {
            case nil: return []
            case .array(let a)?: return a
            default: throw TekaStore.Refused(reason: "\(key) is not a list; nothing published")
            }
        }
        let rawItems = try list("open_items")
        let findings = ItemRules.check(items: rawItems, log: try list("processing_log"), v0: false)
        if !findings.isEmpty { throw TekaStore.Refused(reason: "open_items fail lifeproj's rules; nothing published") }
        let items = rawItems.compactMap(\.objectValue)

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

    package static func stripGenerated(_ slice: JSONValue) -> JSONValue {
        guard case .object(var o) = slice else { return slice }
        o.remove("generated")
        return .object(o)
    }
}

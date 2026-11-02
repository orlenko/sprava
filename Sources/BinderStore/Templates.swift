import Foundation
import SpravaKit

/// Creates a binder from a template: a ready binder-v0 folder at disclosure `none`, adopted at once, whose checklist
/// arrives as one card (mvp.md feature 6; binder-v0 §3.1, §6.9).
public enum BinderCreator {
    public struct Created: Sendable {
        public let folder: URL
        /// nil for a template with no checklist.
        public let checklistCard: String?
    }

    /// What the person typed, as a binder name of the shape binder-v0 §3.1 asks of a binder Sprava creates: diacritics
    /// stripped, lowercase, each run of other characters one hyphen, at most 64 characters with no hyphen at either end.
    /// A name with nothing left, as one only in another script, takes `fallback` in the same shape, then `new-binder`.
    public static func slug(_ typed: String, fallback: String) -> String {
        for text in [typed, fallback] {
            var out = String(IDMint.cleaned(text).prefix(64))
            while out.hasSuffix("-") { out.removeLast() }
            if !out.isEmpty { return out }
        }
        return "new-binder"
    }

    /// The name a new binder takes from what the person typed. One with nothing left falls back to the empty folder's
    /// own name when there is one, then to the template's suggestion, so typing never ends in a refusal.
    public static func name(for typed: String, template: BinderTemplate, year: Int, existing: URL? = nil) -> String {
        let suggested = template.suggestedName(year)
        return slug(typed, fallback: existing.map { slug($0.lastPathComponent, fallback: suggested) } ?? suggested)
    }

    /// `name`, or the first of `name-2`, `name-3`, … that no other binder has and no other entry in `parent` holds. The
    /// empty folder that becomes the binder does not stand in the way of its own name, in any case.
    public static func freeName(_ name: String, parent: URL, knownNames: [String], existing: URL? = nil) -> String {
        let known = Set(knownNames.map { $0.precomposedStringWithCanonicalMapping.lowercased() })
        func taken(_ candidate: String) -> Bool {
            if known.contains(candidate.lowercased()) { return true }
            var at = stat()
            guard lstat(parent.appendingPathComponent(candidate).path, &at) == 0 else { return false }
            var own = stat()
            guard let existing, lstat(existing.path, &own) == 0 else { return true }
            return own.st_dev != at.st_dev || own.st_ino != at.st_ino
        }
        guard taken(name) else { return name }
        for n in 2...999 {
            let suffix = "-\(n)"
            var base = String(name.prefix(64 - suffix.count))
            while base.hasSuffix("-") { base.removeLast() }
            if !taken(base + suffix) { return base + suffix }
        }
        // Left to `create`, which says the name is taken.
        return name
    }

    /// An empty folder can become a binder: nothing in it but Finder's `.DS_Store`. Reads entries one at a time and
    /// stops at the first other one, so a large folder is not listed whole only to learn it is not empty.
    public static func isEmptyFolder(_ url: URL) -> Bool {
        guard let dir = opendir(url.path) else { return false }
        defer { closedir(dir) }
        errno = 0
        while let entry = readdir(dir) {
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
            if name == "." || name == ".." { errno = 0; continue }
            // Finder's metadata is a plain file. A folder or link under that name holds what backup skips (it leaves out
            // every `.DS_Store` path), so it does not count as empty.
            var st = stat()
            guard name == ".DS_Store", lstat(url.appendingPathComponent(name).path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
                return false
            }
            errno = 0
        }
        return errno == 0
    }

    /// `existing` is an empty folder in `parent` that becomes the binder, renamed to `name` when its name differs, since
    /// `meta.name` equals the folder's name (binder-v0 §3.1). Without it, the binder's folder is made new. `synced` is
    /// replaceable for tests only.
    public static func create(parent: URL, name: String, template: BinderTemplate, deviceID: String, knownNames: [String],
                              year: Int, today: CalendarDate, client: String = "sprava/0.1", now: Date = Date(),
                              existing: URL? = nil, synced: (URL) -> Bool = Adoption.syncedLocation) throws -> Created {
        guard name.wholeMatch(of: /[a-z0-9][a-z0-9-]*/) != nil, name.count <= 64 else {
            throw TekaStore.Refused(reason: "a binder name uses lowercase letters, digits and hyphens, starting with a letter or a digit")
        }
        let folded = name.lowercased()
        guard !knownNames.contains(where: { $0.precomposedStringWithCanonicalMapping.lowercased() == folded }) else {
            throw TekaStore.Refused(reason: "another binder already has that name")
        }
        guard SafeFile.isTrustedFolder(parent) else { throw TekaStore.Refused(reason: "that folder cannot hold a binder") }
        if synced(parent) { throw TekaStore.Refused(reason: "that folder is uploaded by a sync service") }
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        if let existing {
            guard existing.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path,
                  SafeFile.isTrustedFolder(existing), isEmptyFolder(existing) else {
                throw TekaStore.Refused(reason: "only an empty folder can become a new binder")
            }
            // A synced folder, such as Desktop or Documents under iCloud, can sit in a parent that is not.
            if synced(existing) { throw TekaStore.Refused(reason: "that folder is uploaded by a sync service") }
            if existing.lastPathComponent != name {
                // A change of case only, on a volume that ignores case, finds the folder itself under the new name.
                var from = stat(), to = stat()
                guard lstat(folder.path, &to) != 0
                        || (lstat(existing.path, &from) == 0 && from.st_dev == to.st_dev && from.st_ino == to.st_ino) else {
                    throw TekaStore.Refused(reason: "a folder with that name already exists")
                }
                guard rename(existing.path, folder.path) == 0 else { throw TekaStore.Refused(reason: "the folder could not be renamed") }
                // The new name survives a power loss before the Shelf records the binder under it.
                try AtomicFile.flushFolder(parent, step: "fsync parent folder")
            }
        } else {
            guard mkdir(folder.path, 0o755) == 0 else {
                throw TekaStore.Refused(reason: errno == EEXIST ? "a folder with that name already exists" : "the folder could not be created")
            }
        }
        for sub in template.folders + ["intake"] {
            try FileManager.default.createDirectory(at: folder.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        try AtomicFile.write(Data(template.projectGuide(year).utf8), to: folder.appendingPathComponent("PROJECT.md"), mode: 0o644)

        var meta = JSONObject()
        meta.set("schema_version", .int(2))
        meta.set("name", .string(name))
        meta.set("format", .str("teka"))
        meta.set("format_version", .str("0"))
        meta.set("disclosure", .str("none"))
        meta.set("lifecycle", .str("finite"))
        meta.set("created", .string(today.description))
        meta.set("id_scheme", .str("teka-year-seq"))
        meta.set("modules", .array([]))
        meta.set("template", .obj([("key", .str(template.key)), ("fingerprint", .str(template.fingerprint))]))
        var catalog = JSONObject()
        catalog.set("meta", .object(meta))
        catalog.set("documents", .array([.obj([("id", .str("project-guide")), ("title", .str("Project guide")),
                                              ("path", .str("PROJECT.md")), ("source", .str("template"))])]))
        catalog.set("open_items", .array([]))
        catalog.set("processing_log", .array([]))
        try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: folder.appendingPathComponent("catalog.json"), mode: 0o644)

        var owner = JSONObject()
        owner.set("format_version", .str("0"))
        owner.set("device", .string(deviceID))
        owner.set("adopted_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        try TekaStore(folder: folder, client: client).adopt(survey: JSONObject([(key: "created_from", value: .string(template.key))]),
                                                            owner: owner, now: now)
        guard let state = try StateDirectory.open(folder.appendingPathComponent(".sprava")) else { throw BinderTemplate.Invalid() }
        try state.write(Data(JSONWriter.pretty(template.json).utf8), to: "template.json")

        let ops: [JSONObject] = template.checklist.enumerated().map { n, title in
            var item = JSONObject()
            item.set("id", .string("$new:\(n + 1)"))
            item.set("title", .string(title))
            item.set("status", .str("open"))
            item.set("priority", .str("normal"))
            item.set("no_deadline", .bool(true))
            item.set("kind", .str("other"))
            return JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))]))])
        }
        // The checklist is the person's choice of template, so it arrives as the person's own card.
        let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        guard !ops.isEmpty else { return Created(folder: folder, checklistCard: nil) }
        let card = Proposal.make(title: "Start with the \(template.title.lowercased()) checklist (\(ops.count) items, no dates)", actor: user,
                                 ops: ops, provenance: JSONObject([(key: "template", value: .string(template.key))]), now: now)
        try ProposalStore.save(card, in: folder)
        return Created(folder: folder, checklistCard: card.id)
    }
}

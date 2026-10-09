import BinderFormat
import Foundation
import SpravaKit

/// The stamp of an adopted binder (binder-v0 §9.4 step 6): offered only when the catalog, once stamped, would be a
/// ready v0 binder, with the meta values v0 cannot read kept aside first (binder-v0 §9.5).
extension Adoption {
    /// The stamp card of binder-v0 §9.4 step 6, when the catalog, after the `pending` ops, would be a clean v0
    /// catalog; a lifeproj v1 catalog also gets `schema_version: 2`. nil otherwise.
    static func stampProposal(_ folder: URL, survey: JSONObject, pending: [JSONObject], client: String, now: Date) -> Proposal? {
        let teka = Teka.read(folder)
        guard let current = teka.catalog, teka.level == .lifeprojV2 || teka.level == .lifeprojV1 else { return nil }
        let importActor = JSONObject([(key: "kind", value: .str("import")), (key: "client", value: .string(client))])
        let lifeprojReach = survey["lifeproj_can_reach"] == .bool(true)
        let found = current["meta"]?.objectValue ?? JSONObject()
        // A meta value of a v0 field that the v0 types reject goes to `legacy_<field>` first, by `set_meta` in the
        // same card, so the stamp never makes a binder that needs attention (binder-v0 §9.4 step 4, §9.5).
        let setMeta = metaRepair(found)
        var meta = found
        for key in setMeta?["unset"]?.arrayValue?.compactMap(\.stringValue) ?? [] { meta.remove(key) }
        for entry in setMeta?["set"]?.objectValue?.entries ?? [] { meta.set(entry.key, entry.value) }
        var patch: [JSONValue] = []
        // A value the stamp writes over (a found `format`, `format_version`, `disclosure` or a name that is not a
        // non-empty string) is kept aside under the next free `legacy_<field>` first (binder-v0 §9.5); with none free,
        // no stamp is offered. `schema_version` is the one value replaced outright (binder-v0 §9.4 step 6); the
        // migrate's `from` records it.
        var noLegacyKey = false
        func add(_ key: String, _ value: JSONValue, keepAside: Bool = true) {
            if keepAside, let old = meta[key], old != value {
                guard let aside = legacyKey(key, in: meta) else { noLegacyKey = true; return }
                patch.append(.obj([("op", .str("add")), ("path", .string("/meta/\(aside)")), ("value", old)]))
                meta.set(aside, old)
            }
            patch.append(.obj([("op", .str(meta[key] == nil ? "add" : "replace")), ("path", .string("/meta/\(key)")), ("value", value)]))
        }
        if teka.level == .lifeprojV1 { add("schema_version", .int(2), keepAside: false) }
        if (meta["name"]?.stringValue ?? "").isEmpty { add("name", .string(folder.lastPathComponent)) }
        add("format", .str("teka"))
        add("format_version", .str("0"))
        add("disclosure", .str(lifeprojReach ? "full" : "none"))
        if meta["modules"] == nil, case .array(let found)? = survey["modules_found"], !found.isEmpty { add("modules", .array(found)) }
        if meta["id_scheme"] == nil { add("id_scheme", survey["ids"] == .str("teka-year-seq") ? .str("teka-year-seq") : .str("opaque")) }
        if noLegacyKey { return nil }
        for key in ["documents", "open_items", "processing_log"] where current[key] == nil {
            patch.append(.obj([("op", .str("add")), ("path", .string("/\(key)")), ("value", .array([]))]))
        }
        var migrateArgs = JSONObject()
        migrateArgs.set("from", .obj([("schema_version", found["schema_version"] ?? .null)]))
        migrateArgs.set("to", .obj([("schema_version", .int(2)), ("format", .str("teka")), ("format_version", .str("0"))]))
        migrateArgs.set("patch", .array(patch))
        let stamp = JSONObject([(key: "op", value: .str("migrate")), (key: "args", value: .object(migrateArgs))])
        let ops = (setMeta.map { [JSONObject([(key: "op", value: .str("set_meta")), (key: "args", value: .object($0))])] } ?? []) + [stamp]
        // Offer the stamp only if, after the pending ops, the catalog would be a ready v0 binder.
        let probe: [JSONObject] = (pending + ops).map { body in
            var line = body
            line.set("id", .string(UUIDv7.make(now: now)))
            line.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
            line.set("actor", .object(importActor))
            return line
        }
        guard let result = try? TransactionGuard.check(probe, on: current), TransactionGuard.violations(result.catalog).isEmpty,
              readyAsV0(result.catalog, in: folder) else { return nil }
        return Proposal.make(title: "Stamp this binder as binder v0", actor: importActor, ops: ops,
                             provenance: JSONObject([(key: "adoption", value: .str("stamp"))]), now: now)
    }

    /// The `set_meta` args that keep aside each v0 meta field whose value the v0 types reject (binder-v0 §4.2): the
    /// value goes to `legacy_<field>`, and the field is removed, since only the person can say what it should be.
    /// nil when every field is fine.
    static func metaRepair(_ meta: JSONObject) -> JSONObject? {
        func strings(_ v: JSONValue) -> Bool { v.arrayValue?.allSatisfy { $0.stringValue != nil } == true }
        let valid: [(String, (JSONValue) -> Bool)] = [
            ("lifecycle", { ["ongoing", "finite"].contains($0.stringValue ?? "") }),
            ("created", { $0.stringValue.flatMap(CalendarDate.strict) != nil }),
            ("id_scheme", { ["teka-year-seq", "opaque"].contains($0.stringValue ?? "") }),
            ("modules", strings),
            ("active_chapters", strings),
        ]
        var set = JSONObject()
        var unset: [JSONValue] = []
        var taken = meta
        for (key, ok) in valid {
            guard let value = meta[key], !ok(value), let aside = legacyKey(key, in: taken) else { continue }
            set.set(aside, value)
            taken.set(aside, value)
            unset.append(.string(key))
        }
        guard !unset.isEmpty else { return nil }
        return JSONObject([(key: "set", value: .object(set)), (key: "unset", value: .array(unset))])
    }

    /// `legacy_<field>`, or `legacy_<field>_2` and so on when that is taken (binder-v0 §9.5).
    static func legacyKey(_ field: String, in meta: JSONObject) -> String? {
        (1...100).lazy.map { $0 == 1 ? "legacy_\(field)" : "legacy_\(field)_\($0)" }.first { meta[$0] == nil }
    }

    /// Whether `catalog` would read as a ready v0 binder in `folder`: the full reading of `Teka.read`, meta and
    /// name included, not only the record rules the guard checks. The probe copy lives under `.sprava/`, so the
    /// catalog's contents never leave the binder, and is removed at once.
    static func readyAsV0(_ catalog: JSONObject, in folder: URL) -> Bool {
        let fm = FileManager.default
        let root = folder.appendingPathComponent(".sprava/probe-\(UUID().uuidString.lowercased())", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let probe = root.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        guard (try? AtomicFile.makePrivateFolder(probe)) != nil,
              (try? AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: probe.appendingPathComponent("catalog.json"))) != nil
        else { return false }
        let teka = Teka.read(probe)
        return teka.level == .tekaV0 && teka.state == .ready
    }

    /// After the person approves a card in a binder that is adopted but not yet stamped, offers the stamp once the
    /// catalog would pass, unless a stamp card is already waiting. A waiting stamp card made before a value it moves
    /// aside was changed is rejected and made again from the catalog as it is. Returns the id of a card it wrote.
    public static func offerStamp(_ folder: URL, client: String = "sprava/0.1", now: Date = Date()) throws -> String? {
        let teka = Teka.read(folder)
        guard teka.level == .lifeprojV1 || teka.level == .lifeprojV2 else { return nil }
        let store = TekaStore(folder: folder)
        for (p, _) in ProposalStore.list(in: folder)
        where p.state == "proposed" && p.raw["provenance"]?["adoption"] == .str("stamp") && !p.changedSince(catalog: teka.catalog).isEmpty {
            try store.reject(p, reason: "the binder settings changed since this card was made", now: now)
        }
        let waiting = ProposalStore.list(in: folder).contains { p, _ in
            p.state == "proposed" && (p.raw["provenance"]?["adoption"] == .str("stamp") || p.ops.contains { $0["op"] == .str("migrate") })
        }
        guard !waiting, let ops = try? store.readOpLog().ops,
              let survey = ops.last(where: { $0["op"] == .str("import_snapshot") })?["args"]?["survey"]?.objectValue,
              let card = stampProposal(folder, survey: survey, pending: [], client: client, now: now) else { return nil }
        try ProposalStore.save(card, in: folder)
        return card.id
    }
}

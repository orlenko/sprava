import CryptoKit
import Foundation

/// Adopting an existing binder in place (binder-v0 §9): a read-only survey, the import snapshot, lossless
/// mechanical fixes applied as `import` ops, and proposals for everything that changes meaning.
public enum Adoption {
    /// lifeproj's three copied-in checker versions, by the SHA-256 of the stamped file (binder-v0 §9.2 step 3).
    public static let checkerVersions: [String: String] = [
        "cbc841229a12f0ca538f9f26af9a7e4a7f9208a185b2ab1ad1c43055bda8da24": "gen1",
        "dc19265c394fb10637238ccb4b20a68970606413741b85333c7d1471a9056cdd": "gen2",
        "b13dcf01647a88e16edf24b1cab2205054709753025b26e546e62069851c916d": "gen3",
    ]

    static let moduleFolders = ["email-intake": "intake/mail", "docs-intake": "intake/_converted", "github-source": "sources",
                                "timeline": "timeline.md", "ledger": "ledger", "chapters": "chapters", "entities": "entities"]

    /// The survey: counts, kinds of problems and record ids only, never personal values (binder-v0 §9.2).
    public static func survey(_ folder: URL, inRegistry: Bool) -> JSONObject {
        let teka = Teka.read(folder)
        let fm = FileManager.default
        var s = JSONObject()
        s.set("state", .string(teka.state.label))
        s.set("level", .string(teka.level?.label ?? "none"))
        if let data = try? Data(contentsOf: folder.appendingPathComponent("catalog_check.py")) {
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            s.set("checker", .string(checkerVersions[hex] ?? "modified-or-unknown"))
        } else {
            s.set("checker", .str("none"))
        }
        let items = teka.items
        var byStatus: [String: Int] = [:]
        for item in items { byStatus[item.object?["status"]?.stringValue ?? "missing", default: 0] += 1 }
        s.set("items_by_status", .obj(byStatus.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) }))
        s.set("done_in_open_items", .int(items.filter { $0.declaredStatus == .done }.count))
        s.set("waiting_without_follow_up_at", .int(items.filter {
            ($0.status == .waiting || $0.status == .blocked) && $0.object?["follow_up_at"] == nil }.count))
        s.set("rule_findings", .int(teka.findings.count))
        let ids = items.compactMap { $0.object?["id"] }
        let prefix = teka.name
        let recommended = ids.allSatisfy { ($0.stringValue ?? "").wholeMatch(of: try! Regex("^\(NSRegularExpression.escapedPattern(for: prefix))-\\d{4}-\\d{3,}$")) != nil }
        s.set("ids", .string(ids.isEmpty ? "none" : recommended ? "teka-year-seq" : "opaque"))
        if let raw = try? String(contentsOf: folder.appendingPathComponent("catalog.json"), encoding: .utf8) {
            s.set("escaped_non_ascii", .bool(raw.contains("\\u")))
            s.set("foreign_absolute_paths", .int(raw.components(separatedBy: "\"/Users/").count - 1
                                                    + raw.components(separatedBy: "\"/home/").count - 1
                                                    + raw.components(separatedBy: "\"~/").count - 1))
        }
        let docs = teka.catalog?["documents"]?.arrayValue ?? []
        s.set("documents", .int(docs.count))
        s.set("documents_missing_fields", .int(docs.filter { d in ["id", "title", "path"].contains { d[$0] == nil } }.count))
        let modules = moduleFolders.filter { fm.fileExists(atPath: folder.appendingPathComponent($0.value).path) }.map(\.key).sorted()
        s.set("modules_found", .array(modules.map(JSONValue.string)))
        // lifeproj reaches the binder when it is registered, equipped, or when the binder's agent notes tell an
        // agent to run lifeproj's publish or drain.
        let notes = ["CLAUDE.md", "AGENTS.md"].compactMap { try? String(contentsOf: folder.appendingPathComponent($0), encoding: .utf8) }
        let notesRunLifeproj = notes.contains { text in
            text.range(of: #"lifeproj\s+(publish|drain)"#, options: .regularExpression) != nil
        }
        s.set("lifeproj_can_reach", .bool(inRegistry || notesRunLifeproj
                                          || fm.fileExists(atPath: folder.appendingPathComponent("catalog_check.py").path)))
        s.set("hooks_may_send_data", .bool(((try? String(contentsOf: folder.appendingPathComponent(".claude/settings.json"), encoding: .utf8)) ?? "").contains("\"hooks\"")))
        s.set("credentials_files", .int(["scripts/mail/.env", "intake/mail/.env"].filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }.count))
        s.set("old_email_intake_layout", .bool(fm.fileExists(atPath: folder.appendingPathComponent("intake/mail/state.json").path)))
        s.set("synced_location", .bool(syncedLocation(folder)))
        return s
    }

    /// iCloud Drive, File Provider folders, and Desktop or Documents (which iCloud may sync): adoption is refused
    /// there (architecture 2.3; spike e confirms the Desktop and Documents detection).
    public static func syncedLocation(_ folder: URL) -> Bool {
        let path = folder.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(home + "/Library/Mobile Documents") || path.hasPrefix(home + "/Library/CloudStorage") { return true }
        if let values = try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true { return true }
        return false
    }

    public struct Result {
        public var mechanical: [JSONObject]
        public var proposals: [Proposal]
    }

    /// Adopts `folder` in place. Writes only `.sprava/` and `.teka.lock`, plus `catalog.json` for the lossless
    /// mechanical fixes. Everything that changes meaning becomes a proposal.
    public static func adopt(_ folder: URL, inRegistry: Bool, deviceID: String, today: CalendarDate,
                             now: Date = Date(), client: String = "sprava/0.1") throws -> Result {
        let teka = Teka.read(folder)
        switch teka.state {
        case .notATeka, .corrupt, .unknownLevel:
            throw TekaStore.Refused(reason: "cannot adopt: \(teka.state.label)")
        default: break
        }
        if teka.writesBlocked { throw TekaStore.Refused(reason: "cannot adopt until this is repaired: " + teka.reasons.joined(separator: "; ")) }
        if syncedLocation(folder) { throw TekaStore.Refused(reason: "this folder is uploaded by a sync service") }
        let store = TekaStore(folder: folder, client: client)
        let survey = survey(folder, inRegistry: inRegistry)
        var owner = JSONObject()
        owner.set("format_version", .str("0"))
        owner.set("device", .string(deviceID))
        owner.set("adopted_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        try store.adopt(survey: survey, owner: owner, now: now)

        let importActor = JSONObject([(key: "kind", value: .str("import")), (key: "client", value: .string(client))])
        let catalog = Teka.read(folder).catalog ?? JSONObject()
        let items = catalog["open_items"]?.arrayValue ?? []
        let log = catalog["processing_log"]?.arrayValue ?? []
        let broken = Set(teka.findings.map(\.location))
        // An id held by two items is left for the person: a fix to one would be a fix to both.
        var seenIDs: [JSONValue: Int] = [:]
        for item in items { if let id = item["id"] { seenIDs[id, default: 0] += 1 } }

        // Step 3: mechanical, lossless fixes (binder-v0 §9.4).
        var bodies: [TekaStore.OpBody] = []
        for (i, item) in items.enumerated() {
            guard case .object(let o) = item, let id = o["id"], !broken.contains("open_items[\(i)]"), seenIDs[id] == 1 else { continue }
            var set = JSONObject()
            var unset: [String] = []
            var derived = o["derived"]?.arrayValue?.compactMap(\.stringValue) ?? []
            var notes: [String] = []
            for key in ["due", "waiting_on", "link"] where o[key] == .null { unset.append(key) }
            if o["no_deadline"] == .bool(true), o["due"] == .str("") { unset.append("due") }
            if case .string(let due)? = o["due"], !due.isEmpty, CalendarDate.strict(due) == nil, let d = CalendarDate.lenient(due) {
                set.set("due", .string(d.description))
                derived.append("due")
                notes.append("due was written \(due)")
            }
            let status = o["status"]?.stringValue
            if (status == "waiting" || status == "blocked"), o["follow_up_at"] == nil {
                let expected = o["expected_by"]?.stringValue.flatMap(CalendarDate.strict)
                let base = expected?.adding(days: 1) ?? today.adding(days: 7)
                var follow = base
                if let due = (set["due"] ?? o["due"])?.stringValue.flatMap(CalendarDate.strict), due < follow { follow = due }
                if follow < today { follow = today }
                set.set("follow_up_at", .string(follow.description))
                derived.append("follow_up_at")
            }
            guard !set.entries.isEmpty || !unset.isEmpty else { continue }
            if !derived.isEmpty, set.entries.contains(where: { ["due", "follow_up_at"].contains($0.key) }) {
                set.set("derived", .array(derived.map(JSONValue.string)))
            }
            var args = JSONObject()
            args.set("id", id)
            if !set.entries.isEmpty { args.set("set", .object(set)) }
            if !unset.isEmpty { args.set("unset", .array(unset.map(JSONValue.string))) }
            var extra: [(String, JSONValue)] = []
            if !notes.isEmpty { extra.append(("note", .string(notes.joined(separator: "; ")))) }
            bodies.append(.init(op: "update_item", args: args, actor: importActor, extra: extra))
        }
        // Each fix is guarded on its own, so one the guard refuses never blocks the others or the proposals.
        var mechanical: [JSONObject] = []
        for body in bodies {
            if let applied = try? store.apply([body], now: now) { mechanical += applied }
        }

        // Step 4: proposals for what changes meaning.
        var proposals: [Proposal] = []
        let closedIDs = Set(log.compactMap { $0["id"] })
        var closeOps: [JSONObject] = []
        for item in items {
            guard let id = item["id"] else { continue }
            let isDone = item["status"] == .str("done")
            guard isDone || closedIDs.contains(id) else { continue }
            var args = JSONObject()
            args.set("id", id)
            args.set("closed_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
            args.set("source", .str("import"))
            args.set("note", .string(isDone ? "status was done in open_items at adoption"
                                              : "its id already closes a processing log entry"))
            closeOps.append(JSONObject([(key: "op", value: .str("complete")), (key: "args", value: .object(args))]))
        }
        if !closeOps.isEmpty {
            proposals.append(Proposal.make(title: "Close \(closeOps.count) item(s) already marked done", actor: importActor,
                                           ops: closeOps, now: now))
        }

        // Step 6: the stamp, when the catalog would then satisfy v0. Proposed after the closures.
        let lifeprojReach = survey["lifeproj_can_reach"] == .bool(true)
        var patch: [JSONValue] = []
        let meta = Teka.read(folder).catalog?["meta"]?.objectValue ?? JSONObject()
        func add(_ key: String, _ value: JSONValue) {
            patch.append(.obj([("op", .str(meta[key] == nil ? "add" : "replace")), ("path", .string("/meta/\(key)")), ("value", value)]))
        }
        if meta["name"] == nil { add("name", .string(folder.lastPathComponent)) }
        add("format", .str("teka"))
        add("format_version", .str("0"))
        add("disclosure", .str(lifeprojReach ? "full" : "none"))
        if meta["modules"] == nil, case .array(let found)? = survey["modules_found"], !found.isEmpty { add("modules", .array(found)) }
        if meta["id_scheme"] == nil { add("id_scheme", survey["ids"] == .str("teka-year-seq") ? .str("teka-year-seq") : .str("opaque")) }
        for key in ["documents", "open_items", "processing_log"] where Teka.read(folder).catalog?[key] == nil {
            patch.append(.obj([("op", .str("add")), ("path", .string("/\(key)")), ("value", .array([]))]))
        }
        var migrateArgs = JSONObject()
        migrateArgs.set("from", .obj([("schema_version", meta["schema_version"] ?? .null)]))
        migrateArgs.set("to", .obj([("schema_version", .int(2)), ("format", .str("teka")), ("format_version", .str("0"))]))
        migrateArgs.set("patch", .array(patch))
        let stamp = JSONObject([(key: "op", value: .str("migrate")), (key: "args", value: .object(migrateArgs))])
        // Offer the stamp only if, after the closures, the catalog would be a clean v0 catalog.
        if let current = Teka.read(folder).catalog, Teka.read(folder).level == .lifeprojV2 {
            var trial = current
            let probe: [JSONObject] = (closeOps + [stamp]).map { body in
                var line = body
                line.set("id", .string(UUIDv7.make(now: now)))
                line.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
                line.set("actor", .object(importActor))
                return line
            }
            if let result = try? TransactionGuard.check(probe, on: trial) {
                trial = result.catalog
                if TransactionGuard.violations(trial).isEmpty {
                    proposals.append(Proposal.make(title: "Stamp this binder as binder v0", actor: importActor,
                                                   ops: [stamp], now: now))
                }
            }
        }
        for p in proposals { try ProposalStore.save(p, in: folder) }
        return Result(mechanical: mechanical, proposals: proposals)
    }
}

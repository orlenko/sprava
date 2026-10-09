import BinderFormat
import CryptoKit
import Foundation
import SpravaKit

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
        let checkerURL = folder.appendingPathComponent("catalog_check.py")
        if let data = readInside(folder, "catalog_check.py", limit: 1024 * 1024) {
            let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            s.set("checker", .string(checkerVersions[hex] ?? "modified-or-unknown"))
        } else {
            var st = stat()
            s.set("checker", .str(lstat(checkerURL.path, &st) == 0 ? "modified-or-unknown" : "none"))
        }
        let items = teka.items
        // A status outside the closed list is counted as `unknown`, never by its text, which may be anything.
        var byStatus: [String: Int] = [:]
        for item in items {
            let status = item.object?["status"]
            byStatus[status == nil ? "missing" : item.declaredStatus?.rawValue ?? "unknown", default: 0] += 1
        }
        s.set("items_by_status", .obj(byStatus.sorted { $0.key < $1.key }.map { ($0.key, .int($0.value)) }))
        s.set("done_in_open_items", .int(items.filter { $0.declaredStatus == .done }.count))
        s.set("waiting_without_follow_up_at", .int(items.filter {
            ($0.status == .waiting || $0.status == .blocked) && $0.object?["follow_up_at"] == nil }.count))
        s.set("rule_findings", .int(teka.findings.count))
        let ids = items.compactMap { $0.object?["id"] }
        let prefix = teka.name
        let recommended = ids.allSatisfy { ($0.stringValue ?? "").wholeMatch(of: try! Regex("^\(NSRegularExpression.escapedPattern(for: prefix))-\\d{4}-\\d{3,}$")) != nil }
        s.set("ids", .string(ids.isEmpty ? "none" : recommended ? "teka-year-seq" : "opaque"))
        if let data = readInside(folder, "catalog.json", limit: 64 * 1024 * 1024), let raw = String(data: data, encoding: .utf8) {
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
        let notes = ["CLAUDE.md", "AGENTS.md"].compactMap { readInside(folder, $0, limit: 1024 * 1024) }
            .map { withoutAddendum(String(decoding: $0, as: UTF8.self)) }
        let notesRunLifeproj = notes.contains { text in
            text.range(of: #"lifeproj\s+(publish|drain)"#, options: .regularExpression) != nil
        }
        s.set("lifeproj_can_reach", .bool(inRegistry || notesRunLifeproj
                                          || fm.fileExists(atPath: folder.appendingPathComponent("catalog_check.py").path)))
        let settings = readInside(folder, ".claude/settings.json", limit: 1024 * 1024).map { String(decoding: $0, as: UTF8.self) } ?? ""
        s.set("hooks_may_send_data", .bool(settings.contains("\"hooks\"")))
        s.set("credentials_files", .int(["scripts/mail/.env", "intake/mail/.env"].filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path) }.count))
        s.set("old_email_intake_layout", .bool(fm.fileExists(atPath: folder.appendingPathComponent("intake/mail/state.json").path)))
        s.set("synced_location", .bool(syncedLocation(folder)))
        return s
    }

    /// A file of the binder, read for the survey without leaving the binder (binder-v0 §3.6): a link is followed
    /// only to a regular file of this user inside the binder, and nothing else is opened, so a link to a device or a
    /// named pipe never hangs the survey. nil for a file that is missing or may not be read.
    static func readInside(_ folder: URL, _ path: String, limit: Int) -> Data? {
        let root = folder.resolvingSymlinksInPath().path
        let real = folder.appendingPathComponent(path).resolvingSymlinksInPath()
        guard real.path.hasPrefix(root + "/") else { return nil }
        if case .ok(let data) = SafeFile.read(real, limit: limit) { return data }
        return nil
    }

    /// A manual without Sprava's own addendum, which names `lifeproj publish` only to forbid it: from the marker
    /// line to the next `## ` heading after the addendum's own, or to the end. The marker counts only as a line of its
    /// own, as `ManualAddendum.isPresent` reads it: a manual that mentions it in its prose keeps all of its text.
    static func withoutAddendum(_ text: String) -> String {
        var out: [Substring] = []
        var inAddendum = false
        var sawHeading = false
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            if line.trimmingCharacters(in: .whitespaces) == ManualAddendum.marker {
                inAddendum = true
                sawHeading = false
                continue
            }
            if inAddendum, line.hasPrefix("## ") {
                if !sawHeading { sawHeading = true; continue }
                inAddendum = false
            }
            if !inAddendum { out.append(line) }
        }
        return out.joined(separator: "\n")
    }

    /// iCloud Drive, File Provider folders, and Desktop or Documents (which iCloud may sync): adoption is refused
    /// there (architecture 2.3; spike e confirms the Desktop and Documents detection).
    public static func syncedLocation(_ folder: URL) -> Bool {
        if inSyncRoot(folder.resolvingSymlinksInPath().path, home: FileManager.default.homeDirectoryForCurrentUser.path) { return true }
        if let values = try? folder.resourceValues(forKeys: [.isUbiquitousItemKey]), values.isUbiquitousItem == true { return true }
        return false
    }

    /// Whether `path` is iCloud Drive or a File Provider folder, or inside one, matched by whole path components, so a
    /// sibling such as `CloudStorageBackup` is not taken for `CloudStorage`.
    static func inSyncRoot(_ path: String, home: String) -> Bool {
        [home + "/Library/Mobile Documents", home + "/Library/CloudStorage"].contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    public struct Result {
        public var mechanical: [JSONObject]
        public var proposals: [Proposal]
    }

    /// Present while an adoption's fixes and cards are not all written: made before the import snapshot and
    /// removed once every card is saved, so an adoption cut short is finished by running it again.
    static func unfinishedMarker(_ folder: URL) -> URL { folder.appendingPathComponent(".sprava/adoption-unfinished") }

    /// Adopts `folder` in place. Writes only `.sprava/` and `.teka.lock`, plus `catalog.json` for the lossless
    /// mechanical fixes. Everything that changes meaning becomes a proposal. An adoption cut short after its import
    /// snapshot resumes: the snapshot and its survey are kept, the fixes are applied where still needed, and a card
    /// already saved is not saved twice.
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
        let marker = unfinishedMarker(folder)
        let history = try store.readOpLog().ops
        let survey: JSONObject
        if history.isEmpty {
            survey = Self.survey(folder, inRegistry: inRegistry)
            var owner = JSONObject()
            owner.set("format_version", .str("0"))
            owner.set("device", .string(deviceID))
            owner.set("adopted_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
            try AtomicFile.makePrivateFolder(marker.deletingLastPathComponent())
            try AtomicFile.write(Data(), to: marker)
            try store.adopt(survey: survey, owner: owner, now: now)
        } else {
            var st = stat()
            guard lstat(marker.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  let found = history.first(where: { $0["op"] == .str("import_snapshot") })?["args"]?["survey"]?.objectValue
            else { throw TekaStore.Refused(reason: "already adopted") }
            survey = found
        }

        let importActor = JSONObject([(key: "kind", value: .str("import")), (key: "client", value: .string(client))])
        let catalog = Teka.read(folder).catalog ?? JSONObject()
        let items = catalog["open_items"]?.arrayValue ?? []
        let log = catalog["processing_log"]?.arrayValue ?? []
        // An id held by two items is left for the person: a fix to one would be a fix to both.
        var seenIDs: [JSONValue: Int] = [:]
        for item in items { if let id = item["id"] { seenIDs[id, default: 0] += 1 } }

        // Step 3: mechanical, lossless fixes (binder-v0 §9.4). An item that breaks the rules gets its fix too: the guard
        // takes it only when it leaves the item valid (an empty `due` beside `no_deadline`, say), and refuses it otherwise.
        let fixable = items.compactMap { item -> JSONValue? in
            guard let id = item["id"], seenIDs[id] == 1 else { return nil }
            return id
        }
        let mechanical = try applyMechanicalFixes(store: store, ids: fixable, today: today, actor: importActor, now: now)

        // Step 4: proposals for what changes meaning.
        var proposals: [Proposal] = []
        let closedIDs = Set(log.compactMap { $0["id"] })
        var closeOps: [JSONObject] = []
        // An op names its item by id, so an id two items share would close whichever comes first: those items go to
        // the person on a card they settle by hand.
        var shared: [JSONValue] = []
        for item in items {
            guard let id = item["id"] else { continue }
            guard seenIDs[id] == 1 else {
                if !shared.contains(id) { shared.append(id) }
                continue
            }
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
        if !shared.isEmpty {
            let names = shared.map { JSONWriter.compact($0) }.joined(separator: ", ")
            proposals.append(Proposal.make(title: "Give each of these ids to one open item only, by hand, then reject this card: " + names,
                                           actor: importActor, ops: [],
                                           provenance: JSONObject([(key: "adoption", value: .str("shared-id")), (key: "manual_repair", value: .bool(true)),
                                                                   (key: "ids", value: .array(shared))]), now: now))
        }
        // No op can name an item without an id (or an entry that is not an item at all), so those go to the person
        // too, by their place in the list, counted from 1.
        let unnamed = items.indices.filter { items[$0].objectValue == nil || items[$0]["id"] == nil || items[$0]["id"] == .null }
        if !unnamed.isEmpty {
            let places = unnamed.map { String($0 + 1) }.joined(separator: ", ")
            proposals.append(Proposal.make(title: "Give an id to the open items at these places in the list, by hand, then reject this card: " + places,
                                           actor: importActor, ops: [],
                                           provenance: JSONObject([(key: "adoption", value: .str("no-id")), (key: "manual_repair", value: .bool(true)),
                                                                   (key: "positions", value: .array(unnamed.map { .int($0) }))]), now: now))
        }

        // Repairs are judged after the mechanical fixes. A lifeproj or pre-lifeproj catalog is judged by the v0 rules,
        // since those are what the stamp needs: a redacted item without a kind passes lifeproj's rules, and a v1 or
        // pre-lifeproj catalog has none, yet none of them stamps. Adoption runs once, so its cards are the only ones.
        let afterFixes = Teka.read(folder)
        let fixed = afterFixes.catalog ?? catalog
        let towardV0 = teka.level == .lifeprojV1 || teka.level == .lifeprojV2 || teka.level == .preLifeproj
        let repairItems = fixed["open_items"]?.arrayValue ?? []
        let findings = towardV0 ? ItemRules.check(items: repairItems, log: fixed["processing_log"]?.arrayValue ?? [], v0: true)
                                : afterFixes.findings
        proposals += repairCards(findings.map { ($0.code, $0.location, $0.field) }, items: repairItems, today: today,
                                 actor: importActor, now: now)

        // A pre-lifeproj catalog first gets `meta.schema_version: 1`, keeping a value below 1 aside (§9.4 step 4) under
        // the next free legacy name (§9.5); with none free, no migration is offered. A core key that is not an array
        // stays in needs migration for now.
        if teka.level == .preLifeproj, let found = Teka.read(folder).catalog {
            var patch: [JSONValue] = []
            if case .object(var meta)? = found["meta"] {
                if meta["schema_version"] != nil {
                    do {
                        if let aside = try keepAside("schema_version", in: &meta, becoming: .int(1)) {
                            patch.append(.obj([("op", .str("add")), ("path", .string("/meta/\(aside.key)")), ("value", aside.value)]))
                        }
                        patch.append(.obj([("op", .str("replace")), ("path", .str("/meta/schema_version")), ("value", .int(1))]))
                    } catch {}
                } else {
                    patch.append(.obj([("op", .str("add")), ("path", .str("/meta/schema_version")), ("value", .int(1))]))
                }
            } else if found["meta"] == nil {
                patch.append(.obj([("op", .str("add")), ("path", .str("/meta")), ("value", .obj([("schema_version", .int(1))]))]))
            }
            if !patch.isEmpty {
                let migrate = JSONObject([(key: "op", value: .str("migrate")), (key: "args", value: .obj([("patch", .array(patch))]))])
                proposals.append(Proposal.make(title: "Mark this catalog as lifeproj v1, the first step to binder v0", actor: importActor,
                                               ops: [migrate], provenance: JSONObject([(key: "adoption", value: .str("schema"))]), now: now))
            }
        }

        // Step 6: the stamp, when the catalog would then satisfy v0. Proposed after the closures.
        if let stamp = stampProposal(folder, survey: survey, pending: closeOps, client: client, now: now) { proposals.append(stamp) }
        // A card an interrupted run already saved is kept as it is, never saved a second time. A new card is returned
        // as saved, with the fingerprints of the items it touches, so approving it still notices an item changed since.
        let saved = Dictionary(ProposalStore.list(in: folder).map { (cardKey($0.0), $0.0) }) { first, _ in first }
        proposals = try proposals.map { p in
            if let earlier = saved[cardKey(p)] { return earlier }
            let digest = try ProposalStore.save(p, in: folder)
            return try ProposalStore.load(p.id, in: folder, expectedDigest: digest)
        }
        unlink(marker.path)
        return Result(mechanical: mechanical, proposals: proposals)
    }

    /// What makes two adoption cards the same card: the title, and each op's type and record id. Times differ
    /// between runs and are left out.
    static func cardKey(_ p: Proposal) -> String {
        p.title + "|" + p.ops.map { ($0["op"]?.stringValue ?? "") + ":" + JSONWriter.compact($0["args"]?["id"] ?? .null) }
            .joined(separator: ",")
    }

    /// The index in `open_items` a finding's location names, written `open_items[<digits>]`; nil for any other place.
    /// It is the transaction guard's rule, so a repair card and a violation name the same item.
    static func itemIndex(_ location: String) -> Int? { TransactionGuard.itemIndex(location) }

    /// One repair card per item that breaks its level's rules: a migration cannot invent a date or a party, so the
    /// person fills them in on the card (binder-v0 §9.4 step 4). Closures and shared ids are handled elsewhere, and a
    /// finding about anything but an open item makes no card here.
    static func repairCards(_ findings: [(code: RuleFinding.Code, location: String, field: String?)], items: [JSONValue],
                            today: CalendarDate, actor: JSONObject, now: Date) -> [Proposal] {
        let handled: Set<RuleFinding.Code> = [.doneInOpenItems, .reusedID, .duplicateID]
        var ids: [JSONValue: Int] = [:]
        for item in items { if let id = item["id"] { ids[id, default: 0] += 1 } }
        var repaired = Set<String>()
        var cards: [Proposal] = []
        for finding in findings where !handled.contains(finding.code) {
            guard let index = itemIndex(finding.location), items.indices.contains(index),
                  case .object(let o) = items[index], let id = o["id"], ids[id] == 1,
                  repaired.insert(finding.location).inserted else { continue }
            let missing = findings.filter { $0.location == finding.location && !handled.contains($0.code) }
                .map { $0.field.map { "\($0)" } ?? $0.code.rawValue }
            var set = JSONObject()
            let status = o["status"]?.stringValue
            if status == "waiting" || status == "blocked", o["follow_up_at"] == nil {
                // A `derived` the new list does not carry (an object, a mixed list) is kept aside first; with no legacy
                // name free, the card leaves the follow-up date to the person.
                var taken = o
                let derived = (o["derived"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter { $0 != "follow_up_at" }
                let names: JSONValue = .array((derived + ["follow_up_at"]).map(JSONValue.string))
                do {
                    if let aside = try keepAside("derived", in: &taken, becoming: names) { set.set(aside.key, aside.value) }
                    let due = o["due"]?.stringValue.flatMap { CalendarDate.strict($0) ?? CalendarDate.lenient($0) }
                    set.set("follow_up_at", .string(followUp(o, due: due, today: today).description))
                    set.set("derived", names)
                } catch {}
            }
            var op = JSONObject([(key: "op", value: .str("update_item")),
                                 (key: "args", value: .obj([("id", id), ("set", .object(set))]))])
            op.set("card", .obj([("flags", .array([.string("fill in what is missing: " + missing.joined(separator: ", "))]))]))
            cards.append(Proposal.make(title: "Fill in what this item is missing", actor: actor, ops: [op],
                                       provenance: JSONObject([(key: "repair", value: .array(missing.map(JSONValue.string)))]), now: now))
        }
        return cards
    }

    /// The derived follow-up date of a waiting or blocked item (binder-v0 §5.3): the day after `expected_by`, else a
    /// week from today, but never after the item's due date, so it reaches Nudge before its deadline, and never
    /// before today.
    static func followUp(_ o: JSONObject, due: CalendarDate?, today: CalendarDate) -> CalendarDate {
        let expected = o["expected_by"]?.stringValue.flatMap(CalendarDate.strict)
        var follow = expected?.adding(days: 1) ?? today.adding(days: 7)
        if let due, due < follow { follow = due }
        if follow < today { follow = today }
        return follow
    }

    struct NothingToFix: Error {}

    /// Applies the mechanical fix of each item in `ids`, one batch per item. Each fix is built from the item as read
    /// under the lock, after outside edits were absorbed, so a value someone wrote after the survey (a follow-up date,
    /// say) is seen and never overwritten. Each is guarded on its own, so one the guard refuses never blocks the
    /// others or the proposals. Any other failure (a disk error, a busy or unreadable binder) throws, so the adoption
    /// stops with its unfinished marker in place and is finished by running it again.
    static func applyMechanicalFixes(store: TekaStore, ids: [JSONValue], today: CalendarDate, actor: JSONObject,
                                     now: Date) throws -> [JSONObject] {
        var mechanical: [JSONObject] = []
        for id in ids {
            do {
                mechanical += try store.apply(building: { catalog, _ in
                    let found = (catalog["open_items"]?.arrayValue ?? []).filter { $0["id"] == id }
                    guard found.count == 1, case .object(let o) = found[0],
                          let body = mechanicalFix(o, today: today, actor: actor) else { throw NothingToFix() }
                    return [body]
                }, now: now)
            } catch is NothingToFix {
            } catch is TransactionGuard.Rejection {
            }
        }
        return mechanical
    }

    /// The lossless fixes of binder-v0 §9.4 step 3 for one item, as one `update_item`; nil when it needs none. Every
    /// value it replaces or removes goes through `keepAside`: a compact due date, a `derived` that is not a list of
    /// names, stay in the item under `legacy_<field>`. With no legacy name free, the item gets no fix.
    static func mechanicalFix(_ o: JSONObject, today: CalendarDate, actor: JSONObject) -> TekaStore.OpBody? {
        guard let id = o["id"] else { return nil }
        var taken = o
        var set = JSONObject()
        var unset: [String] = []
        var added: [String] = []
        var notes: [String] = []
        func replace(_ key: String, with value: JSONValue?) throws {
            if let aside = try keepAside(key, in: &taken, becoming: value) { set.set(aside.key, aside.value) }
            if let value { set.set(key, value) } else { unset.append(key) }
        }
        do {
            for key in ["due", "waiting_on", "link"] where o[key] == .null { try replace(key, with: nil) }
            if o["no_deadline"] == .bool(true), o["due"] == .str("") { try replace("due", with: nil) }
            if case .string(let due)? = o["due"], !due.isEmpty, CalendarDate.strict(due) == nil, let d = CalendarDate.lenient(due) {
                try replace("due", with: .string(d.description))
                added.append("due")
                notes.append("due was written \(due)")
            }
            let status = o["status"]?.stringValue
            if (status == "waiting" || status == "blocked"), o["follow_up_at"] == nil {
                let follow = followUp(o, due: (set["due"] ?? o["due"])?.stringValue.flatMap(CalendarDate.strict), today: today)
                try replace("follow_up_at", with: .string(follow.description))
                added.append("follow_up_at")
            }
            if !added.isEmpty {
                let kept = (o["derived"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter { !added.contains($0) }
                try replace("derived", with: .array((kept + added).map(JSONValue.string)))
            }
        } catch {
            return nil
        }
        guard !set.entries.isEmpty || !unset.isEmpty else { return nil }
        var args = JSONObject()
        args.set("id", id)
        if !set.entries.isEmpty { args.set("set", .object(set)) }
        if !unset.isEmpty { args.set("unset", .array(unset.map(JSONValue.string))) }
        var extra: [(String, JSONValue)] = []
        if !notes.isEmpty { extra.append(("note", .string(notes.joined(separator: "; ")))) }
        return .init(op: "update_item", args: args, actor: actor, extra: extra)
    }
}

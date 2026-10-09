import BinderFormat
import Foundation
import SpravaKit

/// The privacy ratchet (architecture 4.5 step 5; binder-v0 §5.5, §6.7): an outside edit that narrows what a binder
/// shows takes effect at once; one that loosens it does not. Every loosening binder-v0 §5.5 names is held back:
/// `meta.disclosure` raised, `redact` cleared, `slice_title` added, removed or changed, a tag added to a redacted
/// item, or the kind removed from one. The hub slice and MCP keep projecting with the last values the person
/// confirmed until a privacy card is approved.
///
/// In the MVP the confirmed values are kept unsealed (mvp.md section 4): they are the values Sprava itself last
/// applied, read from the binder's op log, which records every op Sprava applied and every outside edit apart.
public enum PrivacyRatchet {
    /// Disclosure levels from the narrowest to the widest.
    static let order = ["none", "kind", "title", "full"]

    /// A disclosure value as found: absent is lifeproj's `full` (binder-v0 §8.1); anything unknown is `none`.
    public static func level(_ value: JSONValue?) -> String {
        guard let value else { return "full" }
        guard case .string(let s) = value, order.contains(s) else { return "none" }
        return s
    }

    public static func narrower(_ a: String, _ b: String) -> String {
        (order.firstIndex(of: a) ?? 0) <= (order.firstIndex(of: b) ?? 0) ? a : b
    }

    /// What Sprava itself last applied: the latest `import_snapshot`, then every later op Sprava applied, skipping
    /// aborted ones; an `external_edit` never changes what stands for an item already known. A redaction is
    /// confirmed by any op that sets it and lifted only by the person's own op (architecture 4.5, 7.3). So is a hub
    /// title: any op may give an item one where it had none, but only the person's own op changes or removes it.
    /// Every item has a baseline from the first time Sprava sees it, at adoption, in its own op, or in an outside
    /// edit it recorded: its hub title or the confirmed absence of one, its redaction, tags and kind, as they were
    /// then. A title added outside later is held back as well. Tags and kind stand as the ops set them; only the
    /// person's own op removes a kind. An item no log state shows yet is taken as found, its first sight.
    public struct Confirmed: Equatable {
        public var disclosure: String
        /// Items whose redaction stands, by the id's canonical text.
        public var redacted: Set<String>
        /// The `slice_title` that stands for each item that has one, by the id's canonical text.
        public var sliceTitles: [String: JSONValue] = [:]
        /// Every item with a baseline, by the id's canonical text: one of them without an entry in `sliceTitles` has
        /// no hub title, confirmed.
        public var known: Set<String> = []
        /// The tags and the kind that stand for each item Sprava knows.
        public var tags: [String: Set<JSONValue>] = [:]
        public var kinds: [String: JSONValue] = [:]
    }

    /// A `slice_title` that counts: a truthy value, as the projection reads it.
    static func sliceTitle(_ value: JSONValue?) -> JSONValue? { value.flatMap { ItemRules.isTruthy($0) ? $0 : nil } }

    static func key(_ id: JSONValue?) -> String? { id.flatMap { try? Canonical.serialize($0) } }

    public static func confirmed(opLog ops: [JSONObject]) -> Confirmed? {
        guard let start = ops.lastIndex(where: { $0["op"] == .str("import_snapshot") }) else { return nil }
        let aborted = Set(ops.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        let snapshot = ops[start]["args"]?["catalog"]
        var c = Confirmed(disclosure: level(snapshot?["meta"]?["disclosure"]), redacted: [])
        func record(_ item: JSONValue?) {
            guard let k = key(item?["id"]) else { return }
            c.known.insert(k)
            if item?["redact"] == .bool(true) { c.redacted.insert(k) }
            if let t = sliceTitle(item?["slice_title"]) { c.sliceTitles[k] = t }
            c.tags[k] = Set(item?["tags"]?.arrayValue ?? [])
            if let kind = item?["kind"] { c.kinds[k] = kind }
        }
        for item in snapshot?["open_items"]?.arrayValue ?? [] { record(item) }
        // The catalog as each op left it, so an item first seen in an outside edit gets its baseline as that edit left
        // it (binder-v0 §5.5 holds back loosening an item, not the arrival of a new one), and never goes without one.
        var state = snapshot?.objectValue ?? JSONObject()
        for op in ops.dropFirst(start + 1) where !aborted.contains(op["id"]?.stringValue ?? "") {
            defer {
                if let next = try? OpApplier.apply(op, to: state) { state = next }
                // Only an outside edit or a migration brings an item no op of Sprava's named; add_item and reopen
                // record theirs below.
                if op["op"] == .str("external_edit") || op["op"] == .str("migrate") {
                    for item in state["open_items"]?.arrayValue ?? [] where !(key(item["id"]).map(c.known.contains) ?? true) { record(item) }
                }
            }
            let args = op["args"]
            let byUser = op["actor"]?["kind"] == .str("user")
            switch op["op"]?.stringValue {
            case "set_disclosure"?:
                if byUser { c.disclosure = level(args?["disclosure"]) }
            case "migrate"?:
                for step in args?["patch"]?.arrayValue ?? [] where step["path"] == .str("/meta/disclosure") {
                    c.disclosure = step["op"] == .str("remove") ? "full" : level(step["value"])
                }
            case "add_item"?, "reopen"?:
                record(args?["item"])
            case "update_item"?:
                guard let k = key(args?["id"]) else { continue }
                let unset = args?["unset"]?.arrayValue ?? []
                if args?["set"]?["redact"] == .bool(true) {
                    c.redacted.insert(k)
                } else if byUser, args?["set"]?["redact"] != nil || unset.contains(.str("redact")) {
                    c.redacted.remove(k)
                }
                let title = args?["set"]?["slice_title"]
                if byUser || c.sliceTitles[k] == nil, title != nil || unset.contains(.str("slice_title")) {
                    c.sliceTitles[k] = sliceTitle(title)
                }
                if let tags = args?["set"]?["tags"] { c.tags[k] = Set(tags.arrayValue ?? []) }
                if unset.contains(.str("tags")) { c.tags[k] = [] }
                if let kind = args?["set"]?["kind"] { c.kinds[k] = kind }
                if byUser, unset.contains(.str("kind")) { c.kinds[k] = nil }
            default:
                break
            }
        }
        return c
    }

    /// What the cross-binder surfaces use for one binder: the narrower of the found and the confirmed values.
    public struct View: Equatable {
        public var disclosure: String
        /// Items to project redacted, by the id's canonical text.
        public var redacted: Set<String>
        /// The level found in the catalog when it is wider than the confirmed one, waiting for a card.
        public var widenedTo: String?
        /// Open items whose redaction an outside edit cleared, waiting for a card.
        public var lifted: [JSONValue]
        /// Open items whose `slice_title` an outside edit added, removed or changed, waiting for a card: the hub keeps
        /// the confirmed title, or none, until then.
        public var retitled: [Retitled] = []
        /// The hub title of every item whose title stands apart from the found one, by the id's canonical text,
        /// closed items included: the confirmed `slice_title`, or, where none is confirmed but one was added
        /// outside, the title the projection gives without one (`[redacted]` for a redacted item). The hub never
        /// sees another title for them until the person allows it.
        public var titles: [String: JSONValue] = [:]
        /// Redacted items that gained a tag outside, and redacted items whose kind was removed outside, waiting for
        /// a card. A tag waiting holds the binder at disclosure `title` at most, where a redacted item's tags are
        /// not published (binder-v0 §5.5); the slice at `full` carries no kind, and `kinds` keeps the confirmed one.
        public var retagged: [Retagged] = []
        public var unkinded: [JSONValue] = []
        public var kinds: [String: JSONValue] = [:]
    }

    public struct Retitled: Equatable {
        public var id: JSONValue
        /// The title the hub keeps (nil when none is confirmed), and the one found in the catalog (nil when removed).
        public var confirmed: JSONValue?
        public var found: JSONValue?
    }

    public struct Retagged: Equatable {
        public var id: JSONValue
        public var found: JSONValue
    }

    /// The view of an adopted binder. An op log that cannot be read fails closed: disclosure `none`.
    public static func view(folder: URL, catalog: JSONObject) -> View {
        let found = level(catalog["meta"]?["disclosure"])
        let items = catalog["open_items"]?.arrayValue ?? []
        let foundRedacted = Set(items.filter { $0["redact"] == .bool(true) }.compactMap { key($0["id"]) })
        guard let ops = try? TekaStore(folder: folder).readOpLog().ops else {
            return View(disclosure: "none", redacted: foundRedacted, widenedTo: nil, lifted: [])
        }
        guard let confirmed = confirmed(opLog: ops) else {
            return View(disclosure: found, redacted: foundRedacted, widenedTo: nil, lifted: [])
        }
        let redacted = foundRedacted.union(confirmed.redacted)
        let disclosure = narrower(found, confirmed.disclosure)
        let lifted = items.compactMap { it -> JSONValue? in
            guard let id = it["id"], let k = key(id), confirmed.redacted.contains(k), it["redact"] != .bool(true) else { return nil }
            return id
        }

        // Titles: an item Sprava knows keeps its confirmed hub title, or its confirmed absence of one.
        var titles = confirmed.sliceTitles
        var retitled: [Retitled] = []
        func heldTitle(_ k: String, found: JSONValue?, title: JSONValue?, redact: Bool) -> Bool {
            guard confirmed.known.contains(k), found != confirmed.sliceTitles[k] else { return false }
            if confirmed.sliceTitles[k] == nil { titles[k] = redact || redacted.contains(k) ? .str("[redacted]") : title ?? .null }
            return true
        }
        for it in items {
            guard let id = it["id"], let k = key(id) else { continue }
            let foundTitle = sliceTitle(it["slice_title"])
            if heldTitle(k, found: foundTitle, title: it["title"], redact: it["redact"] == .bool(true)) {
                retitled.append(Retitled(id: id, confirmed: confirmed.sliceTitles[k], found: foundTitle))
            }
        }
        // A closure publishes no title or tags in `closed[]` (binder-v0 §8.2), so a closed item never holds the binder
        // back; its hub title is held all the same, for a publisher that shows a closed item once more by its title.
        for entry in catalog["processing_log"]?.arrayValue ?? [] where ["done", "dropped"].contains(entry["action"]?.stringValue ?? "") {
            guard let k = key(entry["id"]) else { continue }
            let final = entry["final"]
            _ = heldTitle(k, found: sliceTitle(final?["slice_title"]), title: entry["title"], redact: final?["redact"] == .bool(true))
        }

        // Tags and kind of redacted items.
        var retagged: [Retagged] = []
        var unkinded: [JSONValue] = []
        var kinds: [String: JSONValue] = [:]
        for it in items {
            guard let id = it["id"], let k = key(id), confirmed.known.contains(k), redacted.contains(k) else { continue }
            let tags = it["tags"]?.arrayValue ?? []
            if !Set(tags).isSubset(of: confirmed.tags[k] ?? []) { retagged.append(Retagged(id: id, found: .array(tags))) }
            if it["kind"] == nil, let kind = confirmed.kinds[k] {
                unkinded.append(id)
                kinds[k] = kind
            }
        }
        let held = retagged.isEmpty ? disclosure : narrower(disclosure, "title")
        return View(disclosure: held, redacted: redacted, widenedTo: disclosure == found ? nil : found, lifted: lifted,
                    retitled: retitled, titles: titles, retagged: retagged, unkinded: unkinded, kinds: kinds)
    }

    /// The disclosure every cross-binder surface uses for a binder read from `folder` (a Shelf row's folder and binder).
    public static func disclosure(folder: URL, teka: Teka) -> String {
        guard let catalog = teka.catalog else { return "none" }
        return teka.isAdopted ? view(folder: folder, catalog: catalog).disclosure : level(catalog["meta"]?["disclosure"])
    }

    /// The privacy card for a loosening made outside Sprava: the person's own `set_disclosure` and `update_item`
    /// ops, which make the found values the confirmed ones once approved. A card already waiting for the same
    /// change is kept; none is made when nothing loosened. Returns the id of a card it wrote.
    public static func ensureCard(folder: URL, client: String = "sprava/0.1", now: Date = Date()) throws -> String? {
        let teka = Teka.read(folder)
        guard teka.isAdopted, let catalog = teka.catalog else { return nil }
        let v = view(folder: folder, catalog: catalog)
        func update(_ id: JSONValue, _ change: (String, JSONValue)) -> JSONObject {
            JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", id), change]))])
        }
        var ops: [JSONObject] = []
        var what: [String] = []
        if let wider = v.widenedTo {
            ops.append(JSONObject([(key: "op", value: .str("set_disclosure")), (key: "args", value: .obj([("disclosure", .string(wider))]))]))
            what.append("Disclosure was raised to \(wider)")
        }
        for id in v.lifted { ops.append(update(id, ("unset", .array([.str("redact")])))) }
        if !v.lifted.isEmpty { what.append("Redaction was removed") }
        for r in v.retitled {
            ops.append(update(r.id, r.found.map { ("set", .obj([("slice_title", $0)])) } ?? ("unset", .array([.str("slice_title")]))))
        }
        if !v.retitled.isEmpty { what.append("A hub title was added, changed or removed") }
        for r in v.retagged { ops.append(update(r.id, ("set", .obj([("tags", r.found)])))) }
        if !v.retagged.isEmpty { what.append("A tag was added to a redacted item") }
        for id in v.unkinded { ops.append(update(id, ("unset", .array([.str("kind")])))) }
        if !v.unkinded.isEmpty { what.append("The kind of a redacted item was removed") }
        guard !ops.isEmpty else { return nil }
        let waiting = ProposalStore.list(in: folder).contains { p, _ in
            p.state == "proposed" && p.raw["provenance"]?["privacy_widening"] == .bool(true) && p.ops == ops
        }
        guard !waiting else { return nil }
        let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        let title = what.joined(separator: "; ") + " outside Sprava. Allow it? Until then the hub "
            + (v.widenedTo != nil || !v.retagged.isEmpty ? "and brains see \(v.disclosure) and " : "") + "keeps what you confirmed"
        let card = Proposal.make(title: title, actor: user, ops: ops,
                                 provenance: JSONObject([(key: "privacy_widening", value: .bool(true))]), now: now)
        try ProposalStore.save(card, in: folder)
        return card.id
    }
}

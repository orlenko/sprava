import BinderFormat
import Foundation
import SpravaKit

/// The privacy ratchet (architecture 4.5 step 5; binder-v0 §5.5, §6.7): an outside edit that narrows what a binder
/// shows takes effect at once; one that widens it (`meta.disclosure` raised, `redact` cleared, `slice_title` removed
/// or changed) does not. The hub slice and MCP keep projecting with the last values the person confirmed until a
/// privacy card is approved.
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
    /// aborted ones; an `external_edit` never counts. A redaction is confirmed by any op that sets it and lifted
    /// only by the person's own op (architecture 4.5, 7.3). So is a hub title: any op may give an item one where it
    /// had none, but only the person's own op changes or removes it.
    public struct Confirmed: Equatable {
        public var disclosure: String
        /// Items whose redaction stands, by the id's canonical text.
        public var redacted: Set<String>
        /// The `slice_title` that stands for each item, by the id's canonical text.
        public var sliceTitles: [String: JSONValue] = [:]
    }

    /// A `slice_title` that counts: a truthy value, as the projection reads it.
    static func sliceTitle(_ value: JSONValue?) -> JSONValue? { value.flatMap { ItemRules.isTruthy($0) ? $0 : nil } }

    public static func confirmed(opLog ops: [JSONObject]) -> Confirmed? {
        guard let start = ops.lastIndex(where: { $0["op"] == .str("import_snapshot") }) else { return nil }
        let aborted = Set(ops.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        let snapshot = ops[start]["args"]?["catalog"]
        var c = Confirmed(disclosure: level(snapshot?["meta"]?["disclosure"]), redacted: [])
        func key(_ id: JSONValue?) -> String? { id.flatMap { try? Canonical.serialize($0) } }
        for item in snapshot?["open_items"]?.arrayValue ?? [] {
            guard let k = key(item["id"]) else { continue }
            if item["redact"] == .bool(true) { c.redacted.insert(k) }
            if let t = sliceTitle(item["slice_title"]) { c.sliceTitles[k] = t }
        }
        for op in ops.dropFirst(start + 1) where !aborted.contains(op["id"]?.stringValue ?? "") {
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
                guard let k = key(args?["item"]?["id"]) else { continue }
                if args?["item"]?["redact"] == .bool(true) { c.redacted.insert(k) }
                if let t = sliceTitle(args?["item"]?["slice_title"]) { c.sliceTitles[k] = t }
            case "update_item"?:
                guard let k = key(args?["id"]) else { continue }
                if args?["set"]?["redact"] == .bool(true) {
                    c.redacted.insert(k)
                } else if byUser, args?["set"]?["redact"] != nil
                            || args?["unset"]?.arrayValue?.contains(.str("redact")) == true {
                    c.redacted.remove(k)
                }
                let title = args?["set"]?["slice_title"]
                if byUser || c.sliceTitles[k] == nil, title != nil
                    || args?["unset"]?.arrayValue?.contains(.str("slice_title")) == true {
                    c.sliceTitles[k] = sliceTitle(title)
                }
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
        /// Open items whose `slice_title` an outside edit removed or changed, waiting for a card: the hub keeps the
        /// confirmed title until then.
        public var retitled: [Retitled] = []
        /// The confirmed hub title of every item that has one, by the id's canonical text, closed items included:
        /// the hub never sees another title for them until the person allows it.
        public var titles: [String: JSONValue] = [:]
    }

    public struct Retitled: Equatable {
        public var id: JSONValue
        /// The title the hub keeps, and the one found in the catalog (nil when removed).
        public var confirmed: JSONValue
        public var found: JSONValue?
    }

    /// The view of an adopted binder. An op log that cannot be read fails closed: disclosure `none`.
    public static func view(folder: URL, catalog: JSONObject) -> View {
        let found = level(catalog["meta"]?["disclosure"])
        let items = catalog["open_items"]?.arrayValue ?? []
        let foundRedacted = Set(items.filter { $0["redact"] == .bool(true) }.compactMap { $0["id"].flatMap { try? Canonical.serialize($0) } })
        guard let ops = try? TekaStore(folder: folder).readOpLog().ops else {
            return View(disclosure: "none", redacted: foundRedacted, widenedTo: nil, lifted: [])
        }
        guard let confirmed = confirmed(opLog: ops) else {
            return View(disclosure: found, redacted: foundRedacted, widenedTo: nil, lifted: [])
        }
        let disclosure = narrower(found, confirmed.disclosure)
        let lifted = items.compactMap { it -> JSONValue? in
            guard let id = it["id"], let k = try? Canonical.serialize(id), confirmed.redacted.contains(k), it["redact"] != .bool(true) else { return nil }
            return id
        }
        let retitled = items.compactMap { it -> Retitled? in
            guard let id = it["id"], let k = try? Canonical.serialize(id), let kept = confirmed.sliceTitles[k],
                  sliceTitle(it["slice_title"]) != kept else { return nil }
            return Retitled(id: id, confirmed: kept, found: sliceTitle(it["slice_title"]))
        }
        return View(disclosure: disclosure, redacted: foundRedacted.union(confirmed.redacted),
                    widenedTo: disclosure == found ? nil : found, lifted: lifted, retitled: retitled,
                    titles: confirmed.sliceTitles)
    }

    /// The disclosure every cross-binder surface uses for a binder read from `folder` (a Shelf row's folder and binder).
    public static func disclosure(folder: URL, teka: Teka) -> String {
        guard let catalog = teka.catalog else { return "none" }
        return teka.isAdopted ? view(folder: folder, catalog: catalog).disclosure : level(catalog["meta"]?["disclosure"])
    }

    /// The privacy card for a widening made outside Sprava: the person's own `set_disclosure` and `update_item`
    /// ops, which make the found values the confirmed ones once approved. A card already waiting for the same
    /// change is kept; none is made when nothing widened. Returns the id of a card it wrote.
    public static func ensureCard(folder: URL, client: String = "sprava/0.1", now: Date = Date()) throws -> String? {
        let teka = Teka.read(folder)
        guard teka.isAdopted, let catalog = teka.catalog else { return nil }
        let v = view(folder: folder, catalog: catalog)
        var ops: [JSONObject] = []
        if let wider = v.widenedTo {
            ops.append(JSONObject([(key: "op", value: .str("set_disclosure")), (key: "args", value: .obj([("disclosure", .string(wider))]))]))
        }
        for id in v.lifted {
            ops.append(JSONObject([(key: "op", value: .str("update_item")),
                                   (key: "args", value: .obj([("id", id), ("unset", .array([.str("redact")]))]))]))
        }
        for r in v.retitled {
            let change: (String, JSONValue) = r.found.map { ("set", .obj([("slice_title", $0)])) } ?? ("unset", .array([.str("slice_title")]))
            ops.append(JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", r.id), change]))]))
        }
        guard !ops.isEmpty else { return nil }
        let waiting = ProposalStore.list(in: folder).contains { p, _ in
            p.state == "proposed" && p.raw["provenance"]?["privacy_widening"] == .bool(true) && p.ops == ops
        }
        guard !waiting else { return nil }
        let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        let title = v.widenedTo.map { "Disclosure was raised to \($0) outside Sprava. Allow it? Until then the hub and brains see \(v.disclosure)" }
            ?? (v.lifted.isEmpty ? "A hub title was changed or removed outside Sprava. Allow it? Until then the hub keeps the one you confirmed"
                : "Redaction was removed outside Sprava. Allow it? Until then the hub keeps it redacted")
        let card = Proposal.make(title: title, actor: user, ops: ops,
                                 provenance: JSONObject([(key: "privacy_widening", value: .bool(true))]), now: now)
        try ProposalStore.save(card, in: folder)
        return card.id
    }
}

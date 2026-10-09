@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Random sequences of outside edits, approvals, closures and settling, from a fixed seed, checked after every step
/// against a model of what the person confirmed (the privacy ratchet) or approved (recovery). Invented data only.
@Suite struct RandomSequenceTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    /// SplitMix64: the same sequence on every run.
    struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        store.testHookFullSync = { _ in 0 }
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        return (folder, store)
    }

    func read(_ folder: URL) throws -> JSONObject {
        try #require(try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue)
    }

    func write(_ c: JSONObject, _ folder: URL) throws {
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
    }

    static func key(_ id: JSONValue?) -> String { id.flatMap { try? Canonical.serialize($0) } ?? "" }

    static func changing(_ c: inout JSONObject, _ id: JSONValue, _ change: (inout JSONObject) -> Void) {
        c.set("open_items", .array((c["open_items"]?.arrayValue ?? []).map { it in
            guard it["id"] == id, case .object(var o) = it else { return it }
            change(&o)
            return .object(o)
        }))
    }

    // MARK: - The privacy ratchet

    /// What the person confirmed for one item.
    struct Baseline {
        var sliceTitle: JSONValue?
        var redact: Bool
        var tags: Set<JSONValue>
    }

    static func baseline(_ it: JSONValue) -> Baseline {
        Baseline(sliceTitle: PrivacyRatchet.sliceTitle(it["slice_title"]), redact: it["redact"] == .bool(true),
                 tags: Set(it["tags"]?.arrayValue ?? []))
    }

    /// Whatever the order of outside edits, approvals, privacy cards, closures and settling, the hub never receives a
    /// hub title, a tag of a redacted item or a disclosure level the person did not confirm.
    @Test(arguments: [20_261_009, 7, 4242, 99_991] as [UInt64]) func theHubNeverReceivesAnUnconfirmedValue(_ seed: UInt64) throws {
        var rng = Seeded(state: seed)
        let (folder, store) = try adopted()
        try store.apply([.init(op: "set_disclosure", args: JSONObject([(key: "disclosure", value: .str("full"))]), actor: user)], now: now)
        var known: [String: Baseline] = [:]
        for it in try read(folder)["open_items"]?.arrayValue ?? [] { known[Self.key(it["id"])] = Self.baseline(it) }
        var pending = Set<String>()   // added outside, not yet seen by Sprava
        var disclosure = "full"
        var counter = 0

        // Sprava sees the catalog before every write: what another program added gets its baseline as found.
        func absorb() throws {
            for it in try read(folder)["open_items"]?.arrayValue ?? [] where pending.contains(Self.key(it["id"])) {
                known[Self.key(it["id"])] = Self.baseline(it)
            }
            pending.removeAll()
        }
        func confirm(_ op: JSONObject) {
            let args = op["args"]
            let k = Self.key(args?["id"])
            switch op["op"]?.stringValue {
            case "set_disclosure"?: disclosure = args?["disclosure"]?.stringValue ?? disclosure
            case "update_item"?:
                guard var b = known[k] else { return }
                let unset = args?["unset"]?.arrayValue ?? []
                if args?["set"]?["redact"] == .bool(true) { b.redact = true }
                if unset.contains(.str("redact")) { b.redact = false }
                if let t = args?["set"]?["slice_title"] { b.sliceTitle = PrivacyRatchet.sliceTitle(t) }
                if unset.contains(.str("slice_title")) { b.sliceTitle = nil }
                if let tags = args?["set"]?["tags"] { b.tags = Set(tags.arrayValue ?? []) }
                known[k] = b
            default: break
            }
        }

        for step in 0..<75 {
            var c = try read(folder)
            let items = (c["open_items"]?.arrayValue ?? []).filter { $0["recurrence"] == nil }
            let pick = items.isEmpty ? nil : items[Int.random(in: 0..<items.count, using: &rng)]
            counter += 1
            switch Int.random(in: 0..<10, using: &rng) {
            case 0:   // another program adds an item, perhaps redacted, titled or tagged
                let id = String(format: "estate-example-2026-%03d", 200 + counter)
                var o = JSONObject([(key: "id", value: .string(id)), (key: "title", value: .string("Invented outside task \(counter)")),
                                    (key: "status", value: .str("open")), (key: "priority", value: .str("normal")),
                                    (key: "no_deadline", value: .bool(true)), (key: "kind", value: .str("other")),
                                    (key: "created_at", value: .str("2026-10-06T08:00:00Z")), (key: "updated_at", value: .str("2026-10-06T08:00:00Z"))])
                if Bool.random(using: &rng) { o.set("redact", .bool(true)) }
                if Bool.random(using: &rng) { o.set("slice_title", .string("Invented hub title \(counter)")) }
                if Bool.random(using: &rng) { o.set("tags", .array([.string("tag-\(counter)")])) }
                c.set("open_items", .array((c["open_items"]?.arrayValue ?? []) + [.object(o)]))
                try write(c, folder)
                pending.insert(Self.key(.string(id)))
            case 1, 2:   // another program changes a privacy field
                let choice = Int.random(in: 0..<7, using: &rng)
                if choice == 6 {
                    var meta = c["meta"]?.objectValue ?? JSONObject()
                    meta.set("disclosure", .string(["none", "kind", "title", "full"][Int.random(in: 0..<4, using: &rng)]))
                    c.set("meta", .object(meta))
                } else if let id = pick?["id"] {
                    Self.changing(&c, id) { o in
                        switch choice {
                        case 0: o.set("slice_title", .string("Invented outside hub title \(counter)"))
                        case 1: o.remove("slice_title")
                        case 2: o.set("redact", .bool(true)); o.set("kind", .str("other"))
                        case 3: o.remove("redact")
                        case 4: o.set("tags", .array((o["tags"]?.arrayValue ?? []) + [.string("outside-tag-\(counter)")]))
                        default: o.remove("kind")
                        }
                    }
                }
                try write(c, folder)
            case 3, 4:   // the person changes a privacy field in the app
                guard let id = pick?["id"] else { continue }
                let changes: [[(String, JSONValue)]] = [
                    [("set", .obj([("redact", .bool(true)), ("kind", .str("other"))]))], [("unset", .array([.str("redact")]))],
                    [("set", .obj([("slice_title", .string("Invented approved hub title \(counter)"))]))],
                    [("unset", .array([.str("slice_title")]))], [("set", .obj([("tags", .array([.string("approved-tag-\(counter)")]))]))],
                ]
                let op = JSONObject([(key: "op", value: .str("update_item")),
                                     (key: "args", value: .obj([("id", id)] + changes[Int.random(in: 0..<changes.count, using: &rng)]))])
                try absorb()
                if (try? store.apply([.init(op: "update_item", args: op["args"]?.objectValue ?? JSONObject(), actor: user)], now: now)) != nil {
                    confirm(op)
                }
            case 5, 6:   // the person approves the privacy card
                guard let id = try PrivacyRatchet.ensureCard(folder: folder, now: now)
                        ?? ProposalStore.list(in: folder).first(where: { $0.0.state == "proposed" && $0.0.raw["provenance"]?["privacy_widening"] == .bool(true) })?.0.id
                else { continue }
                let card = try ProposalStore.load(id, in: folder, expectedDigest: nil)
                try absorb()
                if (try? store.approve(card, now: now)) != nil { card.ops.forEach(confirm) } else { try? store.reject(card, now: now) }
            case 7:   // the person closes an item
                guard let id = pick?["id"] else { continue }
                try absorb()
                if (try? store.apply([.init(op: "complete", args: JSONObject([(key: "id", value: id)]), actor: user)], now: now)) != nil {
                    known[Self.key(id)] = nil
                }
            default:
                try absorb()
                try? store.settle(now: now)
            }

            // The invariant: what the hub would receive for each open item Sprava has seen.
            let found = try read(folder)
            let v = PrivacyRatchet.view(folder: folder, catalog: found)
            let foundLevel = PrivacyRatchet.level(found["meta"]?["disclosure"])
            #expect(PrivacyRatchet.narrower(v.disclosure, disclosure) == v.disclosure, "seed \(seed) step \(step): disclosure \(v.disclosure) over \(disclosure)")
            #expect(PrivacyRatchet.narrower(v.disclosure, foundLevel) == v.disclosure, "seed \(seed) step \(step): disclosure over the catalog's")
            for it in found["open_items"]?.arrayValue ?? [] {
                let k = Self.key(it["id"])
                guard let b = known[k], !pending.contains(k) else { continue }
                let redacted = it["redact"] == .bool(true) || v.redacted.contains(k)
                let title = v.titles[k] ?? PrivacyRatchet.sliceTitle(it["slice_title"]) ?? (redacted ? .str("[redacted]") : it["title"] ?? .null)
                let allowed = b.sliceTitle ?? (it["redact"] == .bool(true) || b.redact ? .str("[redacted]") : it["title"] ?? .null)
                #expect(title == allowed, "seed \(seed) step \(step): item \(k) shows \(title), confirmed \(allowed)")
                if v.disclosure == "full", redacted {
                    let shown = Set(it["tags"]?.arrayValue ?? [])
                    #expect(shown.isSubset(of: b.tags), "seed \(seed) step \(step): item \(k) shows an unconfirmed tag")
                }
            }
        }
    }

    // MARK: - Recovery

    /// One place the sequence writes: a field of an item, of a document, or of meta.
    struct Place: Hashable {
        let kind: String
        let id: String?
        let field: String
        let optional: Bool
    }

    static let places: [Place] = [
        Place(kind: "open_items", id: "estate-example-2026-007", field: "title", optional: false),
        Place(kind: "open_items", id: "estate-example-2026-007", field: "priority", optional: false),
        Place(kind: "open_items", id: "estate-example-2026-007", field: "link", optional: true),
        Place(kind: "open_items", id: "estate-example-2026-012", field: "title", optional: false),
        Place(kind: "open_items", id: "estate-example-2026-012", field: "tags", optional: true),
        Place(kind: "documents", id: "estate-example-doc-2026-002", field: "title", optional: false),
        Place(kind: "documents", id: "estate-example-doc-2026-002", field: "date", optional: true),
        Place(kind: "meta", id: nil, field: "invented_a", optional: true),
        Place(kind: "meta", id: nil, field: "invented_b", optional: true),
    ]

    static func value(_ c: JSONObject, _ p: Place) -> JSONValue? {
        if p.kind == "meta" { return c["meta"]?[p.field] }
        return c[p.kind]?.arrayValue?.first { $0["id"] == p.id.map(JSONValue.string) }?[p.field]
    }

    static func setting(_ c: JSONObject, _ p: Place, _ value: JSONValue?) -> JSONObject {
        func change(_ o: JSONObject) -> JSONObject {
            var o = o
            if let value { o.set(p.field, value) } else { o.remove(p.field) }
            return o
        }
        var out = c
        if p.kind == "meta" {
            out.set("meta", .object(change(c["meta"]?.objectValue ?? JSONObject())))
        } else {
            out.set(p.kind, .array((c[p.kind]?.arrayValue ?? []).map { r in
                guard r["id"] == p.id.map(JSONValue.string), case .object(let o) = r else { return r }
                return .object(change(o))
            }))
        }
        return out
    }

    /// A value for a place, new on each call.
    static func fresh(_ p: Place, _ n: Int, _ tag: String) -> JSONValue {
        switch p.field {
        case "priority": return .string(["high", "normal", "low"][n % 3])
        case "date": return .string(String(format: "2026-11-%02d", 1 + n % 28))
        case "link": return .string("documents/\(tag)-\(n).pdf")
        case "tags": return .array([.string("\(tag)-\(n)")])
        default: return .string("Invented \(tag) \(n)")
        }
    }

    /// Whatever the order of approvals, unrelated outside edits and stale copies, recovery offers back exactly the
    /// approved values a copy took back, and never writes over a value of the other program's own.
    @Test(arguments: [61_092_026, 11, 2026, 31_337] as [UInt64]) func recoveryOffersBackExactlyWhatWasApproved(_ seed: UInt64) throws {
        var rng = Seeded(state: seed)
        let (folder, store) = try adopted()
        // For each place: the values it held since an outside edit last wrote it (or adoption), and whether an
        // approval wrote it last.
        var history: [Place: [JSONValue?]] = [:], approved: [Place: Bool] = [:]
        let start = try read(folder)
        for p in Self.places { history[p] = [Self.value(start, p)]; approved[p] = false }
        var copies = [start]
        var n = 0

        for step in 0..<60 {
            n += 1
            let p = Self.places[Int.random(in: 0..<Self.places.count, using: &rng)]
            switch Int.random(in: 0..<8, using: &rng) {
            case 0...3:   // an approval
                let v: JSONValue? = p.optional && Int.random(in: 0..<5, using: &rng) == 0 ? nil : Self.fresh(p, n, "approved")
                let set: [(String, JSONValue)] = v.map { [("set", .obj([(p.field, $0)]))] } ?? [("unset", .array([.string(p.field)]))]
                let body: TekaStore.OpBody
                switch p.kind {
                case "meta": body = .init(op: "set_meta", args: JSONObject(set.map { (key: $0.0, value: $0.1) }), actor: user)
                case "documents": body = .init(op: "update_document", args: JSONObject([(key: "id", value: .string(p.id!))] + set.map { (key: $0.0, value: $0.1) }), actor: user)
                default: body = .init(op: "update_item", args: JSONObject([(key: "id", value: .string(p.id!))] + set.map { (key: $0.0, value: $0.1) }), actor: user)
                }
                if (try? store.apply([body], now: now)) != nil, Self.value(try read(folder), p) == v {
                    history[p, default: []].append(v)
                    approved[p] = true
                }
            default:
                // Another program saves the catalog: an edit of one place on the current one, or a stale copy with
                // changes of its own. Both are judged by the same rule.
                let before = try read(folder)
                var stale: JSONObject
                if Int.random(in: 0..<2, using: &rng) == 0 {
                    stale = Self.setting(before, p, p.optional && Bool.random(using: &rng) ? nil : Self.fresh(p, n, "outside"))
                } else {
                    stale = copies[Int.random(in: 0..<copies.count, using: &rng)]
                    for _ in 0..<Int.random(in: 0...2, using: &rng) {
                        let q = Self.places[Int.random(in: 0..<Self.places.count, using: &rng)]
                        n += 1
                        stale = Self.setting(stale, q, q.optional && Bool.random(using: &rng) ? nil : Self.fresh(q, n, "stale"))
                    }
                }
                // The rule, place by place: an approved value taken back to an earlier one, or removed, comes back;
                // anything else stays as the copy has it.
                var want: [Place: JSONValue?] = [:]
                var lossy = false
                for q in Self.places {
                    let e = Self.value(before, q), s = Self.value(stale, q)
                    let lost = s != e && approved[q] == true && (s == nil || history[q]?.contains(s) == true)
                    want[q] = lost ? e : s
                    lossy = lossy || lost
                }
                try write(stale, folder)
                try store.settle(now: now)
                let card = ProposalStore.list(in: folder).map(\.0).first { $0.state == "proposed" && $0.raw["provenance"]?["overwritten_ops"] != nil }
                #expect((card != nil) == lossy, "seed \(seed) step \(step): a recovery card \(lossy ? "is missing" : "for nothing")")
                if let card {
                    #expect(card.raw["provenance"]?["manual_repair"] == nil, "seed \(seed) step \(step): not rebuilt")
                    try store.approve(card, now: now)
                }
                let after = try read(folder)
                for q in Self.places {
                    let got = Self.value(after, q)
                    #expect(got == want[q] ?? nil, "seed \(seed) step \(step): \(q.id ?? "meta").\(q.field) is \(String(describing: got)), want \(String(describing: want[q] ?? nil))")
                    let e = Self.value(before, q), s = Self.value(stale, q)
                    if s != e { history[q] = [s]; approved[q] = false }
                    if got != s { history[q, default: []].append(got); approved[q] = true }
                }
            }
            copies.append(try read(folder))
        }
    }
}

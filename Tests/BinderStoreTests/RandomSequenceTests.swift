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

    /// One place the sequence writes: a field of an item, of a document, or of meta; or, with an empty field,
    /// whether an item is still open (`true`) or closed (absent).
    struct Place: Hashable {
        let kind: String
        let id: String?
        let field: String
        let optional: Bool
    }

    /// Items to close, added before adoption.
    static let closable = ["estate-example-2026-101", "estate-example-2026-102", "estate-example-2026-103"]

    static let places: [Place] = [
        Place(kind: "open_items", id: "estate-example-2026-007", field: "title", optional: false),
        Place(kind: "open_items", id: "estate-example-2026-007", field: "priority", optional: false),
        Place(kind: "open_items", id: "estate-example-2026-007", field: "link", optional: true),
        Place(kind: "open_items", id: "estate-example-2026-007", field: "status", optional: false),
        Place(kind: "open_items", id: "estate-example-2026-007", field: "waiting_on", optional: true),
        Place(kind: "open_items", id: "estate-example-2026-007", field: "follow_up_at", optional: true),
        Place(kind: "open_items", id: "estate-example-2026-012", field: "title", optional: false),
        Place(kind: "open_items", id: "estate-example-2026-012", field: "tags", optional: true),
        Place(kind: "documents", id: "estate-example-doc-2026-002", field: "title", optional: false),
        Place(kind: "documents", id: "estate-example-doc-2026-002", field: "date", optional: true),
        Place(kind: "meta", id: nil, field: "invented_a", optional: true),
        Place(kind: "meta", id: nil, field: "invented_b", optional: true),
    ] + closable.map { Place(kind: "open_items", id: $0, field: "", optional: false) }

    static func value(_ c: JSONObject, _ p: Place) -> JSONValue? {
        if p.kind == "meta" { return c["meta"]?[p.field] }
        let record = c[p.kind]?.arrayValue?.first { $0["id"] == p.id.map(JSONValue.string) }
        return p.field.isEmpty ? record.map { _ in .bool(true) } : record?[p.field]
    }

    static func setting(_ c: JSONObject, _ p: Place, _ value: JSONValue?) -> JSONObject {
        guard !p.field.isEmpty else { return c }
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

    /// A value for a place, new on each call (a status is one of three).
    static func fresh(_ p: Place, _ n: Int, _ tag: String) -> JSONValue {
        switch p.field {
        case "priority": return .string(["high", "normal", "low"][n % 3])
        case "status": return .string(["open", "waiting", "blocked"][n % 3])
        case "date": return .string(String(format: "2026-11-%02d", 1 + n % 28))
        case "follow_up_at": return .string(String(format: "2026-12-%02d", 1 + n % 28))
        case "link": return .string("documents/\(tag)-\(n).pdf")
        case "tags": return .array([.string("\(tag)-\(n)")])
        default: return .string("Invented \(tag) \(n)")
        }
    }

    /// The approval the sequence makes for a place: a field set or removed, a status set with or without its
    /// waiting fields, or an open item completed or dropped.
    func approval(_ p: Place, _ n: Int, _ rng: inout Seeded) -> TekaStore.OpBody? {
        let id = JSONValue.string(p.id ?? "")
        if p.field.isEmpty {
            return .init(op: Bool.random(using: &rng) ? "complete" : "drop", args: JSONObject([(key: "id", value: id)]), actor: user)
        }
        if p.field == "status" {
            var args = JSONObject([(key: "id", value: id), (key: "status", value: Self.fresh(p, n, "approved"))])
            if Bool.random(using: &rng) {
                args.set("waiting_on", .string("Invented party \(n)"))
                args.set("follow_up_at", .string(String(format: "2026-12-%02d", 1 + n % 28)))
            }
            return .init(op: "set_status", args: args, actor: user)
        }
        let v: JSONValue? = p.optional && Int.random(in: 0..<5, using: &rng) == 0 ? nil : Self.fresh(p, n, "approved")
        let set: [(key: String, value: JSONValue)] = v.map { [(key: "set", value: .obj([(p.field, $0)]))] } ?? [(key: "unset", value: .array([.string(p.field)]))]
        switch p.kind {
        case "meta": return .init(op: "set_meta", args: JSONObject(set), actor: user)
        case "documents": return .init(op: "update_document", args: JSONObject([(key: "id", value: id)] + set), actor: user)
        default: return .init(op: "update_item", args: JSONObject([(key: "id", value: id)] + set), actor: user)
        }
    }

    /// Whatever the order of approvals (field changes, statuses, closures), unrelated outside edits and stale
    /// copies, recovery offers back exactly the approved values a copy took back, never writes over a value of the
    /// other program's own, and approving its card changes nothing outside what it puts back.
    @Test(arguments: [61_092_026, 11, 2026, 31_337] as [UInt64]) func recoveryOffersBackExactlyWhatWasApproved(_ seed: UInt64) throws {
        var rng = Seeded(state: seed)
        let folder = try makeTeka(fixture: "sprava-v0") { folder in
            let url = folder.appendingPathComponent("catalog.json")
            var c = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
            c.set("open_items", .array((c["open_items"]?.arrayValue ?? []) + Self.closable.map { id in
                .obj([("id", .string(id)), ("title", .string("Invented task to close \(id.suffix(3))")), ("status", .str("open")),
                      ("priority", .str("normal")), ("no_deadline", .bool(true)), ("kind", .str("other")),
                      ("created_at", .str("2026-10-01T08:00:00Z")), ("updated_at", .str("2026-10-01T08:00:00Z"))])
            }))
            try Data(JSONWriter.pretty(.object(c)).utf8).write(to: url)
        }
        let store = TekaStore(folder: folder)
        store.testHookFullSync = { _ in 0 }
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
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
            case 0...3:   // an approval; every place it changed was written by an approval last
                let before = try read(folder)
                guard Self.value(before, p) != nil || !p.field.isEmpty, let body = approval(p, n, &rng),
                      (try? store.apply([body], now: now)) != nil else { break }
                let after = try read(folder)
                for q in Self.places where Self.value(before, q) != Self.value(after, q) {
                    history[q, default: []].append(Self.value(after, q))
                    approved[q] = true
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
                var lost = Set<Place>()
                for q in Self.places {
                    let e = Self.value(before, q), s = Self.value(stale, q)
                    if s != e && approved[q] == true && (s == nil || history[q]?.contains(s) == true) { lost.insert(q) }
                    want[q] = lost.contains(q) ? e : s
                }
                try write(stale, folder)
                try store.settle(now: now)
                let found = try read(folder)
                let card = ProposalStore.list(in: folder).map(\.0).first { $0.state == "proposed" && $0.raw["provenance"]?["overwritten_ops"] != nil }
                #expect((card != nil) == !lost.isEmpty, "seed \(seed) step \(step): a recovery card \(lost.isEmpty ? "for nothing" : "is missing")")
                if let card, card.raw["provenance"]?["manual_repair"] == .bool(true) {
                    // Asked for a repair by hand only when putting the approved values back would leave a record
                    // breaking the rules, which the guard would refuse. Nothing is then put back.
                    var wanted = found
                    for q in lost { wanted = Self.setting(wanted, q, Self.value(before, q)) }
                    let broken = TransactionGuard.violations(wanted).contains { v in
                        lost.contains { $0.id.map { canonicalText(.string($0)) } == v.recordKey && $0.kind == v.array }
                    }
                    #expect(broken, "seed \(seed) step \(step): asked for a repair by hand with nothing in the way")
                    try store.reject(card, now: now)
                    for q in lost { want[q] = Self.value(stale, q) }
                    lost.removeAll()
                } else if let card {
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
                // Approving the card changed nothing but what it put back: a closure made again takes its item and
                // writes its log entry; every other place stays as the copy had it, byte for byte.
                let reclosed = Set(lost.filter { $0.field.isEmpty }.compactMap(\.id))
                let was = TekaStore.cells(found), then = TekaStore.cells(after)
                for cell in Set(was.keys).union(then.keys) where was[cell] != then[cell] {
                    let id = cell.id?.stringValue
                    let repaired = lost.contains(Place(kind: cell.kind, id: id, field: cell.field, optional: true))
                        || lost.contains(Place(kind: cell.kind, id: id, field: cell.field, optional: false))
                        || (cell.kind == "open_items" && id.map(reclosed.contains) == true)
                        || (cell.kind == "processing_log" && was[cell] == nil && !reclosed.isEmpty)
                    #expect(repaired, "seed \(seed) step \(step): \(cell.kind) \(id ?? "") \(cell.field) changed outside the repair")
                }
            }
            copies.append(try read(folder))
        }
    }

    // MARK: - Writes stay readable

    /// A random JSON value for a setting: plain values, integers at and past the I-JSON range, nested objects,
    /// and now and then a member name twice. Says whether it is unsafe.
    func randomSetting(_ rng: inout Seeded, depth: Int = 0) -> (JSONValue, unsafe: Bool) {
        switch Int.random(in: 0..<(depth < 2 ? 6 : 4), using: &rng) {
        case 0: return (.string("Invented \(Int.random(in: 0..<1000, using: &rng))"), false)
        case 1:
            let numbers: [(String, Bool)] = [("9007199254740991", false), ("-9007199254740991", false), ("9007199254740993", true),
                                              ("-9007199254740993", true), ("19.99", false), ("1e400", true), ("42", false)]
            let (text, unsafe) = numbers[Int.random(in: 0..<numbers.count, using: &rng)]
            return (.number(JSONNumber(text: text)), unsafe)
        case 2: return (.bool(Bool.random(using: &rng)), false)
        case 3: return (.null, false)
        case 4:
            var entries: [(key: String, value: JSONValue)] = []
            var unsafe = false
            for i in 0..<Int.random(in: 1...3, using: &rng) {
                let (v, u) = randomSetting(&rng, depth: depth + 1)
                entries.append((key: "k\(i)", value: v))
                unsafe = unsafe || u
            }
            if Int.random(in: 0..<4, using: &rng) == 0 {
                entries.append((key: "k0", value: .str("twice")))
                unsafe = true
            }
            return (.object(JSONObject(entries)), unsafe)
        default:
            let (v, u) = randomSetting(&rng, depth: depth + 1)
            return (.array([v, .str("Invented")]), u)
        }
    }

    /// Whatever settings are asked for, applied directly or approved on a card, every catalog and op line the store
    /// writes reads back as written, never needing attention; an unsafe one is refused with nothing written.
    @Test(arguments: [5, 77, 1_234] as [UInt64]) func everyWriteReadsBack(_ seed: UInt64) throws {
        var rng = Seeded(state: seed)
        let (folder, store) = try adopted()
        let catalogURL = folder.appendingPathComponent("catalog.json"), logURL = folder.appendingPathComponent(".sprava/ops.ndjson")
        for step in 0..<30 {
            let (value, unsafe) = randomSetting(&rng)
            let args = JSONObject([(key: "set", value: .obj([("invented_\(step)", value)]))])
            let before = (try Data(contentsOf: catalogURL), try Data(contentsOf: logURL))
            var applied = true
            if Bool.random(using: &rng) {
                do { try store.apply([.init(op: "set_meta", args: args, actor: user)], now: now) } catch { applied = false }
            } else {
                let card = Proposal.make(title: "Invented card", actor: user,
                                         ops: [JSONObject([(key: "op", value: .str("set_meta")), (key: "args", value: .object(args))])], now: now)
                do { try store.approve(card, now: now) } catch { applied = false }
            }
            #expect(applied == !unsafe, "seed \(seed) step \(step): \(unsafe ? "an unsafe value was written" : "a safe value was refused")")
            if !applied {
                #expect(try Data(contentsOf: catalogURL) == before.0 && Data(contentsOf: logURL) == before.1, "seed \(seed) step \(step): written anyway")
            }
            let teka = Teka.read(folder)
            #expect(teka.safety.isSafe && !teka.writesBlocked, "seed \(seed) step \(step): \(teka.reasons)")
            #expect((try? store.readCatalog()) != nil && (try? store.readOpLog()) != nil, "seed \(seed) step \(step): unreadable")
        }
    }
}

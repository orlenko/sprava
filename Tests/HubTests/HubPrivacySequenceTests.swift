import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
@testable import Hub
import SpravaKit
import SpravaTestSupport
import Testing

/// Regression tests for the calibrated review of the hub layer, and random sequences of outside edits, approvals,
/// closures and publishes checked against one invariant: the slice on the spool never shows more than what the
/// person confirmed for the current catalog. Every value is invented.
@Suite(.serialized) struct HubPrivacySequenceTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    let user = JSONObject([(key: "kind", value: .str("user"))])

    func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-hub-seq-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func item(_ n: Int, redact: Bool = false) -> String {
        #"{"id":"a-\#(n)","title":"Invented task \#(n)","status":"open","priority":"normal","due":"2026-11-0\#(n)","#
            + #""tags":["invented-tag-\#(n)"],"waiting_on":"Invented Party \#(n)","link":"docs/invented-file-\#(n).pdf""#
            + (redact ? #","redact":true}"# : "}")
    }

    func cat(_ f: URL) throws -> JSONObject {
        try JSONParser.parse(try Data(contentsOf: f.appendingPathComponent("catalog.json"))).value.objectValue!
    }

    func write(_ c: JSONObject, _ f: URL) throws {
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: f.appendingPathComponent("catalog.json"))
    }

    /// An adopted binder `tax` with `count` open items (those in `redacted` redacted at adoption), published once to a
    /// spool with an inbox and an outbox unless `publish` is false.
    func adoptedTax(_ root: URL, count: Int = 3, redacted: Set<Int> = [], publish: Bool = true) throws -> (URL, URL) {
        let f = root.appendingPathComponent("tax", isDirectory: true)
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let items = (1...count).map { item($0, redact: redacted.contains($0)) }.joined(separator: ",")
        let text = #"{"meta":{"schema_version":2,"name":"tax"},"documents":[],"open_items":[\#(items)],"processing_log":[]}"#
        try Data(text.utf8).write(to: f.appendingPathComponent("catalog.json"))
        try TekaStore(folder: f).adopt(survey: JSONObject(), owner: JSONObject(), now: now)
        let s = root.appendingPathComponent("spool")
        for sub in ["inbox", "outbox"] {
            try FileManager.default.createDirectory(at: s.appendingPathComponent(sub), withIntermediateDirectories: true)
            chmod(s.appendingPathComponent(sub).path, 0o700)
        }
        chmod(s.path, 0o700)
        guard publish else { return (f, s) }
        guard case .published = try HubLane.publish(f, root: s, now: now) else { throw TekaStore.Refused(reason: "first publish failed") }
        return (f, s)
    }

    /// Edits one open item outside Sprava.
    func editOutside(_ f: URL, _ id: String, _ change: (inout JSONObject) -> Void) throws {
        var c = try cat(f)
        let items = (c["open_items"]?.arrayValue ?? []).map { v -> JSONValue in
            guard var o = v.objectValue, o["id"] == .string(id) else { return v }
            change(&o)
            return .object(o)
        }
        c.set("open_items", .array(items))
        try write(c, f)
    }

    func sliceURL(_ s: URL) -> URL { s.appendingPathComponent("inbox/tax.agenda.json") }

    func slice(_ s: URL) throws -> JSONValue { try JSONParser.parse(try Data(contentsOf: sliceURL(s))).value }

    func userOp(_ f: URL, _ op: String, _ args: JSONObject) throws {
        try TekaStore(folder: f).apply([.init(op: op, args: args, actor: user)], now: now)
    }

    func args(_ pairs: (String, JSONValue)...) -> JSONObject { JSONObject(pairs.map { (key: $0.0, value: $0.1) }) }

    // MUST-FIX 1. A publish whose slice is unchanged still keeps the cursors: the person's lift it read is consumed,
    // so a redaction an outside edit restored afterwards is not lifted by that old approval when it is removed again.
    @Test func anUnchangedPublishConsumesTheLiftItRead() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try editOutside(f, "a-1") { $0.set("redact", .bool(true)) }
        guard case .published = try HubLane.publish(f, root: s, now: now) else { Issue.record("publish failed"); return }
        try userOp(f, "update_item", args(("id", .str("a-1")), ("unset", .array([.str("redact")]))))
        try editOutside(f, "a-1") { $0.set("redact", .bool(true)) }
        #expect(try HubLane.publish(f, root: s, now: now) == .unchanged)
        try editOutside(f, "a-1") { $0.remove("redact") }
        _ = try HubLane.publish(f, root: s, now: now)
        let first = try slice(s)["items"]?.arrayValue?.first
        #expect(first?["title"] == .str("[redacted]"))
        #expect(first?["waiting_on"] == .str("[party]") && first?["link"] == .null)
        #expect(first?["id"] != .str("tax-a-1"))
    }

    // MUST-FIX 2. A publish refused by a broken item withdraws the slice when the slice shows more than the binder
    // now allows (here an item redacted outside); one that shows nothing more stays.
    @Test func aRefusedPublishWithdrawsASliceThatShowsMore() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        try editOutside(f, "a-2") { $0.set("priority", .str("invented-bad")) }
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(f, root: s, now: now, force: true) }
        #expect(FileManager.default.fileExists(atPath: sliceURL(s).path))

        try editOutside(f, "a-1") { $0.set("redact", .bool(true)) }
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(f, root: s, now: now, force: true) }
        #expect(!FileManager.default.fileExists(atPath: sliceURL(s).path))

        try editOutside(f, "a-2") { $0.set("priority", .str("normal")) }
        guard case .published = try HubLane.publish(f, root: s, now: now) else { Issue.record("publish failed"); return }
        #expect(try slice(s)["items"]?.arrayValue?.first?["title"] == .str("[redacted]"))
    }

    // ISSUE 3. A completions value that is not a list fails the drain and stays, instead of reading as empty.
    @Test func aCompletionsObjectFailsTheDrain() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let outbox = s.appendingPathComponent("outbox/tax.intake.json")
        let body = Data(#"{"completions":{"id":"tax-a-1","action":"done"}}"#.utf8)
        try body.write(to: outbox)
        #expect(throws: TekaStore.Refused.self) { try HubLane.drain(f, root: s, now: now) }
        #expect(try Data(contentsOf: outbox) == body)
        #expect(try cat(f)["open_items"]?.arrayValue?.count == 3)
    }

    // ISSUE 4. The recommended id form uses the prefix IDMint mints with for the binder's name, not the name itself.
    @Test func theRecommendedFormUsesTheMintPrefix() throws {
        #expect(HubLane.isRecommended(.str("tax-2026-001"), teka: "Tax"))
        #expect(!HubLane.isRecommended(.str("Tax-2026-001"), teka: "Tax"))
        let key = SymmetricKey(data: Data(repeating: 7, count: 32))
        #expect(HubLane.sliceID(.str("tax-2026-001"), redacted: true, teka: "Tax", key: key) == "Tax-tax-2026-001")
    }

    // Round 2, MUST-FIX 2. A lock that cannot be taken (a folder in its place) still withdraws a slice that shows
    // more than the binder allows now, such as an item redacted since; with nothing narrowed the slice stays and the
    // publish fails.
    @Test func aDamagedLockWithdrawsAnItemRedactedSince() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let lock = f.appendingPathComponent(".teka.lock")
        try? FileManager.default.removeItem(at: lock)
        try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try HubLane.publish(f, root: s, now: now, force: true) }
        #expect(FileManager.default.fileExists(atPath: sliceURL(s).path))
        try editOutside(f, "a-1") { $0.set("redact", .bool(true)) }
        #expect(throws: TekaStore.Refused.self) { try HubLane.publish(f, root: s, now: now, force: true) }
        #expect(!FileManager.default.fileExists(atPath: sliceURL(s).path))
    }

    // Round 2, MUST-FIX 2, the busy lock kept apart: another program's lock may be a publish that read the wider
    // state, so an item redacted since is withdrawn only once the lock is free, and the publish says so meanwhile.
    @Test func aBusyLockWithdrawsAnItemRedactedSinceOnceFree() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let fd = open(f.appendingPathComponent(".teka.lock").path, O_RDWR | O_CREAT, 0o600)
        #expect(fd >= 0 && flock(fd, LOCK_EX) == 0)
        func publish() throws -> HubLane.PublishResult {
            try HubLane.publish(f, root: s, now: now, force: true, nameCollides: false, lockTimeout: 0.2)
        }
        #expect(throws: TekaStore.Busy.self) { try publish() }
        try editOutside(f, "a-1") { $0.set("redact", .bool(true)) }
        #expect(throws: TekaStore.Refused.self) { try publish() }
        #expect(FileManager.default.fileExists(atPath: sliceURL(s).path))
        flock(fd, LOCK_UN)
        close(fd)
        _ = try publish()
        #expect(try slice(s)["items"]?.arrayValue?.first?["title"] == .str("[redacted]"))
    }

    // Round 2, ISSUE 3. A completion whose `at` or `source` is not a string is applied with them normalized, and
    // the values it had are kept in the op's note (binder-v0 §8.3).
    @Test func aNormalizedCompletionKeepsItsValuesInTheNote() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root)
        let outbox = s.appendingPathComponent("outbox/tax.intake.json")
        try Data(#"{"completions":[{"id":"tax-a-1","action":"done","at":1791360000,"source":{"app":"invented"}}]}"#.utf8).write(to: outbox)
        #expect(try HubLane.drain(f, root: s, now: now).applied == 1)
        let op = try TekaStore(folder: f).readOpLog().ops.last { $0["op"] == .str("complete") }
        #expect(op?["args"]?["closed_at"] == .null && op?["args"]?["source"] == .str("osavul"))
        let note = op?["note"]?.stringValue ?? ""
        #expect(note.contains("at was 1791360000") && note.contains(#"source was {"app":"invented"}"#))
        #expect(!FileManager.default.fileExists(atPath: outbox.path))
    }

    // Round 2, MUST-FIX 1. Before a binder's first publication the hub has seen none of its tags; a tag an outside
    // edit gave a redacted item then is still held until the person allows it, whether a write of Sprava's recorded
    // the outside edit or not. The baseline is the privacy ratchet's (adoption, or an op), never "nothing seen yet".
    @Test(arguments: [false, true])
    func anOutsideTagBeforeTheFirstPublicationIsHeld(recorded: Bool) throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root, count: 2, redacted: [1], publish: false)
        try editOutside(f, "a-1") { $0.set("tags", .array([.str("invented-tag-1"), .str("invented-outside-tag")])) }
        if recorded { try userOp(f, "update_item", args(("id", .str("a-2")), ("set", .obj([("priority", .str("high"))])))) }
        _ = try? HubLane.publish(f, root: s, now: now)
        if FileManager.default.fileExists(atPath: sliceURL(s).path) {
            #expect(!String(decoding: try Data(contentsOf: sliceURL(s)), as: UTF8.self).contains("invented-outside-tag"))
        }

        // Once the person allows it, the tag is published.
        let id = try #require(try PrivacyRatchet.ensureCard(folder: f, now: now))
        let card = try ProposalStore.load(id, in: f, expectedDigest: nil)
        try TekaStore(folder: f).approve(card, now: now)
        guard case .published = try HubLane.publish(f, root: s, now: now) else { Issue.record("publish failed"); return }
        let redacted = try slice(s)["items"]?.arrayValue?.first { $0["title"] == .str("[redacted]") }
        #expect(redacted?["tags"] == .array([.str("invented-tag-1"), .str("invented-outside-tag")]))
    }

    // An item an outside edit added, which no write of Sprava's has recorded yet, has no baseline in the ratchet: the
    // tags the hub saw for it still limit it once an outside edit redacts it and adds one.
    @Test func anUnrecordedItemKeepsTheTagsTheHubSaw() throws {
        let root = try scratch()
        let (f, s) = try adoptedTax(root, count: 2)
        var c = try cat(f)
        c.set("open_items", .array((c["open_items"]?.arrayValue ?? []) + [try JSONParser.parse(Data(item(3).utf8)).value]))
        try write(c, f)
        guard case .published = try HubLane.publish(f, root: s, now: now) else { Issue.record("publish failed"); return }
        try editOutside(f, "a-3") {
            $0.set("redact", .bool(true))
            $0.set("tags", .array([.str("invented-tag-3"), .str("invented-late-tag")]))
        }
        guard case .published = try HubLane.publish(f, root: s, now: now) else { Issue.record("publish failed"); return }
        let redacted = try slice(s)["items"]?.arrayValue?.first { $0["title"] == .str("[redacted]") }
        #expect(redacted?["tags"] == .array([.str("invented-tag-3")]))
    }

    // MARK: - Random sequences

    struct SplitMix: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// What the person confirmed, kept apart from the code under test. A redaction stands once Sprava's op set it or
    /// a publish showed it, until the person's own op lifts it; a hub title is the one the person's op set; a tag
    /// stands once it was confirmed at adoption, set by the person, or shown by a publish; the disclosure is the one
    /// the person set.
    struct Model {
        var redacted: [String: Bool] = [:]
        var titles: [String: JSONValue] = [:]
        var tags: [String: Set<JSONValue>] = [:]
        var disclosure = "full"

        mutating func apply(_ op: JSONObject) {
            let a = op["args"]
            switch op["op"]?.stringValue {
            case "set_disclosure"?:
                disclosure = PrivacyRatchet.level(a?["disclosure"])
            case "update_item"?:
                guard let k = a?["id"]?.stringValue else { return }
                let unset = a?["unset"]?.arrayValue ?? []
                if a?["set"]?["redact"] == .bool(true) { redacted[k] = true }
                if unset.contains(.str("redact")) || a?["set"]?["redact"] == .bool(false) { redacted[k] = false }
                if let t = a?["set"]?["slice_title"] { titles[k] = t }
                if unset.contains(.str("slice_title")) { titles[k] = nil }
                if let t = a?["set"]?["tags"]?.arrayValue { tags[k, default: []].formUnion(t) }
            default:
                break
            }
        }
    }

    /// Checks the invariant; returns what broke it, nil when it holds.
    func violation(_ f: URL, _ s: URL, _ m: Model) throws -> String? {
        let c = try cat(f)
        let found = PrivacyRatchet.level(c["meta"]?["disclosure"])
        let exists = FileManager.default.fileExists(atPath: sliceURL(s).path)
        if PrivacyRatchet.narrower(found, m.disclosure) != "full" { return exists ? "a slice below disclosure full" : nil }
        guard exists else { return nil }
        guard let key = try HubLane.existingSliceKey(f) else { return "no slice key" }
        let open = (c["open_items"]?.arrayValue ?? []).compactMap(\.objectValue)
        for shown in try slice(s)["items"]?.arrayValue ?? [] {
            if shown["status"] == .str("done") {
                guard shown["title"] == .str("[closed]"), shown["tags"] == .array([]), shown["waiting_on"] == .null,
                      shown["link"] == .null else { return "a closure shows more than its id: \(shown)" }
                continue
            }
            let sid = shown["id"]?.stringValue ?? ""
            guard let it = open.first(where: { o in
                let k = o["id"]?.stringValue ?? ""
                return sid == "tax-\(k)" || sid == HubLane.alias(.string(k), teka: "tax", key: key)
            }) else { return "an item that is not open: \(sid)" }
            let k = it["id"]?.stringValue ?? ""
            let red = it["redact"] == .bool(true) || m.redacted[k] == true
            if red && sid == "tax-\(k)" { return "the raw id of redacted \(k)" }
            var titles: [JSONValue?] = [.str("[redacted]"), m.titles[k]]
            if !red { titles += [it["title"], it["slice_title"]] }
            if !titles.contains(shown["title"]) { return "title of \(k): \(String(describing: shown["title"]))" }
            if ![.str("[party]"), .null].contains(shown["waiting_on"]), red || shown["waiting_on"] != it["waiting_on"] {
                return "party of \(k)"
            }
            if shown["link"] != .null, red || shown["link"] != it["link"] { return "link of \(k)" }
            let foundTags = Set(it["tags"]?.arrayValue ?? [])
            for tag in shown["tags"]?.arrayValue ?? [] where !foundTags.contains(tag) || (red && !(m.tags[k] ?? []).contains(tag)) {
                return "tag \(tag) of \(k)"
            }
        }
        return nil
    }

    /// `outsideFirst`: items redacted at adoption at random, and outside edits the hub never saw (a tag added, a
    /// redaction) before the first publication, which is checked like any other.
    func run(seed: UInt64, steps: Int, outsideFirst: Bool = false) throws {
        var rng = SplitMix(state: seed)
        let root = try scratch()
        let redactedAtAdoption = outsideFirst ? Set((1...2).filter { _ in Bool.random(using: &rng) }) : []
        let (f, s) = try adoptedTax(root, count: 2, redacted: redactedAtAdoption, publish: !outsideFirst)
        var m = Model()
        for n in 1...2 { m.tags["a-\(n)"] = [.str("invented-tag-\(n)")] }
        for n in redactedAtAdoption { m.redacted["a-\(n)"] = true }
        var openIDs = ["a-1", "a-2"]
        var trail: [String] = ["adopted, redacted \(redactedAtAdoption.sorted())"]

        func observe() throws {
            // A publish that worked: what it showed redacted stands, and the hub saw its tags.
            let c = try cat(f)
            for it in (c["open_items"]?.arrayValue ?? []).compactMap(\.objectValue) where it["redact"] == .bool(true) {
                if let k = it["id"]?.stringValue { m.redacted[k] = true }
            }
            guard FileManager.default.fileExists(atPath: sliceURL(s).path), let key = try HubLane.existingSliceKey(f) else { return }
            for shown in try slice(s)["items"]?.arrayValue ?? [] {
                for k in openIDs where shown["id"] == .string("tax-\(k)") || shown["id"] == .string(HubLane.alias(.string(k), teka: "tax", key: key)) {
                    m.tags[k, default: []].formUnion(shown["tags"]?.arrayValue ?? [])
                }
            }
        }

        /// Publishes and checks the invariant; false when it broke.
        func publishAndCheck(_ step: Int) throws -> Bool {
            let result = try? HubLane.publish(f, root: s, now: now)
            trail.append("publish -> \(result.map { "\($0)" } ?? "failed")")
            if let why = try violation(f, s, m) {
                Issue.record("seed \(seed), step \(step): \(why)\n\(trail.joined(separator: "\n"))")
                return false
            }
            switch result {
            case .published?, .unchanged?: try observe()
            default: break
            }
            return true
        }

        if outsideFirst {
            for k in openIDs {
                if Bool.random(using: &rng) {
                    trail.append("before the first publication: outside tag \(k)")
                    try editOutside(f, k) {
                        let tags = ($0["tags"]?.arrayValue ?? []) + [.str("invented-early-tag")]
                        $0.set("tags", .array(tags))
                    }
                }
                if Bool.random(using: &rng) {
                    trail.append("before the first publication: outside redact \(k)")
                    try editOutside(f, k) { $0.set("redact", .bool(true)) }
                }
            }
            guard try publishAndCheck(-1) else { return }
        }

        for step in 0..<steps {
            let k = openIDs[Int.random(in: 0..<openIDs.count, using: &rng)]
            let n = step
            // Steps by weight: redaction and its lift, the review's scenarios, and publishing come up most.
            let weights = [3, 1, 1, 1, 1, 3, 1, 1, 1, 4]
            var pick = Int.random(in: 0..<weights.reduce(0, +), using: &rng)
            let kind = weights.firstIndex { w in pick -= w; return pick < 0 }!
            switch kind {
            case 0:
                let on = Bool.random(using: &rng)
                trail.append("outside redact \(k) \(on)")
                try editOutside(f, k) { if on { $0.set("redact", .bool(true)) } else { $0.remove("redact") } }
            case 1:
                let on = Bool.random(using: &rng)
                trail.append("outside slice_title \(k) \(on)")
                try editOutside(f, k) { if on { $0.set("slice_title", .string("Invented outside title \(n)")) } else { $0.remove("slice_title") } }
            case 2:
                let add = Bool.random(using: &rng)
                trail.append("outside tags \(k) \(add)")
                try editOutside(f, k) {
                    var tags = $0["tags"]?.arrayValue ?? []
                    if add { tags.append(.string("invented-outside-tag-\(n)")) } else if !tags.isEmpty { tags.removeLast() }
                    $0.set("tags", .array(tags))
                }
            case 3:
                let on = Bool.random(using: &rng)
                trail.append("outside kind \(k) \(on)")
                try editOutside(f, k) { if on { $0.set("kind", .str("payment")) } else { $0.remove("kind") } }
            case 4:
                let level = [nil, "full", "title", "kind", "none"][Int.random(in: 0..<5, using: &rng)]
                trail.append("outside disclosure \(level ?? "absent")")
                var c = try cat(f)
                var meta = c["meta"]?.objectValue ?? JSONObject()
                if let level { meta.set("disclosure", .string(level)) } else { meta.remove("disclosure") }
                c.set("meta", .object(meta))
                try write(c, f)
            case 5:
                let choices: [(String, JSONObject)] = [
                    ("update_item", args(("id", .string(k)), ("unset", .array([.str("redact")])))),
                    ("update_item", args(("id", .string(k)), ("set", .obj([("redact", .bool(true)), ("kind", .str("payment"))])))),
                    ("update_item", args(("id", .string(k)), ("set", .obj([("slice_title", .string("Invented hub title \(n)"))])))),
                    ("update_item", args(("id", .string(k)), ("unset", .array([.str("slice_title")])))),
                    ("update_item", args(("id", .string(k)), ("set", .obj([("tags", .array([.string("invented-person-tag-\(n)")]))])))),
                    ("set_disclosure", args(("disclosure", .str(["full", "title", "none"][n % 3])))),
                ]
                // The person's lift of a redaction half of the time, else any change.
                let (op, a) = choices[Bool.random(using: &rng) ? 0 : Int.random(in: 0..<choices.count, using: &rng)]
                trail.append("person \(op) \(a)")
                if (try? userOp(f, op, a)) != nil { m.apply(JSONObject([(key: "op", value: .string(op)), (key: "args", value: .object(a))])) }
            case 6:
                trail.append("approve privacy card")
                if let id = try? PrivacyRatchet.ensureCard(folder: f, now: now), let card = try? ProposalStore.load(id, in: f, expectedDigest: nil),
                   (try? TekaStore(folder: f).approve(card, now: now)) != nil {
                    for op in card.ops { m.apply(op) }
                }
            case 7:
                let broken = Bool.random(using: &rng)
                trail.append("outside priority \(k) broken \(broken)")
                try editOutside(f, k) { $0.set("priority", .str(broken ? "invented-bad" : "normal")) }
            case 8:
                guard openIDs.count > 1 else { continue }
                trail.append("person closes \(k)")
                if (try? userOp(f, "complete", args(("id", .string(k)), ("closed_at", .str("2026-10-07T10:00:00Z")),
                                                   ("source", .str("user"))))) != nil {
                    openIDs.removeAll { $0 == k }
                }
            default:
                guard try publishAndCheck(step) else { return }
            }
        }
    }

    // Fixed seeds: 35 reaches the unchanged publish of finding 1; 1, 2 and 10 reach refused publishes of finding 2
    // (a redacted id, a title, a tag). Each was checked to fail without its fix.
    @Test(arguments: [UInt64(35), 1, 2, 10])
    func randomSequencesNeverShowMoreThanConfirmed(seed: UInt64) throws {
        try run(seed: seed, steps: 80)
    }

    // Round 2, MUST-FIX 1: sequences that start with outside edits the hub never saw, before the first publication.
    @Test(arguments: [UInt64(3), 4, 5, 6, 7, 8, 9, 11])
    func randomSequencesFromOutsideEditsBeforeTheFirstPublication(seed: UInt64) throws {
        try run(seed: seed, steps: 80, outsideFirst: true)
    }
}

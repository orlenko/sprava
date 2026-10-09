import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Random sequences of what can happen to the inbox, from fixed seeds: captures (private or not, empty or not) whose
/// lines belong in two binders, revisions that change some lines and keep the rest, retractions, copies from a second
/// device, crashes at a random cursor save, the clerk's hand-off (items added in either binder, completions and
/// date-only updates of existing items), the person approving (through the approval gate), rejecting, filing or
/// discarding cards, each binder going out of reach and coming back, and sweeps. Three things hold:
/// 1. after every step, every line of each chain's current revision is accounted for, across both binders (read where
///    they are, in reach or not) and the Inbox: on a waiting card, listed as not filed yet, in a binder, or declined by
///    the person; and every change a waiting card ever asked for from a line still in the current words (a
///    completion, a date, a priority) is still asked for, done, declined, or in front of the person as the line;
/// 2. after every clean sweep with both binders in reach, nothing from a chain ever marked private is unredacted in a
///    binder (or lacks a waiting redaction), and no waiting card adds it unredacted; and at every approval nothing on
///    the card the gate lets through is in the clear;
/// 3. after every clean sweep with both binders in reach, no card waits from a revision that is not the chain's
///    current words, unless it only narrows privacy (or is a retraction's removal card). Invented data only.
@Suite(.serialized) struct InboxSequenceTests {
    let devices = ["aaaaaaaa-2222-4333-8444-5555555555e1", "bbbbbbbb-2222-4333-8444-5555555555e2"]
    let unregistered = "00000000-2222-4333-8444-5555555555e0"
    static let descriptions = ["Roof work with the invented roofer", "Garden, notary and permit work with the invented gardener"]

    struct Rng {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ n: Int) -> Int { Int(next() % UInt64(n)) }
        mutating func chance(_ percent: Int) -> Bool { below(100) < percent }
        mutating func pick<T>(_ a: [T]) -> T { a[below(a.count)] }
    }

    struct Event {
        let chain: Int
        let revision: String
        let text: String
        let retracted: Bool
        let device: String
        let wall: Int
        let counter: Int
    }

    /// An event's stamp, as its clock orders it.
    struct Stamp: Comparable {
        let wall: Int
        let counter: Int
        static func < (a: Stamp, b: Stamp) -> Bool { (a.wall, a.counter) < (b.wall, b.counter) }
    }

    /// A change a waiting card asked for from a line of a chain: the line's words and what the op does.
    struct Asked: Hashable {
        let chain: Int
        let line: String
        let what: String
    }

    final class Model {
        var events: [String: Event] = [:]
        var chains: [[String]] = []        // chain -> its revisions' ids in the order written (copies not included)
        var copies: [Int: [String]] = [:]  // chain -> ids of copies
        var privateChains = Set<Int>()
        var declined = Set<String>()       // lines on cards the person rejected or discarded
        var declinedAt: [String: Stamp] = [:]   // each such line, with the newest stamp of the words it was declined from
        var asked: [Asked: Set<String>] = [:]   // changes waiting cards asked for, with the events they were read from
        var log: [String] = []
        var seed: UInt64 = 0
        var written = 0
        var binders: [URL] = []            // the first binder (roof work) and the second (garden, notary, permits)
        var away = [false, false]
        var unwritable = false             // the first binder's cards
        var unreadable: URL?      // a card file made unreadable for a while
        var pseudo = Set<Int>()   // "chains" that are one event from an unregistered folder, never revised
        var raisers: [Int: Set<String>] = [:]   // chain -> private events from unregistered folders that raised it
        var privateEvents = Set<String>()

        func current(_ chain: Int) -> Event { events[chains[chain].last!]! }
        func ids(_ chain: Int) -> Set<String> { Set(chains[chain] + (copies[chain] ?? [])) }
        var anyAway: Bool { away.contains(true) }
    }

    /// The model the clerk asks: every line of the note is an item; a binder by the line's words; a "paid" line
    /// completes the second binder's notary fee it names, a "move" line moves its permit's date.
    final class SeqModel: ClerkModel, @unchecked Sendable {
        let name = "sequence"
        let contextSize = 4096
        let items: JSONValue
        let targets: [String: (String, String)]   // line -> (item id, relation)
        let names: [String]
        init(text: String, targets: [String: (String, String)], names: [String]) {
            items = .obj([("items", .array(CaptureInbox.lines(of: text).map { line in
                item(line.text, line.text, when: line.text.hasSuffix("to November 20") ? "November 20" : "")
            }))])
            self.targets = targets
            self.names = names
        }
        func tokens(instructions: String, prompt: String, task: ClerkTask) async -> Int? { 100 }
        func respond(instructions: String, prompt: String, task: ClerkTask, maxTokens: Int) async throws -> JSONValue {
            switch task {
            case .extraction:
                return items
            case .binder(let options):
                let sentence = prompt.split(separator: "\n").first.map(String.init) ?? ""
                let name = sentence.contains("roofer") ? names[0] : names[1]
                return .obj([("binder", .string(options.contains(name) ? name : "not-sure"))])
            case .duplicate(let ids):
                let sentence = prompt.split(separator: "\n").first { $0.hasPrefix("Its sentence: ") }.map { String($0.dropFirst(14)) } ?? ""
                guard let (id, relation) = targets[sentence], ids.contains(id) else { return .obj([("candidate", .str("none")), ("relation", .str("related"))]) }
                return .obj([("candidate", .string(id)), ("relation", .string(relation))])
            case .document:
                return .obj([("class", .str("unsure"))])
            }
        }
    }

    /// Line `n` of chain `chain`: an item for the first binder, one for the second, a completion of one of the second
    /// binder's notary fees, or a new date for one of its permits.
    func line(_ chain: Int, _ n: Int) -> String {
        let k = (chain + n) % 6 + 1
        switch n % 4 {
        case 0: return "Ask the invented gardener about chain \(chain) item \(n)"
        case 3 where (chain + n) % 2 == 0: return "Paid the invented notary fee \(k) for chain \(chain) item \(n)"
        case 3: return "Move the invented permit \(k) for chain \(chain) item \(n) to November 20"
        default: return "Call the invented roofer about chain \(chain) item \(n)"
        }
    }

    /// The line's number (the word after "item").
    func number(_ line: Substring) -> Int? {
        let words = line.split(separator: " ")
        guard let i = words.firstIndex(of: "item"), i + 1 < words.count else { return nil }
        return Int(words[i + 1])
    }

    /// The second binder's items the clerk changes: notary fees to complete, permits to move.
    func targets(_ m: Model) -> [String: (String, String)] {
        var out: [String: (String, String)] = [:]
        for chain in m.chains.indices {
            for n in 1...14 where n % 4 == 3 {
                let k = (chain + n) % 6 + 1
                out[line(chain, n)] = (chain + n) % 2 == 0 ? ("garden-example-2026-1\(k)1", "done") : ("garden-example-2026-1\(k)2", "update")
            }
        }
        return out
    }

    func addTargets(_ folder: URL) throws {
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("t"))])
        var ops: [TekaStore.OpBody] = []
        for k in 1...6 {
            ops.append(.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([("id", .string("garden-example-2026-1\(k)1")),
                ("title", .string("Invented notary fee \(k)")), ("status", .str("open")), ("priority", .str("normal")), ("no_deadline", .bool(true))]))]), actor: actor))
            ops.append(.init(op: "add_item", args: JSONObject([(key: "item", value: .obj([("id", .string("garden-example-2026-1\(k)2")),
                ("title", .string("Invented permit \(k)")), ("status", .str("open")), ("priority", .str("normal")), ("due", .str("2026-11-01"))]))]), actor: actor))
        }
        _ = try TekaStore(folder: folder).apply(ops, now: pNow)
    }

    func text(_ chain: Int, _ rng: inout Rng, from old: [Int] = []) -> [Int] {
        var numbers = old.filter { _ in rng.chance(70) }
        let more = rng.chance(10) ? 11 + rng.below(2) : 1 + rng.below(3)
        for _ in 0..<more where numbers.count < 14 {
            if let n = (1...14).filter({ !numbers.contains($0) }).randomElement(using: &rng) { numbers.insert(n, at: rng.below(numbers.count + 1)) }
        }
        return numbers
    }

    func publish(_ s: PSetup, _ m: Model, chain: Int, revision: String, text: String, private: Bool, retracted: Bool,
                 device: String, clock: (Int, Int)? = nil, ref: String? = nil) throws -> String {
        // Ids and stamps come from the seed, so a run replays exactly; ids are scrambled, so the order a sweep meets
        // the files in a folder is not the order they were written.
        m.written += 1
        var ids = Rng(s: m.seed &* 31 &+ UInt64(m.written))
        let hex = (0..<4).map { _ in String(format: "%08x", UInt32(truncatingIfNeeded: ids.next())) }.joined()
        let id = [hex.prefix(8), hex.dropFirst(8).prefix(4), "4" + hex.dropFirst(13).prefix(3), "8" + hex.dropFirst(17).prefix(3),
                  hex.dropFirst(20).prefix(12)].joined(separator: "-")
        let (wall, counter) = clock ?? (1_791_360_000_000, m.written)
        var o = JSONObject()
        o.set("format", .str("sprava-capture-event"))
        o.set("format_version", .str("0"))
        o.set("id", .string(id))
        o.set("hlc", .obj([("wall_ms", .int(wall)), ("counter", .int(counter)), ("node", .string(device.replacingOccurrences(of: "-", with: "")))]))
        o.set("device", .obj([("id", .string(device))]))
        o.set("source", .obj([("app", .str("adapter")), ("kind", .str("dictation")), ("ref", .string(ref ?? "seq-\(chain)")), ("revision", .string(revision))]))
        o.set("captured_at", .str("2026-10-06T09:00:00-04:00"))
        o.set("locale", .str("en-CA"))
        o.set("text", .string(text))
        o.set("sensitivity", .str(`private` ? "private" : "unmarked"))
        if retracted { o.set("retracted", .bool(true)) }
        let folder = s.producer.root.appendingPathComponent(device)
        try AtomicFile.makePrivateFolder(folder)
        try CaptureProducer.publish(Data(JSONWriter.pretty(.object(o)).utf8), as: folder.appendingPathComponent("\(id).json"))
        m.events[id] = Event(chain: chain, revision: revision, text: text, retracted: retracted, device: device, wall: wall, counter: counter)
        if `private` {
            m.privateChains.insert(chain)
            m.privateEvents.insert(id)
        }
        return id
    }

    func titles(_ p: Proposal) -> [String] {
        p.ops.compactMap { op in
            (op["op"] == .str("add_item") ? op["args"]?["item"]?["title"] : op["args"]?["set"]?["title"])?.stringValue
        }
    }

    // MARK: - The binders, where they are

    /// Where binder `i` is now: its folder, or the place it went to while away.
    func place(_ m: Model, _ i: Int) -> URL { m.away[i] ? awayURL(m.binders[i]) : m.binders[i] }
    func awayURL(_ folder: URL) -> URL { folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".away") }
    func rows(_ m: Model) -> [ShelfRow] { rowsOf(m.binders) }
    func open(_ folder: URL) -> [Proposal] { ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" } }

    /// Every card waiting, in reach or not: each with its binder's index (nil for the Inbox).
    func waitingAll(_ s: PSetup, _ m: Model) -> [(Int?, Proposal)] {
        (0..<2).flatMap { i in open(place(m, i)).map { (Optional(i), $0) } } + s.inbox.unfiled().map { (nil, $0) }
    }

    /// Cards waiting where a sweep can see them.
    func waiting(_ s: PSetup, _ m: Model) -> [(Int?, Proposal)] {
        waitingAll(s, m).filter { $0.0.map { !m.away[$0] } ?? true }
    }

    func filing(_ m: Model) -> [FilingBinder] {
        (0..<2).filter { !m.away[$0] }.map { i in
            let teka = Teka.read(m.binders[i])
            return FilingBinder(name: teka.name, description: Self.descriptions[i], folder: m.binders[i],
                                words: FilingBinder.index(catalog: teka.catalog, description: Self.descriptions[i]),
                                openItems: FilingBinder.candidates(catalog: teka.catalog))
        }
    }

    // MARK: - The steps

    func step(_ s: PSetup, _ m: Model, _ rng: inout Rng) async throws -> Bool {
        let roll = rng.below(100)
        switch roll {
        case 0..<12:   // a new capture
            let chain = m.chains.count
            let numbers = rng.chance(20) ? [] : text(chain, &rng)
            let isPrivate = rng.chance(25)
            m.chains.append([])
            let id = try publish(s, m, chain: chain, revision: "r1", text: numbers.map { line(chain, $0) }.joined(separator: "\n"),
                                 private: isPrivate, retracted: false, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("new \(chain) \(numbers) private=\(isPrivate)")
        case 12..<28:  // a revision (some lines kept, some gone, some new), or a restore after a retraction
            guard let chain = (0..<m.chains.count).filter({ !m.pseudo.contains($0) }).randomElement(using: &rng) else { return false }
            let old = m.current(chain).text.split(separator: "\n").compactMap(number)
            var numbers = text(chain, &rng, from: old)
            // Often one line only is corrected (replaced, taken out or added), the others kept as they were.
            if rng.chance(50), !old.isEmpty {
                numbers = old
                let k = rng.below(numbers.count)
                switch rng.below(3) {
                case 0: if let n = (1...14).filter({ !old.contains($0) }).randomElement(using: &rng) { numbers[k] = n }
                case 1: if numbers.count > 1 { numbers.remove(at: k) }
                default: if let n = (1...14).filter({ !old.contains($0) }).randomElement(using: &rng) { numbers.insert(n, at: k) }
                }
            }
            // Sometimes the words are all taken out (a revision with no text, not a retraction).
            if rng.chance(8) { numbers = [] } else if numbers.isEmpty { numbers = [1] }
            let isPrivate = rng.chance(10)
            let id = try publish(s, m, chain: chain, revision: "r\(m.chains[chain].count + 1)", text: numbers.map { line(chain, $0) }.joined(separator: "\n"),
                                 private: isPrivate, retracted: false, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("revise \(chain) \(numbers) private=\(isPrivate)\(m.anyAway ? " (away: \(m.away))" : "")")
        case 28..<33:  // a retraction
            guard let chain = (0..<m.chains.count).filter({ !m.pseudo.contains($0) && !m.current($0).retracted }).randomElement(using: &rng) else { return false }
            let isPrivate = rng.chance(10)
            let id = try publish(s, m, chain: chain, revision: "retracted", text: "", private: isPrivate, retracted: true, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("retract \(chain) private=\(isPrivate)")
        case 33..<40:  // a copy of an event from the other device, the same stamp, sensitivity the same or raised
            guard let id = m.chains.indices.filter({ !m.pseudo.contains($0) }).flatMap({ m.chains[$0] }).randomElement(using: &rng),
                  let e = m.events[id] else { return false }
            let isPrivate = m.privateChains.contains(e.chain) || rng.chance(30)
            // To the other registered device, or to a folder no producer is registered for (swept first, so its copy
            // can get the card before the registered original is taken for its duplicate).
            let target = rng.chance(40) ? unregistered : devices.first { $0 != e.device }!
            let copy = try publish(s, m, chain: e.chain, revision: e.revision, text: e.text, private: isPrivate, retracted: e.retracted,
                                   device: target, clock: (e.wall, e.counter))
            m.copies[e.chain, default: []].append(copy)
            m.log.append("copy \(e.chain) \(e.revision) private=\(isPrivate)\(target == unregistered ? " unregistered" : "")")
        case 40..<46:  // a sweep that stops at a random cursor save: one that fails, or the process killed right after one
            let saves = rng.below(6)
            // (No kill while the binder's cards are read-only: its files could not be put back.)
            if rng.chance(50) || m.unwritable || m.unreadable != nil {
                CursorCrash.after(saves, cursor: s.inbox.stateURL)
                defer { CursorCrash.after(nil, cursor: s.inbox.stateURL) }
                _ = s.inbox.sweep(binders: rows(m), commands: s.commands, now: pNow)
                m.log.append("crash sweep after \(saves) saves")
            } else {
                let at = try killAtAnySave(s, m, &rng) { _ = s.inbox.sweep(binders: rows(m), commands: s.commands, now: pNow) }
                m.log.append("killed sweep \(at)")
            }
        case 52..<68:  // the clerk reads one capture, sometimes stopping at a cursor save
            guard let work = s.inbox.nextForClerk() else { return false }
            let filing = filing(m)
            let names = (0..<2).map { Teka.read(m.binders[$0]).name ?? "" }
            let interp = await Clerk(model: SeqModel(text: work.event.text, targets: targets(m), names: names))
                .read(work.event, filing: filing, hint: work.hint, now: pNow)
            let crash = rng.chance(40) ? rng.below(3) : nil
            if crash != nil, rng.chance(50), !m.unwritable, m.unreadable == nil {
                let at = try killAtAnySave(s, m, &rng) {
                    _ = s.inbox.commitClerk(work, interp, filing: filing, rows: rows(m), commands: s.commands, seconds: 1, now: pNow)
                }
                m.log.append("clerk \(work.event.id) killed \(at)")
                return false
            }
            CursorCrash.after(crash, cursor: s.inbox.stateURL)
            defer { CursorCrash.after(nil, cursor: s.inbox.stateURL) }
            _ = s.inbox.commitClerk(work, interp, filing: filing, rows: rows(m), commands: s.commands, seconds: 1, now: pNow)
            m.log.append("clerk \(work.event.id) crash=\(crash.map(String.init) ?? "none")")
            // Often the person then approves what the reading filed in one binder, while the rest waits in the other: a
            // later correction of some of the note's lines meets both.
            if crash == nil, rng.chance(60), !m.away[0], !m.unwritable {
                for card in open(m.binders[0]) where CaptureInbox.sourceEvent(card) == work.event.id && card.raw["provenance"]?["interpretation"] != nil {
                    guard let fresh = s.inbox.cardForApproval(card.id, in: m.binders[0], commands: s.commands, now: pNow) else { continue }
                    checkApprovable(fresh, in: m.binders[0], s, m)
                    let done = (try? TekaStore(folder: m.binders[0]).approve(fresh, now: pNow)) != nil
                    m.log.append("approve \(card.id) in 0 \(done ? "applied" : "refused") (part of a reading)")
                }
            }
        case 68..<84:  // the person acts on a waiting card
            // Card ids are random, so cards are picked in an order of what they hold, and a seed replays the same run.
            func key(_ c: (Int?, Proposal)) -> String {
                let events = c.1.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue).map { id in
                    m.events[id].map { "\($0.chain)/\($0.revision)/\($0.device.prefix(1))" } ?? "?"
                } ?? []
                return [c.0.map(String.init) ?? "-", c.1.title, titles(c.1).joined(separator: ";"), events.joined(separator: ",")].joined(separator: "|")
            }
            // Most often a card of the clerk's in a binder, so a note's cards are acted on in one binder while its others
            // wait in the other, and a later correction meets both.
            let all = waiting(s, m).sorted(by: { key($0) < key($1) })
            let clerks = all.filter { $0.0 != nil && $0.1.raw["provenance"]?["interpretation"] != nil }
            guard let (where_, card) = (rng.chance(60) && !clerks.isEmpty ? clerks : all).randomElement(using: &rng) else { return false }
            let privacyOnly = CaptureInbox.onlyRedacts(card)
            guard let i = where_ else {
                if rng.chance(25) && !privacyOnly {
                    try? s.inbox.discard(card.id)
                    decline(card, s, m)
                    m.log.append("discard \(card.id)")
                } else {
                    let into = rng.below(2)
                    guard !m.away[into] else { return false }
                    try? s.inbox.file(card.id, into: m.binders[into], commands: s.commands)
                    m.log.append("file \(card.id) into \(into)")
                }
                return false
            }
            if rng.chance(70) || privacyOnly {
                // The approval path asks the gate for the card, as the app's must: it settles the binder, and redacts or
                // refuses a card of a private chain.
                guard let fresh = s.inbox.cardForApproval(card.id, in: m.binders[i], commands: s.commands, now: pNow) else {
                    m.log.append("approve \(card.id) waits")
                    return false
                }
                // Invariant 2 at every approval: once settling lets it through, nothing on the card is in the clear when
                // its chain is known to be private (a private event of it was taken in).
                checkApprovable(fresh, in: m.binders[i], s, m)
                if m.unwritable && i == 0 {
                    m.log.append("approve \(card.id) not tried: the binder's cards cannot be written")
                    return false
                }
                let done = (try? TekaStore(folder: m.binders[i]).approve(fresh, now: pNow)) != nil
                m.log.append("approve \(card.id) in \(i) \(done ? "applied" : "refused")")
            } else {
                _ = try? TekaStore(folder: m.binders[i]).reject(card, now: pNow)
                decline(card, s, m)
                m.log.append("reject \(card.id) in \(i)")
            }
        case 84..<88:  // a binder's volume goes away, or comes back
            guard !m.unwritable, m.unreadable == nil else { return false }
            try toggleAway(s, m, rng.below(2))
        case 95..<97:  // a private event from an unregistered folder, with a registered chain's app and ref (its own revision)
            guard let target = (0..<m.chains.count).filter({ !m.pseudo.contains($0) }).randomElement(using: &rng) else { return false }
            let chain = m.chains.count
            let numbers = text(chain, &rng)
            m.chains.append([])
            m.pseudo.insert(chain)
            let id = try publish(s, m, chain: chain, revision: "u\(chain)", text: numbers.map { line(chain, $0) }.joined(separator: "\n"),
                                 private: true, retracted: false, device: unregistered, ref: "seq-\(target)")
            m.chains[chain].append(id)
            // A raise only ever makes more private, so it reaches the registered chain of that app and ref too.
            m.privateChains.insert(target)
            m.raisers[target, default: []].insert(id)
            m.log.append("unregistered private event \(chain) with chain \(target)'s ref \(numbers)")
        case 93..<95:  // one waiting card's file cannot be read for a while (a raise or a withdrawal cannot see it), or can again
            guard !m.anyAway, !m.unwritable else { return false }
            toggleUnreadable(s, m, &rng)
        case 88..<90:  // the first binder's cards cannot be written for a while (a raise then fails and stays owed), or can again
            guard !m.away[0], m.unreadable == nil else { return false }
            toggleUnwritable(s, m)
        case 90..<93:  // a capture's card changes an existing item of the first binder from one of its lines
            // Only for a revision the inbox has taken in and carded, as the clerk reads only those.
            let stages = s.inbox.loadState().ingested
            guard !m.away[0], !m.unwritable, let chain = (0..<m.chains.count).filter({
                      !m.chains[$0].isEmpty && !m.current($0).retracted && ["unfiled", "proposed"].contains(stages[m.chains[$0].last!] ?? "")
                  }).randomElement(using: &rng),
                  let source = CaptureInbox.lines(of: m.current(chain).text).randomElement(using: &rng),
                  let target = Teka.read(m.binders[0]).items.compactMap(\.object).filter({ $0["status"] == .str("open") })
                      .sorted(by: { ($0["title"]?.stringValue ?? "") < ($1["title"]?.stringValue ?? "") }).randomElement(using: &rng),
                  let itemID = target["id"] else { return false }
            let priority = target["priority"] == .str("high") ? "low" : "high"
            var set = JSONObject([(key: "priority", value: .string(priority))])
            if m.privateChains.contains(chain) {
                set.set("redact", .bool(true))
                if target["kind"] == nil { set.set("kind", .str("other")) }
            }
            let event = m.chains[chain].last!
            _ = try clerkCard(s, event: event, ops: [spanOp("update_item", [("id", itemID), ("set", .object(set))], event: event, line: source)],
                              in: m.binders[0])
            m.log.append("chain \(chain) changes item \(itemID.stringValue ?? "?") to \(priority) from \"\(source.text)\"")
        default:       // a clean sweep
            _ = s.inbox.sweep(binders: rows(m), commands: s.commands, now: pNow)
            m.log.append("sweep")
            return !m.anyAway && !m.unwritable && m.unreadable == nil
        }
        return false
    }

    // MARK: - The invariants

    /// The line of a chain's event that `span` lies on, read from the model's own copy of the event.
    func lineText(_ span: JSONValue, _ m: Model) -> (chain: Int, text: String)? {
        guard let id = span["event"]?.stringValue, let e = m.events[id], let start = span["start"]?.numberValue?.safeInteger else { return nil }
        return CaptureInbox.lines(of: e.text).first { $0.start <= Int(start) && Int(start) < $0.end }.map { (e.chain, $0.text) }
    }

    /// Every line a card holds: its items' titles, its ops' source lines, and what it lists as not filed yet.
    func heldLines(_ p: Proposal, _ s: PSetup, _ m: Model) -> Set<String> {
        Set(titles(p) + s.inbox.notFiled(p) + p.ops.flatMap { ($0["spans"]?.arrayValue ?? []).compactMap { lineText($0, m)?.text } })
    }

    /// The stamp of the words a card was made from.
    func stamp(_ p: Proposal, _ m: Model) -> Stamp? {
        guard let id = CaptureInbox.sourceEvent(p), let e = m.events[id] else { return nil }
        return Stamp(wall: e.wall, counter: e.counter)
    }

    /// The person declines a card: its lines are theirs, as of the words it came from.
    func decline(_ card: Proposal, _ s: PSetup, _ m: Model) {
        let lines = heldLines(card, s, m)
        m.declined.formUnion(lines)
        guard let at = stamp(card, m) else { return }
        for l in lines { m.declinedAt[l] = max(m.declinedAt[l] ?? at, at) }
    }

    /// The code's own reading of a note: one item per line, which the clerk reads again.
    func codeReading(_ p: Proposal) -> Bool {
        p.raw["provenance"]?["filed_by"] == .str("code, no model") && p.raw["provenance"]?["supersedes"]?.arrayValue == nil
            && p.raw["provenance"]?["carried_from"] == nil && p.ops.allSatisfy { $0["op"] == .str("add_item") }
    }

    /// Records the changes waiting cards ask for now.
    func observe(_ s: PSetup, _ m: Model) {
        guard m.unreadable == nil else { return }
        for (_, p) in waitingAll(s, m) {
            for op in p.ops where op["op"] != .str("add_item") {
                for span in op["spans"]?.arrayValue ?? [] {
                    if let (chain, text) = lineText(span, m), let e = span["event"]?.stringValue { m.asked[Asked(chain: chain, line: text, what: CaptureInbox.what(op)), default: []].insert(e) }
                }
            }
        }
    }

    /// Invariant 1, across both binders wherever they are and the Inbox.
    func checkAccounted(_ s: PSetup, _ m: Model, seed: UInt64) {
        guard m.unreadable == nil else { return }
        let cards = waitingAll(s, m).map(\.1)
        let approved = (0..<2).flatMap { ProposalStore.list(in: place(m, $0)).map(\.0).filter { $0.state == "applied" } }
        let living = cards + approved
        let items = (0..<2).flatMap { Teka.read(place(m, $0)).items.compactMap(\.object) }
        let notFiled = Set(living.flatMap { s.inbox.notFiled($0) })
        let held = Set(items.compactMap { $0["title"]?.stringValue }).union(living.flatMap { heldLines($0, s, m) })
        var doing = Set<Asked>()
        var read: [String: Stamp] = [:]       // lines a reading of later words holds
        var listed: [String: Stamp] = [:]     // lines listed as not filed yet
        for p in living {
            guard let at = stamp(p, m) else { continue }
            // A reading of the words as a whole, the code's or the clerk's: the line is in front of the person as that
            // reading has it (the clerk reads the code's again; its reading replaces an earlier one).
            if codeReading(p) || p.raw["provenance"]?["interpretation"] != nil {
                for l in heldLines(p, s, m) { read[l] = max(read[l] ?? at, at) }
            }
            for l in s.inbox.notFiled(p) { listed[l] = max(listed[l] ?? at, at) }
            for op in p.ops {
                for span in op["spans"]?.arrayValue ?? [] {
                    if let (chain, text) = lineText(span, m) { doing.insert(Asked(chain: chain, line: text, what: CaptureInbox.what(op))) }
                }
            }
        }
        let stages = s.inbox.loadState().ingested
        /// What is not accounted for of `current`, a chain's words. A change is owed only while its line stayed in the
        /// chain's words: once a revision took the line out (or the chain was retracted or emptied), the line coming
        /// back is new content to review (capture-event-v0 §3.2).
        func missing(_ chain: Int, _ current: Event) -> [String] {
            let lines = Set(CaptureInbox.lines(of: current.text).map(\.text))
            let unheld = lines.filter { !(held.contains($0) || notFiled.contains($0) || m.declined.contains($0)) }.sorted()
                .map { "the line \"\($0)\" is on no card, item or not-filed list" }
            let revisions = (m.chains[chain] + (m.copies[chain] ?? [])).compactMap { m.events[$0] }
            func owed(_ line: String, since id: String) -> Bool {
                guard let e = m.events[id] else { return false }
                return revisions.allSatisfy { r in
                    !((e.wall, e.counter) < (r.wall, r.counter) && (r.wall, r.counter) <= (current.wall, current.counter))
                        || (!r.retracted && CaptureInbox.lines(of: r.text).contains { $0.text == line })
                }
            }
            // A change is accounted for by an op that still asks for it, or, from words at least as new as those it was
            // read from, by the line listed as not filed yet, declined, or read again as a whole.
            func later(_ at: Stamp?, than id: String) -> Bool {
                guard let at, let e = m.events[id] else { return false }
                return Stamp(wall: e.wall, counter: e.counter) <= at
            }
            let dropped = m.asked.filter { a, from in
                guard a.chain == chain, lines.contains(a.line), !doing.contains(a) else { return false }
                return from.contains { id in
                    owed(a.line, since: id) && !later(listed[a.line], than: id) && !later(m.declinedAt[a.line], than: id) && !later(read[a.line], than: id)
                }
            }.map { "\($0.key.what) asked for by \"\($0.key.line)\" is no longer asked for" }.sorted()
            return unheld + dropped
        }
        func newest(_ ids: [String]) -> Event? {
            ids.max { a, b in
                let x = m.events[a]!, y = m.events[b]!
                return (x.wall, x.counter, a) < (y.wall, y.counter, b)
            }.flatMap { m.events[$0] }
        }
        for chain in m.chains.indices {
            // The words the inbox has taken the chain to stand for: the newest event of it (a copy counts) that it has
            // settled. A newer one a crash left being taken in may have done part of its work: either its words or the
            // settled ones are accounted for, whole. An event not swept yet has changed nothing.
            let events = m.chains[chain] + (m.copies[chain] ?? [])
            let settled = newest(events.filter { !["ingested", "stale_revision", "duplicate"].contains(stages[$0] ?? "ingested") })
            let started = newest(events.filter { stages[$0] == "ingested" })
            guard let settled else { continue }   // before a first event is settled, the chain stood for no words
            var candidates = [settled]
            if let started, (settled.wall, settled.counter) < (started.wall, started.counter) { candidates.append(started) }
            let gaps = candidates.map { $0.retracted ? [] : missing(chain, $0) }
            guard !gaps.isEmpty, !gaps.contains(where: \.isEmpty) else { continue }
            Issue.record("chain \(chain): \(gaps[0].joined(separator: "; "))\n\(diagnose(s, m, chain, seed: seed))")
        }
    }

    /// What a failure report shows about a chain: its events' stages, its cards, and its journal lines.
    func diagnose(_ s: PSetup, _ m: Model, _ chain: Int, seed: UInt64) -> String {
        let state = s.inbox.loadState()
        let stages = m.chains[chain].map { "\($0.prefix(8)) \(m.events[$0]!.revision): \(state.ingested[$0] ?? "-") clerk=\(state.clerk?[$0] ?? "-") \(m.events[$0]!.text.split(separator: "\n").compactMap(number))" }
            + (m.copies[chain] ?? []).map { "copy \($0.prefix(8)) \(m.events[$0]!.revision): \(state.ingested[$0] ?? "-")" }
        let all = ((0..<2).flatMap { i in ProposalStore.list(in: place(m, i)).map { (String(i), $0.0) } } + s.inbox.unfiled().map { ("-", $0) }).filter { _, p in
            p.raw["provenance"]?["events"]?.arrayValue?.contains { m.ids(chain).contains($0.stringValue ?? "") } == true
        }.map { b, p in
            "[\(b)] \(p.id.prefix(8)) \(p.state) \(p.raw["rejected_reason"]?.stringValue ?? "") \(p.title) ops=\(p.ops.map { "\($0["op"]?.stringValue ?? "?")@\(($0["spans"]?.arrayValue ?? []).compactMap { lineText($0, m)?.text }.compactMap { number(Substring($0)) })" }) nf=\(s.inbox.notFiled(p).count) private=\(p.raw["provenance"]?["private"] == .bool(true))"
        }
        let journal = ((try? String(contentsOf: s.inbox.journalURL, encoding: .utf8)) ?? "").split(separator: "\n").filter { line in
            m.ids(chain).contains { line.contains($0) } || line.contains("clerk_handoff") || line.contains("carry")
        }.suffix(60).joined(separator: "\n")
        return "stages: \(stages)\ncards:\n\(all.joined(separator: "\n"))\nprivates: \(m.ids(chain).filter { (state.privates ?? []).contains($0) }.count)\njournal: \(journal)\nseed \(seed):\n" + m.log.suffix(80).joined(separator: "\n")
    }

    /// Invariants 2 and 3, and the clerk's acted count, at a clean sweep with both binders in reach.
    func check(_ s: PSetup, _ m: Model, seed: UInt64) {
        let cards = waiting(s, m).map(\.1)
        let trace = "seed \(seed):\n" + m.log.suffix(80).joined(separator: "\n")
        for chain in m.chains.indices where !m.chains[chain].isEmpty && m.privateChains.contains(chain) {
            // 2. Nothing from a private chain is unredacted.
            let ids = m.ids(chain)
            func fromChain(_ o: JSONValue?) -> Bool { o?["provenance"]?["events"]?.arrayValue?.contains { ids.contains($0.stringValue ?? "") } == true }
            let redacting = Set(cards.flatMap(\.ops).compactMap { op -> String? in
                op["op"] == .str("update_item") && op["args"]?["set"]?["redact"] == .bool(true) ? op["args"]?["id"]?.stringValue : nil
            })
            for folder in m.binders {
                // An item counts as the chain's when the chain made it, or when an approved card of the chain changed it,
                // as the op log records (the item keeps the provenance of whatever made it).
                let approved = Set(ProposalStore.list(in: folder).map(\.0).filter { $0.state == "applied" && fromChain(.object($0.raw)) }.map(\.id))
                let changed = Set(((try? TekaStore(folder: folder).readOpLog().ops) ?? []).compactMap { line -> String? in
                    guard approved.contains(line["proposal"]?.stringValue ?? ""), line["op"] != .str("file_document"),
                          line["op"] != .str("update_document") else { return nil }
                    return (line["args"]?["item"]?["id"] ?? line["args"]?["id"])?.stringValue
                })
                for o in Teka.read(folder).items.compactMap(\.object) where (fromChain(.object(o)) || changed.contains(o["id"]?.stringValue ?? ""))
                    && o["redact"] != .bool(true) && !redacting.contains(o["id"]?.stringValue ?? "") {
                    Issue.record("chain \(chain): item \(o["id"]?.stringValue ?? "?") is unredacted\n\(diagnose(s, m, chain, seed: seed))")
                }
            }
            for card in cards {
                for op in card.ops where op["op"] == .str("add_item") && fromChain(op["args"]?["item"]) && op["args"]?["item"]?["redact"] != .bool(true) {
                    Issue.record("chain \(chain): card \(card.id) adds an unredacted item\n\(diagnose(s, m, chain, seed: seed))")
                }
            }
        }
        // The clerk's work is counted "acted" only when the person did act: its code-built card no longer waits where
        // Sprava put it (filing an Inbox card into a binder is acting on it).
        let state = s.inbox.loadState()
        let inInbox = Set(s.inbox.unfiled().map(\.id))
        for (id, clerk) in state.clerk ?? [:] where clerk == "acted" {
            guard let card = state.cards[id] else { continue }
            let waits = state.cardBinder?[id].map { binder in open(URL(fileURLWithPath: binder, isDirectory: true)).contains { $0.id == card } }
                ?? inInbox.contains(card)
            if waits { Issue.record("the clerk's work for \(id) was counted acted while its card \(card) still waits\n\(trace)") }
        }
        // 3. No card waits from words that are no longer the chain's current ones.
        for card in cards where !CaptureInbox.onlyRedacts(card) && card.raw["provenance"]?["retraction"] == nil {
            let events = card.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard events.count == 1, let e = m.events[events[0]] else {
                Issue.record("card \(card.id) has no single event of its own\n\(trace)")
                continue
            }
            let current = m.current(e.chain)
            if current.retracted || e.text != current.text {
                Issue.record("card \(card.id) waits from chain \(e.chain) \(e.revision), but its current words are \(current.revision)\n\(diagnose(s, m, e.chain, seed: seed))")
            }
        }
    }

    /// The first binder's cards folder becomes read-only (a raise or a withdrawal then fails and stays owed), or
    /// writable again. Invariants 2 and 3 are not checked at a sweep meanwhile; approvals are still asked for, and
    /// must be held while anything is owed.
    func toggleUnwritable(_ s: PSetup, _ m: Model) {
        let proposals = ProposalStore.dir(m.binders[0])
        try? FileManager.default.createDirectory(at: proposals, withIntermediateDirectories: true)
        chmod(proposals.path, m.unwritable ? 0o700 : 0o500)
        m.unwritable.toggle()
        m.log.append(m.unwritable ? "binder cards unwritable" : "binder cards writable")
    }

    /// One waiting card's file, in the first binder or the Inbox, becomes unreadable, or readable again. No
    /// invariant is checked meanwhile; approvals are still asked for.
    func toggleUnreadable(_ s: PSetup, _ m: Model, _ rng: inout Rng) {
        if let file = m.unreadable {
            chmod(file.path, 0o600)
            m.unreadable = nil
            m.log.append("card file readable again")
            return
        }
        let inBinder = open(m.binders[0]).map { ProposalStore.dir(m.binders[0]).appendingPathComponent("\($0.id).json") }
        let inInbox = s.inbox.unfiled().map { s.inbox.unfiledDir.appendingPathComponent("\($0.id).json") }
        let files = (inBinder + inInbox).sorted { $0.path < $1.path }
        guard !files.isEmpty else { return }
        let file = files[rng.below(files.count)]
        chmod(file.path, 0o000)
        m.unreadable = file
        m.log.append("card file unreadable: \(file.lastPathComponent)")
    }

    /// Invariant 2 at an approval: when the card's chain is known to be private (one of its private events was taken
    /// in), nothing it adds or changes is in the clear.
    func checkApprovable(_ card: Proposal, in folder: URL, _ s: PSetup, _ m: Model) {
        let stages = s.inbox.loadState().ingested
        let redacted = Set(Teka.read(folder).items.compactMap(\.object).filter { $0["redact"] == .bool(true) }.compactMap { $0["id"]?.stringValue })
        let chains = Set((card.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []).compactMap { m.events[$0]?.chain })
        for chain in chains where m.ids(chain).union(m.raisers[chain] ?? []).contains(where: { m.privateEvents.contains($0) && stages[$0] != nil }) {
            let clear = card.ops.contains { op in
                switch op["op"]?.stringValue {
                case "add_item": op["args"]?["item"]?["redact"] != .bool(true)
                // An update in the clear is fine on an item already redacted: the item stays so.
                case "update_item": op["args"]?["set"]?["redact"] != .bool(true) && !redacted.contains(op["args"]?["id"]?.stringValue ?? "")
                default: false
                }
            }
            if clear {
                let state = s.inbox.loadState()
                Issue.record("card \(card.id) of private chain \(chain) is let through for approval in the clear\n\(JSONWriter.compact(.object(card.raw)))\ndebts: \(state.debts ?? [])\n\(diagnose(s, m, chain, seed: m.seed))")
            }
        }
    }

    final class Taken: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var value: Bool { lock.withLock { done } }
        func set() { lock.withLock { done = true } }
    }

    /// Runs `body` as a process killed right after the `afterSave`-th save of the cursor: Sprava's support folder and
    /// the binders are copied as they are at that moment, and put back once `body` is done, so nothing written after
    /// that save survives. True when that save was reached.
    func kill(_ s: PSetup, _ m: Model, afterSave n: Int, _ body: () -> Void) throws -> Bool {
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-killed-\(UUID().uuidString)")
        let places = self.places(s, m)
        let taken = Taken()
        CursorCrash.stop(after: n, cursor: s.inbox.stateURL) {
            Self.copy(places, to: snapshot)
            taken.set()
        }
        body()
        CursorCrash.stop(after: nil, cursor: s.inbox.stateURL)
        guard taken.value else { return false }
        try putBack(places, from: snapshot)
        return true
    }

    /// Kills `body` right after one of its cursor saves, picked at random among all it makes: it runs once to count
    /// them, everything is put back, and it runs again to be killed there. So every save, the last one of an event's
    /// stage among them, is a crash point some seed meets.
    func killAtAnySave(_ s: PSetup, _ m: Model, _ rng: inout Rng, _ body: () -> Void) throws -> String {
        let before = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-before-\(UUID().uuidString)")
        let places = self.places(s, m)
        Self.copy(places, to: before)
        let counted = CursorCrash.saves(s.inbox.stateURL)
        body()
        let n = CursorCrash.saves(s.inbox.stateURL) - counted
        try putBack(places, from: before)
        guard n > 0 else { return "no save" }
        let k = 1 + rng.below(n)
        _ = try kill(s, m, afterSave: k, body)
        return "after save \(k) of \(n)"
    }

    func places(_ s: PSetup, _ m: Model) -> [URL] {
        [s.support] + m.binders.flatMap { [$0, awayURL($0)] }
    }

    static func copy(_ places: [URL], to snapshot: URL) {
        try? FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        for (i, place) in places.enumerated() where FileManager.default.fileExists(atPath: place.path) {
            try? FileManager.default.copyItem(at: place, to: snapshot.appendingPathComponent("\(i)"))
        }
    }

    func putBack(_ places: [URL], from snapshot: URL) throws {
        let fm = FileManager.default
        for (i, place) in places.enumerated() {
            if fm.fileExists(atPath: place.path) { try fm.removeItem(at: place) }
            let copy = snapshot.appendingPathComponent("\(i)")
            if fm.fileExists(atPath: copy.path) { try fm.copyItem(at: copy, to: place) }
        }
        try? fm.removeItem(at: snapshot)
    }

    /// Binder `i`'s folder moves out of reach (a volume disconnected) or back. While either is away invariants 2 and 3
    /// are not checked; invariant 1 is, reading the binder where it went. Once both are back, the next clean sweep
    /// must leave all three holding.
    func toggleAway(_ s: PSetup, _ m: Model, _ i: Int) throws {
        let folder = m.binders[i]
        if m.away[i] { try FileManager.default.moveItem(at: awayURL(folder), to: folder) } else { try FileManager.default.moveItem(at: folder, to: awayURL(folder)) }
        m.away[i].toggle()
        m.log.append(m.away[i] ? "binder \(i) away" : "binder \(i) back")
    }

    func run(seed: UInt64, steps: Int) async throws {
        let s = try pSetup()
        for device in devices { try s.inbox.registerProducer(folder: device, app: "adapter") }
        let m = Model()
        m.seed = seed
        m.binders = [s.folder, try secondBinder(s)]
        try addTargets(m.binders[1])
        var rng = Rng(s: seed)
        for _ in 0..<steps {
            let clean = try await step(s, m, &rng)
            observe(s, m)
            checkAccounted(s, m, seed: seed)
            if clean { check(s, m, seed: seed) }
        }
        if m.unreadable != nil { toggleUnreadable(s, m, &rng) }
        if m.unwritable { toggleUnwritable(s, m) }
        for i in 0..<2 where m.away[i] { try toggleAway(s, m, i) }
        // Whatever happened, two clean sweeps settle everything.
        _ = s.inbox.sweep(binders: rows(m), commands: s.commands, now: pNow)
        _ = s.inbox.sweep(binders: rows(m), commands: s.commands, now: pNow)
        m.log.append("final sweeps")
        observe(s, m)
        checkAccounted(s, m, seed: seed)
        check(s, m, seed: seed)
    }

    /// Seeds whose runs meet the withdrawal gate where it must carry: each fails when withdrawn cards are not carried
    /// (a completion, a date change, an added line of a binder away during a correction).
    @Test(arguments: [UInt64(3006), 3025, 3051, 3053])
    func randomSequencesKeepEveryCaptureAccountedFor(seed: UInt64) async throws {
        try await run(seed: seed, steps: 150)
    }
}

extension InboxSequenceTests.Rng: RandomNumberGenerator {}

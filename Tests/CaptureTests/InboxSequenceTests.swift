import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Random sequences of what can happen to the inbox, from fixed seeds: captures (private or not, empty or not),
/// revisions, retractions, copies from a second device, crashes at a random cursor save, the clerk's hand-off, the
/// person approving, rejecting, filing or discarding cards, and sweeps. After every clean sweep three things hold:
/// 1. every line of each chain's current revision is accounted for: on a waiting card, listed as not filed yet, in
///    the binder, or declined by the person;
/// 2. nothing from a chain ever marked private is unredacted in the binder (or lacks a waiting redaction), and no
///    waiting card adds it unredacted;
/// 3. no card waits from a revision that is not the chain's current words, unless it only narrows privacy (or is a
///    retraction's removal card). Invented data only.
@Suite(.serialized) struct InboxSequenceTests {
    let devices = ["aaaaaaaa-2222-4333-8444-5555555555e1", "bbbbbbbb-2222-4333-8444-5555555555e2"]

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

    final class Model {
        var events: [String: Event] = [:]
        var chains: [[String]] = []        // chain -> its revisions' ids in the order written (copies not included)
        var copies: [Int: [String]] = [:]  // chain -> ids of copies
        var privateChains = Set<Int>()
        var declined = Set<String>()       // titles on cards the person rejected or discarded
        var log: [String] = []
        var seed: UInt64 = 0
        var written = 0

        func current(_ chain: Int) -> Event { events[chains[chain].last!]! }
        func ids(_ chain: Int) -> Set<String> { Set(chains[chain] + (copies[chain] ?? [])) }
    }

    func line(_ chain: Int, _ n: Int) -> String { "Call the invented roofer about chain \(chain) item \(n)" }

    func text(_ chain: Int, _ rng: inout Rng, from old: [Int] = []) -> [Int] {
        var numbers = old.filter { _ in rng.chance(70) }
        let more = rng.chance(10) ? 11 + rng.below(2) : 1 + rng.below(3)
        for _ in 0..<more where numbers.count < 14 {
            if let n = (1...14).filter({ !numbers.contains($0) }).randomElement(using: &rng) { numbers.insert(n, at: rng.below(numbers.count + 1)) }
        }
        return numbers
    }

    func publish(_ s: PSetup, _ m: Model, chain: Int, revision: String, text: String, private: Bool, retracted: Bool,
                 device: String, clock: (Int, Int)? = nil) throws -> String {
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
        o.set("source", .obj([("app", .str("adapter")), ("kind", .str("dictation")), ("ref", .string("seq-\(chain)")), ("revision", .string(revision))]))
        o.set("captured_at", .str("2026-10-06T09:00:00-04:00"))
        o.set("locale", .str("en-CA"))
        o.set("text", .string(text))
        o.set("sensitivity", .str(`private` ? "private" : "unmarked"))
        if retracted { o.set("retracted", .bool(true)) }
        let folder = s.producer.root.appendingPathComponent(device)
        try AtomicFile.makePrivateFolder(folder)
        try CaptureProducer.publish(Data(JSONWriter.pretty(.object(o)).utf8), as: folder.appendingPathComponent("\(id).json"))
        m.events[id] = Event(chain: chain, revision: revision, text: text, retracted: retracted, device: device, wall: wall, counter: counter)
        if `private` { m.privateChains.insert(chain) }
        return id
    }

    func titles(_ p: Proposal) -> [String] {
        p.ops.compactMap { op in
            (op["op"] == .str("add_item") ? op["args"]?["item"]?["title"] : op["args"]?["set"]?["title"])?.stringValue
        }
    }

    func waiting(_ s: PSetup) -> [Proposal] { pOpen(s) + s.inbox.unfiled() }

    // MARK: - The steps

    func step(_ s: PSetup, _ m: Model, _ rng: inout Rng) async throws -> Bool {
        let roll = rng.below(100)
        switch roll {
        case 0..<16:   // a new capture
            let chain = m.chains.count
            let numbers = rng.chance(20) ? [] : text(chain, &rng)
            let isPrivate = rng.chance(25)
            m.chains.append([])
            let id = try publish(s, m, chain: chain, revision: "r1", text: numbers.map { line(chain, $0) }.joined(separator: "\n"),
                                 private: isPrivate, retracted: false, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("new \(chain) \(numbers) private=\(isPrivate)")
        case 16..<34:  // a revision, or a restore after a retraction
            guard !m.chains.isEmpty else { return false }
            let chain = rng.below(m.chains.count)
            let old = m.current(chain).text.split(separator: "\n").compactMap { Int($0.split(separator: " ").last ?? "") }
            var numbers = text(chain, &rng, from: old)
            if numbers.isEmpty { numbers = [1] }
            let isPrivate = rng.chance(10)
            let id = try publish(s, m, chain: chain, revision: "r\(m.chains[chain].count + 1)", text: numbers.map { line(chain, $0) }.joined(separator: "\n"),
                                 private: isPrivate, retracted: false, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("revise \(chain) \(numbers) private=\(isPrivate)")
        case 34..<42:  // a retraction
            guard let chain = (0..<m.chains.count).filter({ !m.current($0).retracted }).randomElement(using: &rng) else { return false }
            let isPrivate = rng.chance(10)
            let id = try publish(s, m, chain: chain, revision: "retracted", text: "", private: isPrivate, retracted: true, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("retract \(chain) private=\(isPrivate)")
        case 42..<50:  // a copy of an event from the other device, the same stamp, sensitivity the same or raised
            guard let id = m.chains.flatMap({ $0 }).randomElement(using: &rng), let e = m.events[id] else { return false }
            let isPrivate = m.privateChains.contains(e.chain) || rng.chance(15)
            let copy = try publish(s, m, chain: e.chain, revision: e.revision, text: e.text, private: isPrivate, retracted: e.retracted,
                                   device: devices.first { $0 != e.device }!, clock: (e.wall, e.counter))
            m.copies[e.chain, default: []].append(copy)
            m.log.append("copy \(e.chain) \(e.revision) private=\(isPrivate)")
        case 50..<62:  // a sweep that stops at a random cursor save
            let saves = rng.below(6)
            CursorCrash.after(saves, cursor: s.inbox.stateURL)
            defer { CursorCrash.after(nil, cursor: s.inbox.stateURL) }
            _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
            m.log.append("crash sweep after \(saves) saves")
        case 62..<72:  // the clerk reads one capture, sometimes stopping at a cursor save
            guard let work = s.inbox.nextForClerk() else { return false }
            let answer = CaptureInbox.lines(of: work.event.text).map { item($0.text, $0.text) }
            let interp = await Clerk(model: RecordingModel([.obj([("items", .array(answer))])]))
                .read(work.event, filing: [bFiling(s)], hint: work.hint, now: pNow)
            let crash = rng.chance(40) ? rng.below(3) : nil
            CursorCrash.after(crash, cursor: s.inbox.stateURL)
            defer { CursorCrash.after(nil, cursor: s.inbox.stateURL) }
            _ = s.inbox.commitClerk(work, interp, filing: [bFiling(s)], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
            m.log.append("clerk \(work.event.id) crash=\(crash.map(String.init) ?? "none")")
        case 72..<86:  // the person acts on a waiting card
            // Card ids are random, so cards are picked in an order of what they hold, and a seed replays the same run.
            func key(_ p: Proposal) -> String {
                let events = p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue).map { id in
                    m.events[id].map { "\($0.chain)/\($0.revision)/\($0.device.prefix(1))" } ?? "?"
                } ?? []
                return [p.title, titles(p).joined(separator: ";"), events.joined(separator: ",")].joined(separator: "|")
            }
            guard let card = waiting(s).sorted(by: { key($0) < key($1) }).randomElement(using: &rng) else { return false }
            let inInbox = s.inbox.unfiled().contains { $0.id == card.id }
            let privacyOnly = CaptureInbox.onlyRedacts(card)
            if inInbox {
                if rng.chance(25) && !privacyOnly {
                    try? s.inbox.discard(card.id)
                    m.declined.formUnion(titles(card) + s.inbox.notFiled(card))
                    m.log.append("discard \(card.id)")
                } else {
                    try? s.inbox.file(card.id, into: s.folder, commands: s.commands)
                    m.log.append("file \(card.id)")
                }
            } else if rng.chance(70) || privacyOnly {
                let done = (try? TekaStore(folder: s.folder).approve(card, now: pNow)) != nil
                m.log.append("approve \(card.id) \(done ? "applied" : "refused")")
            } else {
                _ = try? TekaStore(folder: s.folder).reject(card, now: pNow)
                m.declined.formUnion(titles(card) + s.inbox.notFiled(card))
                m.log.append("reject \(card.id)")
            }
        default:       // a clean sweep
            _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
            m.log.append("sweep")
            return true
        }
        return false
    }

    // MARK: - The invariants

    func check(_ s: PSetup, _ m: Model, seed: UInt64) {
        let cards = waiting(s)
        let teka = Teka.read(s.folder)
        let items = teka.items.compactMap(\.object)
        // Lines a card listed as not filed yet: on a waiting card, or on one the person approved with that list in view.
        let approved = ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "applied" }
        let notFiled = Set((cards + approved).flatMap { s.inbox.notFiled($0) })
        let shown = Set(items.compactMap { $0["title"]?.stringValue } + cards.flatMap(titles))
        let trace = "seed \(seed):\n" + m.log.suffix(80).joined(separator: "\n")

        for chain in m.chains.indices where !m.chains[chain].isEmpty {
            let current = m.current(chain)
            // 1. Every line of the current revision is accounted for.
            if !current.retracted {
                for l in CaptureInbox.lines(of: current.text) where !(shown.contains(l.text) || notFiled.contains(l.text) || m.declined.contains(l.text)) {
                    let state = s.inbox.loadState()
                    let stages = m.chains[chain].map { "\($0.prefix(8)) \(m.events[$0]!.revision): \(state.ingested[$0] ?? "-") clerk=\(state.clerk?[$0] ?? "-") \(m.events[$0]!.text.split(separator: "\n").map { $0.split(separator: " ").last ?? "" })" }
                        + (m.copies[chain] ?? []).map { "copy \($0.prefix(8)) \(m.events[$0]!.revision): \(state.ingested[$0] ?? "-")" }
                    let all = (ProposalStore.list(in: s.folder).map(\.0) + s.inbox.unfiled()).filter { p in
                        p.raw["provenance"]?["events"]?.arrayValue?.contains { m.ids(chain).contains($0.stringValue ?? "") } == true
                    }.map { "\($0.id.prefix(8)) \($0.state) \($0.raw["rejected_reason"]?.stringValue ?? "") \($0.title) \(titles($0).map { $0.split(separator: " ").last ?? "" }) nf=\(s.inbox.notFiled($0).count)" }
                    Issue.record("chain \(chain): the line \"\(l.text)\" is on no card, item or not-filed list\nstages: \(stages)\nbinder cards: \(all)\nwaiting: \(cards.filter { p in p.raw["provenance"]?["events"]?.arrayValue?.contains { m.ids(chain).contains($0.stringValue ?? "") } == true }.map { JSONWriter.compact(.object($0.raw)) })\n\(trace)")
                }
            }
            // 2. Nothing from a private chain is unredacted.
            if m.privateChains.contains(chain) {
                let ids = m.ids(chain)
                func fromChain(_ o: JSONValue?) -> Bool { o?["provenance"]?["events"]?.arrayValue?.contains { ids.contains($0.stringValue ?? "") } == true }
                let redacting = Set(cards.flatMap(\.ops).compactMap { op -> String? in
                    op["op"] == .str("update_item") && op["args"]?["set"]?["redact"] == .bool(true) ? op["args"]?["id"]?.stringValue : nil
                })
                for o in items where fromChain(.object(o)) && o["redact"] != .bool(true) && !redacting.contains(o["id"]?.stringValue ?? "") {
                    Issue.record("chain \(chain): item \(o["id"]?.stringValue ?? "?") is unredacted\n\(trace)")
                }
                for card in cards {
                    for op in card.ops where op["op"] == .str("add_item") && fromChain(op["args"]?["item"]) && op["args"]?["item"]?["redact"] != .bool(true) {
                        Issue.record("chain \(chain): card \(card.id) adds an unredacted item\n\(trace)")
                    }
                }
            }
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
                Issue.record("card \(card.id) waits from chain \(e.chain) \(e.revision), but its current words are \(current.revision)\n\(trace)")
            }
        }
    }

    func run(seed: UInt64, steps: Int) async throws {
        let s = try pSetup()
        for device in devices { try s.inbox.registerProducer(folder: device, app: "adapter") }
        let m = Model()
        m.seed = seed
        var rng = Rng(s: seed)
        for _ in 0..<steps {
            if try await step(s, m, &rng) { check(s, m, seed: seed) }
        }
        // Whatever happened, two clean sweeps settle everything.
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        m.log.append("final sweeps")
        check(s, m, seed: seed)
    }

    @Test(arguments: [UInt64(7), 118, 221, 412])
    func randomSequencesKeepEveryCaptureAccountedFor(seed: UInt64) async throws {
        try await run(seed: seed, steps: 80)
    }
}

extension InboxSequenceTests.Rng: RandomNumberGenerator {}

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
/// person approving (after the approval path settles what the binder missed), rejecting, filing or discarding cards,
/// the binder going out of reach and coming back, and sweeps. After every clean sweep with the binder in reach three
/// things hold:
/// 1. every line of each chain's current revision is accounted for: on a waiting card, listed as not filed yet, in
///    the binder, or declined by the person;
/// 2. nothing from a chain ever marked private is unredacted in the binder (or lacks a waiting redaction), and no
///    waiting card adds it unredacted;
/// 3. no card waits from a revision that is not the chain's current words, unless it only narrows privacy (or is a
///    retraction's removal card). Invented data only.
@Suite(.serialized) struct InboxSequenceTests {
    let devices = ["aaaaaaaa-2222-4333-8444-5555555555e1", "bbbbbbbb-2222-4333-8444-5555555555e2"]
    let unregistered = "00000000-2222-4333-8444-5555555555e0"

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
        var away = false
        var unwritable = false
        var unreadable: URL?      // a card file made unreadable for a while
        var pseudo = Set<Int>()   // "chains" that are one event from an unregistered folder, never revised
        var raisers: [Int: Set<String>] = [:]   // chain -> private events from unregistered folders that raised it
        var privateEvents = Set<String>()

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
            guard let chain = (0..<m.chains.count).filter({ !m.pseudo.contains($0) }).randomElement(using: &rng) else { return false }
            let old = m.current(chain).text.split(separator: "\n").compactMap { Int($0.split(separator: " ").last ?? "") }
            var numbers = text(chain, &rng, from: old)
            // Sometimes the words are all taken out (a revision with no text, not a retraction).
            if rng.chance(8) { numbers = [] } else if numbers.isEmpty { numbers = [1] }
            let isPrivate = rng.chance(10)
            let id = try publish(s, m, chain: chain, revision: "r\(m.chains[chain].count + 1)", text: numbers.map { line(chain, $0) }.joined(separator: "\n"),
                                 private: isPrivate, retracted: false, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("revise \(chain) \(numbers) private=\(isPrivate)")
        case 34..<42:  // a retraction
            guard let chain = (0..<m.chains.count).filter({ !m.pseudo.contains($0) && !m.current($0).retracted }).randomElement(using: &rng) else { return false }
            let isPrivate = rng.chance(10)
            let id = try publish(s, m, chain: chain, revision: "retracted", text: "", private: isPrivate, retracted: true, device: rng.pick(devices))
            m.chains[chain].append(id)
            m.log.append("retract \(chain) private=\(isPrivate)")
        case 42..<50:  // a copy of an event from the other device, the same stamp, sensitivity the same or raised
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
        case 50..<62:  // a sweep that stops at a random cursor save: one that fails, or the process killed right after one
            let saves = rng.below(6)
            // (No kill while the binder's cards are read-only: its files could not be put back.)
            if rng.chance(50) || m.unwritable || m.unreadable != nil {
                CursorCrash.after(saves, cursor: s.inbox.stateURL)
                defer { CursorCrash.after(nil, cursor: s.inbox.stateURL) }
                _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
                m.log.append("crash sweep after \(saves) saves")
            } else {
                let at = try killAtAnySave(s, m, &rng) { _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }
                m.log.append("killed sweep \(at)")
            }
        case 62..<72:  // the clerk reads one capture, sometimes stopping at a cursor save
            guard let work = s.inbox.nextForClerk() else { return false }
            let answer = CaptureInbox.lines(of: work.event.text).map { item($0.text, $0.text) }
            let interp = await Clerk(model: RecordingModel([.obj([("items", .array(answer))])]))
                .read(work.event, filing: [bFiling(s)], hint: work.hint, now: pNow)
            let crash = rng.chance(40) ? rng.below(3) : nil
            if crash != nil, rng.chance(50), !m.unwritable, m.unreadable == nil {
                let at = try killAtAnySave(s, m, &rng) {
                    _ = s.inbox.commitClerk(work, interp, filing: [bFiling(s)], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
                }
                m.log.append("clerk \(work.event.id) killed \(at)")
                return false
            }
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
                // The approval path asks the gate for the card, as the app's must: it settles the binder, and redacts or
                // refuses a card of a private chain.
                guard let fresh = s.inbox.cardForApproval(card.id, in: s.folder, commands: s.commands, now: pNow) else {
                    m.log.append("approve \(card.id) waits")
                    return false
                }
                // Invariant 2 at every approval: once settling lets it through, nothing on the card is in the clear when
                // its chain is known to be private (a private event of it was taken in).
                checkApprovable(fresh, s, m)
                if m.unwritable {
                    m.log.append("approve \(card.id) not tried: the binder's cards cannot be written")
                    return false
                }
                let done = (try? TekaStore(folder: s.folder).approve(fresh, now: pNow)) != nil
                m.log.append("approve \(card.id) \(done ? "applied" : "refused")")
            } else {
                _ = try? TekaStore(folder: s.folder).reject(card, now: pNow)
                m.declined.formUnion(titles(card) + s.inbox.notFiled(card))
                m.log.append("reject \(card.id)")
            }
        case 86..<89:  // the binder's volume goes away, or comes back
            guard !m.unwritable, m.unreadable == nil else { return false }
            try toggleAway(s, m)
        case 97..<99:  // a private event from an unregistered folder, with a registered chain's app and ref (its own revision)
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
            m.log.append("unregistered private event \(chain) with chain \(target)'s ref \(numbers)\(m.away ? " (binder away)" : "")")
        case 95..<97:  // one waiting card's file cannot be read for a while (a raise or a withdrawal cannot see it), or can again
            guard !m.away, !m.unwritable else { return false }
            toggleUnreadable(s, m, &rng)
        case 89..<91:  // the binder's cards cannot be written for a while (a raise then fails and stays pending), or can again
            guard !m.away, m.unreadable == nil else { return false }
            toggleUnwritable(s, m)
        case 91..<95:  // a capture's card changes an existing item (as the clerk's update of a matching item does)
            // Only for a revision the inbox has taken in and carded, as the clerk reads only those.
            let stages = s.inbox.loadState().ingested
            guard !m.away, !m.unwritable, let chain = (0..<m.chains.count).filter({
                      !m.chains[$0].isEmpty && !m.current($0).retracted && ["unfiled", "proposed"].contains(stages[m.chains[$0].last!] ?? "")
                  }).randomElement(using: &rng),
                  let target = Teka.read(s.folder).items.compactMap(\.object).filter({ $0["status"] == .str("open") })
                      .sorted(by: { ($0["title"]?.stringValue ?? "") < ($1["title"]?.stringValue ?? "") }).randomElement(using: &rng),
                  let itemID = target["id"] else { return false }
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("invented"))])
            let priority = target["priority"] == .str("high") ? "low" : "high"
            var set = JSONObject([(key: "priority", value: .string(priority))])
            if m.privateChains.contains(chain) {
                set.set("redact", .bool(true))
                if target["kind"] == nil { set.set("kind", .str("other")) }
            }
            let card = Proposal.make(title: "Change an item's priority", actor: actor,
                                     ops: [JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(set))]))])],
                                     provenance: JSONObject([(key: "events", value: .array([.string(m.chains[chain].last!)]))]), now: pNow)
            try ProposalStore.save(card, in: s.folder)
            try s.commands.trustProposals([card.id], in: s.folder)
            m.log.append("chain \(chain) changes item \(itemID.stringValue ?? "?") to \(priority)")
        default:       // a clean sweep
            _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
            m.log.append("sweep")
            return !m.away && !m.unwritable && m.unreadable == nil
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

        /// What a failure report shows about a chain: its events' stages, its cards, and its journal lines.
        func diagnose(_ chain: Int) -> String {
            let state = s.inbox.loadState()
            let stages = m.chains[chain].map { "\($0.prefix(8)) \(m.events[$0]!.revision): \(state.ingested[$0] ?? "-") clerk=\(state.clerk?[$0] ?? "-") \(m.events[$0]!.text.split(separator: "\n").map { $0.split(separator: " ").last ?? "" })" }
                + (m.copies[chain] ?? []).map { "copy \($0.prefix(8)) \(m.events[$0]!.revision): \(state.ingested[$0] ?? "-")" }
            let all = (ProposalStore.list(in: s.folder).map(\.0) + s.inbox.unfiled()).filter { p in
                p.raw["provenance"]?["events"]?.arrayValue?.contains { m.ids(chain).contains($0.stringValue ?? "") } == true
            }.map { "\($0.id.prefix(8)) \($0.state) \($0.raw["rejected_reason"]?.stringValue ?? "") \($0.title) \(titles($0).map { $0.split(separator: " ").last ?? "" }) nf=\(s.inbox.notFiled($0).count) private=\($0.raw["provenance"]?["private"] == .bool(true))" }
            let journal = ((try? String(contentsOf: s.inbox.journalURL, encoding: .utf8)) ?? "").split(separator: "\n").filter { line in
                m.ids(chain).contains { line.contains($0) } || line.contains("clerk_handoff") || line.contains("DBG")
            }.suffix(80).joined(separator: "\n")
            return "stages: \(stages)\ncards: \(all)\nprivates: \(m.ids(chain).filter { (state.privates ?? []).contains($0) }.count)\njournal: \(journal)\n\(trace)"
        }

        for chain in m.chains.indices where !m.chains[chain].isEmpty {
            let current = m.current(chain)
            // 1. Every line of the current revision is accounted for.
            if !current.retracted {
                for l in CaptureInbox.lines(of: current.text) where !(shown.contains(l.text) || notFiled.contains(l.text) || m.declined.contains(l.text)) {
                    Issue.record("chain \(chain): the line \"\(l.text)\" is on no card, item or not-filed list\n\(diagnose(chain))")
                }
            }
            // 2. Nothing from a private chain is unredacted.
            if m.privateChains.contains(chain) {
                let ids = m.ids(chain)
                func fromChain(_ o: JSONValue?) -> Bool { o?["provenance"]?["events"]?.arrayValue?.contains { ids.contains($0.stringValue ?? "") } == true }
                let redacting = Set(cards.flatMap(\.ops).compactMap { op -> String? in
                    op["op"] == .str("update_item") && op["args"]?["set"]?["redact"] == .bool(true) ? op["args"]?["id"]?.stringValue : nil
                })
                // An item counts as the chain's when the chain made it, or when an approved card of the chain changed it,
                // as the op log records (the item keeps the provenance of whatever made it).
                let approved = Set(ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "applied" && fromChain(.object($0.raw)) }.map(\.id))
                let changed = Set(((try? TekaStore(folder: s.folder).readOpLog().ops) ?? []).compactMap { line -> String? in
                    guard approved.contains(line["proposal"]?.stringValue ?? ""), line["op"] != .str("file_document"),
                          line["op"] != .str("update_document") else { return nil }
                    return (line["args"]?["item"]?["id"] ?? line["args"]?["id"])?.stringValue
                })
                for o in items where (fromChain(.object(o)) || changed.contains(o["id"]?.stringValue ?? "")) && o["redact"] != .bool(true)
                    && !redacting.contains(o["id"]?.stringValue ?? "") {
                    Issue.record("chain \(chain): item \(o["id"]?.stringValue ?? "?") is unredacted\n\(diagnose(chain))")
                }
                for card in cards {
                    for op in card.ops where op["op"] == .str("add_item") && fromChain(op["args"]?["item"]) && op["args"]?["item"]?["redact"] != .bool(true) {
                        Issue.record("chain \(chain): card \(card.id) adds an unredacted item\n\(diagnose(chain))")
                    }
                }
            }
        }
        // The clerk's work is counted "acted" only when the person did act: its code-built card no longer waits where
        // Sprava put it (filing an Inbox card into a binder is acting on it).
        let state = s.inbox.loadState()
        let inInbox = Set(s.inbox.unfiled().map(\.id)), inBinder = Set(pOpen(s).map(\.id))
        for (id, clerk) in state.clerk ?? [:] where clerk == "acted" {
            if let card = state.cards[id], state.cardBinder?[id] == nil ? inInbox.contains(card) : inBinder.contains(card) {
                Issue.record("the clerk's work for \(id) was counted acted while its card \(card) still waits\n\(trace)")
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
                Issue.record("card \(card.id) waits from chain \(e.chain) \(e.revision), but its current words are \(current.revision)\n\(diagnose(e.chain))")
            }
        }
    }

    /// The binder's cards folder becomes read-only (a raise or a withdrawal then fails and stays owed), or writable again.
    /// No invariant is checked at a sweep meanwhile; approvals are still asked for, and must be held while anything
    /// is owed.
    func toggleUnwritable(_ s: PSetup, _ m: Model) {
        let proposals = ProposalStore.dir(s.folder)
        try? FileManager.default.createDirectory(at: proposals, withIntermediateDirectories: true)
        chmod(proposals.path, m.unwritable ? 0o700 : 0o500)
        m.unwritable.toggle()
        m.log.append(m.unwritable ? "binder cards unwritable" : "binder cards writable")
    }

    /// One waiting card's file, in the binder or the Inbox, becomes unreadable, or readable again. No invariant is checked
    /// at a sweep meanwhile; approvals are still asked for.
    func toggleUnreadable(_ s: PSetup, _ m: Model, _ rng: inout Rng) {
        if let file = m.unreadable {
            chmod(file.path, 0o600)
            m.unreadable = nil
            m.log.append("card file readable again")
            return
        }
        let inBinder = pOpen(s).map { ProposalStore.dir(s.folder).appendingPathComponent("\($0.id).json") }
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
    func checkApprovable(_ card: Proposal, _ s: PSetup, _ m: Model) {
        let stages = s.inbox.loadState().ingested
        let redacted = Set(Teka.read(s.folder).items.compactMap(\.object).filter { $0["redact"] == .bool(true) }.compactMap { $0["id"]?.stringValue })
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
                let trace = m.log.suffix(60).joined(separator: "\n")
                let state = s.inbox.loadState()
                let stages = m.chains[chain].map { "\($0.prefix(8)) \(m.events[$0]!.revision): \(state.ingested[$0] ?? "-") private=\((state.privates ?? []).contains($0))" }
                Issue.record("card \(card.id) of private chain \(chain) is let through for approval in the clear\n\(JSONWriter.compact(.object(card.raw)))\n\(stages)\ndebts: \(state.debts ?? [])\n\(trace)")
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
    /// the binder are copied as they are at that moment, and put back once `body` is done, so nothing written after
    /// that save survives. True when that save was reached.
    func kill(_ s: PSetup, _ m: Model, afterSave n: Int, _ body: () -> Void) throws -> Bool {
        let snapshot = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-killed-\(UUID().uuidString)")
        let places = self.places(s)
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
        let places = self.places(s)
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

    func places(_ s: PSetup) -> [URL] {
        [s.support, s.folder, s.folder.deletingLastPathComponent().appendingPathComponent(s.folder.lastPathComponent + ".away")]
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

    /// The binder's folder moves out of reach (a volume disconnected) or back. While it is away no invariant is
    /// checked, since the binder cannot be read; once it is back, the next clean sweep must leave all three holding.
    func toggleAway(_ s: PSetup, _ m: Model) throws {
        let away = s.folder.deletingLastPathComponent().appendingPathComponent(s.folder.lastPathComponent + ".away")
        if m.away { try FileManager.default.moveItem(at: away, to: s.folder) } else { try FileManager.default.moveItem(at: s.folder, to: away) }
        m.away.toggle()
        m.log.append(m.away ? "binder away" : "binder back")
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
        if m.unreadable != nil { toggleUnreadable(s, m, &rng) }
        if m.unwritable { toggleUnwritable(s, m) }
        if m.away { try toggleAway(s, m) }
        // Whatever happened, two clean sweeps settle everything.
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        m.log.append("final sweeps")
        check(s, m, seed: seed)
    }

    @Test(arguments: [UInt64(1520), 1903, 2109, 2340])
    func randomSequencesKeepEveryCaptureAccountedFor(seed: UInt64) async throws {
        try await run(seed: seed, steps: 120)
    }
}

extension InboxSequenceTests.Rng: RandomNumberGenerator {}

import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// One gate for every withdrawal of a capture's waiting card: a correction's, a retraction's, the work a binder missed
// while away, and the clerk's hand-off (capture-event-v0 §3.2, §6.5). A card goes only once every source span of every
// op on it, of whatever kind (an added item, an update, a completion, a drop, a status change, a redaction), and every
// line it lists as not filed yet, that is still in the chain's current words is carried: held by a card of those words
// that waits, that the person approved or declined, or listed on one as not filed yet. What nothing carries yet is
// carried first, by a card made where the withdrawn one waited; when that card cannot be made, nothing is withdrawn.
// An op that names no span holds no line: a correction's own change to a filed item, which the next correction works
// out again from the item itself, and a retraction's or a raise's card, which names the whole chain.
extension CaptureInbox {
    /// The words a chain stands for now: the event that holds them, its lines, every event of the chain with the same
    /// words, and whether the chain is private.
    struct Words {
        let id: String
        let lines: [(text: String, start: Int, end: Int)]
        let events: Set<String>
        let chain: Set<String>
        let isPrivate: Bool
    }

    /// What one op holds of a line of the current words: the line, and what it does there ("add", or the op and the
    /// item it changes).
    struct Held: Hashable {
        let line: Int
        let what: String
    }

    /// What the cards of the current words already carry: ops by line and kind, and whole lines (listed as not filed
    /// yet, or read whole by the code, whose reading the clerk takes up again).
    struct Carried {
        var held: Set<Held> = []
        var lines: Set<Int> = []
        func covers(_ h: Held) -> Bool { lines.contains(h.line) || held.contains(h) }
        func touches(_ line: Int) -> Bool { lines.contains(line) || held.contains { $0.line == line } }
    }

    /// Where a span of an earlier event is in the current words: on a line (the same words, or changed ones, with the
    /// span's offsets there), on no line any more, or not known (its event's words cannot be read).
    enum SpanFate { case live(line: Int, same: Bool, start: Int, end: Int), removed, unknown }

    /// Why the withdrawn cards may go: what they hold is checked against the chain's current words and carried (nil
    /// words: the chain stands for no words now, so nothing is owed), or the same words are read again (the clerk's
    /// cards in place of the code-built one, or the code-built card that stays in place of the clerk's).
    enum Replacement {
        case carried(Words?)
        case sameReading
    }

    /// The reasons Sprava gives when it withdraws a card itself: a card rejected for any other reason was declined by
    /// the person, and what it held is theirs.
    static let withdrawnBySprava: Set<String> = [
        "replaced by a corrected note", "the note was deleted where it was taken", "replaced by the clerk's reading", takenBack,
        "its digest could not be kept", "it could not be moved from the Inbox",
    ]

    /// `id`'s words as a chain's current ones (`text` when given, else read from the capture folder); nil when they
    /// cannot be read.
    func words(_ id: String, text: String? = nil, chain: [String], state: State) -> Words? {
        guard let text = text ?? storedText(id, paths: state.paths ?? [:]) else { return nil }
        let hash = state.texts?[id]
        let same = Set(chain.filter { hash != nil && state.texts?[$0] == hash }).union([id])
        return Words(id: id, lines: Self.lines(of: text), events: same, chain: Set(chain + [id]),
                     isPrivate: !Set(state.privates ?? []).isDisjoint(with: Set(chain + [id])))
    }

    /// The words a chain stands for now, as the cursor has it: `.carried(nil)` when it stands for none (retracted, or
    /// nothing held yet), nil when they cannot be read.
    func currentWords(_ chain: [String], state: State) -> Replacement? {
        guard let newest = Self.standing(chain, state: state), !["retracted", "retracting"].contains(state.ingested[newest] ?? "") else {
            return .carried(nil)
        }
        return words(newest, chain: chain, state: state).map { .carried($0) }
    }

    /// The words that stand after a retraction: those of the newest event after it that holds words, if any (a
    /// restore taken in before an older retraction was finished); none otherwise.
    func wordsAfter(_ retraction: String, state: State) -> Replacement? {
        let chain = state.chainsByKey?.values.first { $0.contains(retraction) } ?? []
        let later = chain.filter { Self.rank($0, state: state) > Self.rank(retraction, state: state) }
        return later.isEmpty ? .carried(nil) : currentWords(later, state: state)
    }

    /// What an op does, as carried: "add", or the op with the item it changes.
    static func what(_ op: JSONObject) -> String {
        let name = op["op"]?.stringValue ?? ""
        return name == "add_item" ? "add" : name + ":" + (op["args"]?["id"].map(canonicalText) ?? "")
    }

    /// Where `span` of event `event`'s words is in `words`. Lines of earlier events follow the line diff.
    func fate(of span: JSONValue, event: String, in words: Words, state: State,
              cache: inout [String: ([(text: String, start: Int, end: Int)], [LineFate])?]) -> SpanFate {
        guard let start = span["start"]?.numberValue?.safeInteger.map(Int.init),
              let end = span["end"]?.numberValue?.safeInteger.map(Int.init) else { return .removed }
        let lines: [(text: String, start: Int, end: Int)], fates: [LineFate]
        if words.events.contains(event) {
            lines = words.lines
            fates = words.lines.indices.map { .same($0) }
        } else {
            if cache[event] == nil {
                cache[event] = .some(storedText(event, paths: state.paths ?? [:]).map { text in
                    let old = Self.lines(of: text)
                    return (old, Self.diffLines(old.map(\.text), words.lines.map(\.text)).fates)
                })
            }
            guard let known = cache[event] ?? nil else { return .unknown }
            (lines, fates) = known
        }
        // A span that starts between lines is on the line it reaches first.
        guard let k = lines.firstIndex(where: { start < $0.end && end > $0.start }) ?? lines.firstIndex(where: { start < $0.end }),
              k < fates.count else { return .removed }
        switch fates[k] {
        case .removed:
            return .removed
        case .changed(let j):
            return .live(line: j, same: false, start: words.lines[j].start, end: words.lines[j].end)
        case .same(let j):
            let shift = words.lines[j].start - lines[k].start
            return .live(line: j, same: true, start: max(start + shift, words.lines[j].start), end: min(end + shift, words.lines[j].end))
        }
    }

    /// The one event a card was made from; nil for a card of several (a retraction's or a raise's), which holds no
    /// line of its own.
    static func sourceEvent(_ p: Proposal) -> String? {
        let events = p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
        return events.count == 1 ? events[0] : nil
    }

    /// What the cards of the current words in `places` carry, leaving out `excluding` (the cards being withdrawn), and
    /// the items already filed from the chain: an item filed from a line still in the current words is that line's
    /// item, so an add of it is carried (a change to it is the correction's to propose).
    func carried(by words: Words, places: [URL?], excluding: Set<String>, state: State, commands: Commands,
                 cache: inout [String: ([(text: String, start: Int, end: Int)], [LineFate])?]) -> Carried {
        var out = Carried()
        for folder in places.compactMap({ $0 }) {
            for o in Teka.read(folder).items.compactMap(\.object) {
                guard let from = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue).first(where: words.chain.contains) else { continue }
                if let span = o["provenance"]?["span"], case .live(let j, true, _, _) = fate(of: span, event: from, in: words, state: state, cache: &cache) {
                    out.held.insert(Held(line: j, what: "add"))
                } else if let title = o["title"]?.stringValue, let j = words.lines.firstIndex(where: { String($0.text.prefix(200)) == title }) {
                    out.held.insert(Held(line: j, what: "add"))
                }
            }
        }
        for place in places {
            // A waiting card counts only as Sprava wrote it: one another program changed covers nothing (architecture
            // 4.6). The Inbox lists only cards whose digest it kept.
            let cards = place.map { folder in
                ProposalStore.list(in: folder).map(\.0).compactMap { p in p.state == "proposed" ? try? commands.loadTrusted(p.id, in: folder) : p }
            } ?? unfiled()
            for p in cards where !excluding.contains(p.id) {
                guard let event = Self.sourceEvent(p), words.events.contains(event) else { continue }
                let counts = place == nil || p.state == "proposed" || p.state == "applied"
                    || (p.state == "rejected" && !Self.withdrawnBySprava.contains(p.raw["rejected_reason"]?.stringValue ?? ""))
                guard counts else { continue }
                func line(_ span: JSONValue) -> Int? {
                    guard let start = span["start"]?.numberValue?.safeInteger.map(Int.init),
                          let end = span["end"]?.numberValue?.safeInteger.map(Int.init) else { return nil }
                    return words.lines.firstIndex { start < $0.end && end > $0.start }
                }
                // The code's own reading of the words (one item per line, the rest listed): the clerk reads them again.
                let reading = p.raw["provenance"]?["filed_by"] == .str("code, no model") && p.raw["provenance"]?["supersedes"]?.arrayValue == nil
                    && p.raw["provenance"]?["carried_from"] == nil && p.ops.allSatisfy { $0["op"] == .str("add_item") }
                for op in p.ops {
                    for span in op["spans"]?.arrayValue ?? [] {
                        guard let j = line(span) else { continue }
                        if reading { out.lines.insert(j) } else { out.held.insert(Held(line: j, what: Self.what(op))) }
                        // An item given the line as its title is that line's item: an add of the line is carried.
                        if op["op"] == .str("update_item"), op["args"]?["set"]?["title"] != nil { out.held.insert(Held(line: j, what: "add")) }
                    }
                }
                for span in p.raw["provenance"]?["unfiled"]?.arrayValue ?? [] { if let j = line(span) { out.lines.insert(j) } }
            }
        }
        return out
    }

    /// What of card `p` is still owed and not carried yet, as ops and lines for a card that carries it: an op whose
    /// lines are all unchanged is kept as it is (its spans moved to the current words); an added item whose line
    /// changed is proposed again from the line's new words; any other change whose line changed is listed as not filed
    /// yet, for the person to see in the note's own words. A kept op keeps what the card assumed about the item it
    /// changes (its `expect` fingerprint), so a change approved since still stops it for a look (architecture 4.6).
    /// Nil when what it holds cannot be told.
    func carry(_ p: Proposal, words: Words, covered: inout Carried, state: State, actor: JSONObject, numbered: inout Int,
               cache: inout [String: ([(text: String, start: Int, end: Int)], [LineFate])?])
        -> (ops: [JSONObject], unfiled: [(Int, String)], expect: [(String, JSONValue)])? {
        let own = Self.sourceEvent(p)
        var ops: [JSONObject] = []
        var expect: [(String, JSONValue)] = []
        var listed: [(Int, String)] = []
        func span(_ line: Int, _ start: Int, _ end: Int) -> JSONValue {
            .obj([("event", .string(words.id)), ("start", .int(start)), ("end", .int(end))])
        }
        for op in p.ops {
            var live: [(line: Int, same: Bool, start: Int, end: Int)] = []
            for s in op["spans"]?.arrayValue ?? [] {
                guard let event = s["event"]?.stringValue ?? own else { return nil }
                switch fate(of: s, event: event, in: words, state: state, cache: &cache) {
                case .unknown: return nil
                case .removed: continue
                case .live(let line, let same, let start, let end): live.append((line, same, start, end))
                }
            }
            let what = Self.what(op)
            let need = live.filter { !covered.covers(Held(line: $0.line, what: what)) }
            guard !need.isEmpty else { continue }
            if live.allSatisfy(\.same) {
                var o = op
                o.set("spans", .array(live.map { span($0.line, $0.start, $0.end) }))
                if op["op"] == .str("add_item"), var args = op["args"]?.objectValue, var item = args["item"]?.objectValue {
                    numbered += 1
                    item.set("id", .string("$new:\(numbered)"))
                    var prov = item["provenance"]?.objectValue ?? JSONObject()
                    prov.set("events", .array([.string(words.id)]))
                    if prov["span"] != nil { prov.set("span", .obj([("start", .int(live[0].start)), ("end", .int(live[0].end))])) }
                    item.set("provenance", .object(prov))
                    args.set("item", .object(item))
                    o.set("args", .object(args))
                }
                ops.append(o)
                if let id = op["args"]?["id"], op["op"] != .str("add_item"), let key = try? Canonical.serialize(id) {
                    expect += (p.raw["expect"]?.objectValue?.entries ?? []).filter { $0.key == key || $0.key.hasSuffix(":" + key) }.map { ($0.key, $0.value) }
                }
                for l in live { covered.held.insert(Held(line: l.line, what: what)) }
            } else if op["op"] == .str("add_item") {
                for l in need where !covered.covers(Held(line: l.line, what: "add")) {
                    let line = words.lines[l.line]
                    numbered += 1
                    var item = JSONObject()
                    item.set("id", .string("$new:\(numbered)"))
                    item.set("title", .string(String(line.text.prefix(200))))
                    item.set("status", .str("open"))
                    item.set("priority", .str("normal"))
                    item.set("no_deadline", .bool(true))
                    item.set("provenance", .obj([("events", .array([.string(words.id)])), ("proposed_by", .object(actor)),
                                                 ("span", .obj([("start", .int(line.start)), ("end", .int(line.end))]))]))
                    ops.append(JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))])),
                                           (key: "spans", value: .array([span(l.line, line.start, line.end)]))]))
                    covered.held.insert(Held(line: l.line, what: "add"))
                }
            } else {
                for l in need where !covered.lines.contains(l.line) {
                    listed.append((l.line, "changed_since_read"))
                    covered.lines.insert(l.line)
                }
            }
        }
        if let own {
            for s in p.raw["provenance"]?["unfiled"]?.arrayValue ?? [] {
                switch fate(of: s, event: own, in: words, state: state, cache: &cache) {
                case .unknown: return nil
                case .removed: continue
                case .live(let line, _, _, _):
                    guard !covered.touches(line) else { continue }
                    listed.append((line, s["reason"]?.stringValue ?? "more_lines"))
                    covered.lines.insert(line)
                }
            }
        }
        return (ops, listed, expect)
    }

    /// Withdraws `cards` (each in its binder, or the Inbox when nil), once what they hold is carried (`replacement`).
    /// The cards of one place whose content cannot be told, or whose carrying card cannot be made, stay. True once
    /// every card is gone.
    @discardableResult
    func withdraw(_ cards: [(URL?, Proposal)], reason: String, replacement: Replacement, state: State? = nil, binders: [ShelfRow],
                  commands: Commands, now: Date) -> Bool {
        guard !cards.isEmpty else { return true }
        var complete = true
        var going = cards
        if case .carried(let current) = replacement, let words = current {
            let state = state ?? loadState()
            let rows = knownRows(binders, commands: commands).filter {
                $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID && Self.cardsReadable(in: ProposalStore.dir($0.folder))
            }
            var cache: [String: ([(text: String, start: Int, end: Int)], [LineFate])?] = [:]
            var covered = carried(by: words, places: [nil] + rows.map(\.folder), excluding: Set(cards.map(\.1.id)), state: state, commands: commands, cache: &cache)
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
            var places: [URL?] = []
            for (place, _) in cards where !places.contains(place) { places.append(place) }
            for place in places {
                // A binder's card is read as Sprava wrote it: one another program changed is never copied into a card
                // Sprava trusts, so what it holds cannot be told and it stays, with the work owed (architecture 4.6).
                var here: [Proposal] = []
                var known = true
                for (at, p) in cards where at == place {
                    guard let folder = place else { here.append(p); continue }
                    guard let trusted = try? commands.loadTrusted(p.id, in: folder) else { known = false; break }
                    here.append(trusted)
                }
                var ops: [JSONObject] = []
                var listed: [(Int, String)] = []
                var expect: [(String, JSONValue)] = []
                var numbered = 0
                for p in here where known {
                    guard let c = carry(p, words: words, covered: &covered, state: state, actor: actor, numbered: &numbered, cache: &cache) else {
                        known = false
                        break
                    }
                    ops += c.ops
                    listed += c.unfiled
                    expect += c.expect
                }
                let carriedOver = known && (ops.isEmpty && listed.isEmpty || saveCarry(ops: ops, listed: listed, expect: expect, from: here, words: words,
                                                                                         in: place, actor: actor, commands: commands, now: now))
                if !carriedOver {
                    journal([("event", .string(words.id)), ("stage", .str(known ? "carry_failed" : "carry_unknown")), ("cards", .int(here.count))])
                    let held = Set(cards.filter { $0.0 == place }.map(\.1.id))
                    going.removeAll { held.contains($0.1.id) }
                    complete = false
                }
            }
        }
        for (folder, p) in going where !giveWay(p, in: folder, reason: reason, deviceID: commands.deviceID, now: now) { complete = false }
        return complete
    }

    /// Saves the card that carries what withdrawn cards still held, where they waited (the Inbox for an Inbox card),
    /// trusted; false when it cannot be. Its `expect` is what the withdrawn cards assumed about the items their kept
    /// ops change, not the items as they are now; two withdrawn cards that assumed different things leave a mark that
    /// matches no item, so the card is stopped for a look.
    func saveCarry(ops: [JSONObject], listed: [(Int, String)], expect: [(String, JSONValue)], from: [Proposal], words: Words, in folder: URL?,
                   actor: JSONObject, commands: Commands, now: Date) -> Bool {
        var provenance = JSONObject([(key: "events", value: .array([.string(words.id)])), (key: "filed_by", value: .str("code, no model")),
                                     (key: "carried_from", value: .array(from.map { .string($0.id) }))])
        if !listed.isEmpty {
            provenance.set("unfiled", .array(listed.sorted { $0.0 < $1.0 }.map { line, reason in
                .obj([("start", .int(words.lines[line].start)), ("end", .int(words.lines[line].end)), ("reason", .string(reason))])
            }))
        }
        if from.contains(where: { $0.raw["provenance"]?["unverified_source"] == .bool(true) }) { provenance.set("unverified_source", .bool(true)) }
        let title = ops.isEmpty ? "A note was corrected. Lines still to look at" : "A note was corrected. What it still asks for"
        var card = Proposal.make(title: title, actor: actor, ops: ops, provenance: provenance, now: now)
        if words.isPrivate { card = Self.privateCopy(card, catalog: folder.map { Teka.read($0).catalog } ?? nil) }
        guard let folder else {
            var raw = card.raw
            raw.set("binder", .str("not sure"))
            return (try? writeUnfiled(raw)) != nil
        }
        var fingerprints = Proposal.fingerprints(card.ops, catalog: Teka.read(folder).catalog)
        var seen: [String: JSONValue] = [:]
        for (key, value) in expect {
            seen[key] = seen[key].map { $0 == value ? value : .str("assumed differently by the cards it carries") } ?? value
        }
        for (key, value) in seen { fingerprints.set(key, value) }
        var raw = card.raw
        raw.set("expect", .object(fingerprints))
        card = Proposal(raw: raw)
        guard (try? BinderWrite.save(card, in: folder, deviceID: commands.deviceID)) != nil else { return false }
        guard (try? commands.trustProposals([card.id], in: folder)) != nil else {
            BinderWrite.takeBackUntrusted(card, in: folder, deviceID: commands.deviceID, now: now)
            return false
        }
        return true
    }

    /// Takes one waiting card away: rejected in its binder with `reason`, or removed from the Inbox. Only `withdraw`
    /// calls it. True once it no longer waits. (A card Sprava saved but could never trust, so never approvable, is
    /// taken back where it was written; intake's document cards follow their files. Neither held a capture's lines
    /// for the person.)
    func giveWay(_ p: Proposal, in folder: URL?, reason: String, deviceID: String, now: Date) -> Bool {
        if let folder {
            guard let current = ProposalStore.list(in: folder).first(where: { $0.0.id == p.id })?.0, current.state == "proposed" else { return true }
            return (try? BinderWrite.reject(current, in: folder, reason: reason, deviceID: deviceID, now: now)) != nil
        }
        guard let file = unfiledFile(p.id) else { return true }
        return (try? FileManager.default.removeItem(at: file)) != nil || !FileManager.default.fileExists(atPath: file.path)
    }
}

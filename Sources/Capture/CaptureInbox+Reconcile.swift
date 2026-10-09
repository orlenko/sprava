import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// A binder that was out of reach when its chain was corrected (capture-event-v0 §3.2, §6.5): when it is back, the
// items already filed in it from the chain are set against the chain's current words, as the correction would have
// done with the binder there, and a card made meanwhile that adds those lines again gives way to that correction.
extension CaptureInbox {
    /// Reconciles the items filed in `row` from the chain whose current words are `words`: an item whose line changed
    /// (and whose title is still that line's words) gets the new line as its title, one whose line is gone is offered
    /// to drop (redacted first when the chain is private); an item whose line is unchanged, or cannot be identified, is
    /// left alone. A change already decided by a card of the current words (a correction made with the binder in
    /// reach, or this reconciliation before) is not made twice. Then a card of the current words that adds a line now
    /// held by one of these items again is withdrawn through the gate, which carries what else it held. True once
    /// done; false while something cannot be read or written, so the work stays owed.
    func reconcile(_ row: ShelfRow, words: Words, state: inout State, commands: Commands, now: Date) -> Bool {
        guard row.teka.isAdopted, !row.teka.writesBlocked, Owner.device(of: row.folder) == commands.deviceID else { return false }
        let folder = row.folder
        // What cards of the current words already decide about an item, as the person sees them.
        var decided = Set<String>()
        for p in ProposalStore.list(in: folder).map(\.0) {
            guard let e = Self.sourceEvent(p), words.events.contains(e), p.raw["provenance"]?["supersedes"]?.arrayValue != nil else { continue }
            let counts = p.state == "applied" || (p.state == "proposed" && commands.isTrusted(p.id, in: folder))
                || (p.state == "rejected" && !Self.withdrawnBySprava.contains(p.raw["rejected_reason"]?.stringValue ?? ""))
            guard counts else { continue }
            for op in p.ops { if let id = op["args"]?["id"] { decided.insert(canonicalText(id)) } }
        }
        var cache: [String: ([(text: String, start: Int, end: Int)], [LineFate])?] = [:]
        var texts: [String: [(text: String, start: Int, end: Int)]?] = [:]
        func lines(_ e: String) -> [(text: String, start: Int, end: Int)]? {
            if let known = texts[e] { return known }
            let found = storedText(e, paths: state.paths ?? [:]).map(Self.lines(of:))
            texts[e] = .some(found)
            return found
        }
        let closedAt = JSONValue.string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))
        var ops: [JSONObject] = []
        var placed = Set<Int>()
        var complete = true
        for o in row.teka.items.compactMap(\.object) {
            guard let from = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue).first(where: words.chain.contains),
                  let itemID = o["id"], !["done", "dropped"].contains(o["status"]?.stringValue ?? "") else { continue }
            let title = o["title"]?.stringValue ?? ""
            // The item's own line in the words it came from: its span, else its title as one whole line.
            guard let old = lines(from) else { complete = false; continue }
            var k: Int?
            if let start = o["provenance"]?["span"]?["start"]?.numberValue?.safeInteger {
                k = old.firstIndex { $0.start <= Int(start) && Int(start) < $0.end }
            }
            k = k ?? old.firstIndex { String($0.text.prefix(200)) == title }
            guard let k else { continue }
            let span = JSONValue.obj([("start", .int(old[k].start)), ("end", .int(old[k].end))])
            switch fate(of: span, event: from, in: words, state: state, cache: &cache) {
            case .unknown:
                complete = false
            case .removed:
                guard !decided.contains(canonicalText(itemID)) else { continue }
                if words.isPrivate, o["redact"] != .bool(true) {
                    var redact = JSONObject([(key: "redact", value: .bool(true))])
                    if o["kind"] == nil { redact.set("kind", .str("other")) }
                    ops.append(JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(redact))]))]))
                }
                ops.append(JSONObject([(key: "op", value: .str("drop")), (key: "args", value: .obj([
                    ("id", itemID), ("closed_at", closedAt), ("source", .str("capture"))]))]))
            case .live(let j, let same, _, _):
                placed.insert(j)
                let newTitle = String(words.lines[j].text.prefix(200))
                // Only words that are still the line's own are rewritten: a clerk's title is its own.
                guard !same, !decided.contains(canonicalText(itemID)), title == String(old[k].text.prefix(200)), newTitle != title else { continue }
                var set = JSONObject([(key: "title", value: .string(newTitle))])
                if words.isPrivate, o["redact"] != .bool(true) {
                    set.set("redact", .bool(true))
                    if o["kind"] == nil { set.set("kind", .str("other")) }
                }
                ops.append(JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(set))])),
                                       (key: "spans", value: .array([.obj([("event", .string(words.id)), ("start", .int(words.lines[j].start)),
                                                                            ("end", .int(words.lines[j].end))])]))]))
            }
        }
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
        if !ops.isEmpty {
            var provenance = JSONObject([(key: "events", value: .array([.string(words.id)])), (key: "supersedes", value: .array(words.chain.sorted().map(JSONValue.string))),
                                         (key: "filed_by", value: .str("code, no model")), (key: "reconciled", value: .bool(true))])
            if words.isPrivate { provenance.set("private", .bool(true)) }
            let card = Proposal.make(title: "A note was corrected while this binder was away. Change what was filed from it?", actor: actor, ops: ops,
                                     provenance: provenance, now: now)
            do {
                try BinderWrite.save(card, in: folder, deviceID: commands.deviceID)
                try commands.trustProposals([card.id], in: folder)
            } catch {
                BinderWrite.takeBackUntrusted(card, in: folder, deviceID: commands.deviceID, now: now)
                return false
            }
            journal([("event", .string(words.id)), ("stage", .str("reconciled")), ("ops", .int(ops.count))])
        }
        guard !placed.isEmpty else { return complete }
        // A card made while the binder was away that adds a line its item now holds again gives way; the gate carries
        // what else it held (the lines new in the correction).
        let rows = knownRows([row], commands: commands).filter {
            $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID && Self.cardsReadable(in: ProposalStore.dir($0.folder))
        }
        var again: [(URL?, Proposal)] = []
        for place in [nil] + rows.map(\.folder) as [URL?] {
            let cards = place.map { f in ProposalStore.list(in: f).map(\.0).filter { $0.state == "proposed" }.compactMap { try? commands.loadTrusted($0.id, in: f) } }
                ?? unfiled()
            for p in cards {
                guard let e = Self.sourceEvent(p), words.events.contains(e), p.raw["provenance"]?["supersedes"]?.arrayValue == nil,
                      p.raw["provenance"]?["carried_from"] == nil, p.raw["provenance"]?["retraction"] == nil, !Self.onlyRedacts(p) else { continue }
                let adds = p.ops.filter { $0["op"] == .str("add_item") }.flatMap { $0["spans"]?.arrayValue ?? [] }.compactMap { s -> Int? in
                    guard let start = s["start"]?.numberValue?.safeInteger, let end = s["end"]?.numberValue?.safeInteger else { return nil }
                    return words.lines.firstIndex { Int(start) < $0.end && Int(end) > $0.start }
                }
                if adds.contains(where: placed.contains) { again.append((place, p)) }
            }
        }
        guard !again.isEmpty else { return complete }
        for (_, p) in again {
            if let e = Self.sourceEvent(p), ["pending", "retry"].contains(state.clerk?[e] ?? "") { state.clerk?[e] = "kept" }
        }
        let gone = withdraw(again, reason: "replaced by a corrected note", replacement: .carried(words), state: state, binders: [row],
                            commands: commands, now: now)
        return complete && gone
    }
}

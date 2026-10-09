import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// Change cards for a corrected note whose earlier version was already filed (capture-event-v0 §3.2, §6.5).
extension CaptureInbox {
    /// The text of an earlier event, read again from the capture folder; nil when it is gone or unreadable.
    func storedText(_ id: String, paths: [String: String]) -> String? {
        storedEvent(id, paths: paths)?["text"]?.stringValue
    }

    /// An earlier event as read again from the capture folder; nil when it is gone or unreadable.
    func storedEvent(_ id: String, paths: [String: String]) -> JSONValue? {
        guard let parts = paths[id]?.split(separator: "/").map(String.init), parts.count == 2,
              case .ok(let data) = SafeFile.read(root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])) else { return nil }
        return try? JSONParser.parse(data).value
    }

    /// Change cards for a corrected note whose earlier version was already filed (capture-event-v0 §3.2, §6.5).
    /// Each filed item is matched to its own source line: by its title when that is exactly one line of the current
    /// text, else by the span it carries, and followed line by line through the current text to the new one (each
    /// step a line diff). The item as filed is what is compared, so what an earlier correction still waiting would
    /// have changed is carried into this one before that card is withdrawn: an item whose title is still its line's
    /// words, as it came in or as the current text has it, gets the new line as its title when that differs (a
    /// clerk's title is its own words and stays); an item whose line is gone, now or in the current text, is offered to
    /// drop; and an item whose line cannot be identified is left alone. New lines, and lines whose waiting card this
    /// correction withdrew, are proposed once: in the binder of the item filed from the nearest line, else unfiled. At
    /// most ten lines become items; every other line to propose, and every line a withdrawn card listed as not filed
    /// yet, is listed on the new card as not filed yet, so no words are lost to the cap or to a withdrawal. A
    /// private correction redacts every item it touches; an unverified source is marked on every card (architecture 8).
    /// Returns (binder or nil for unfiled, card id) for each card saved; nil when nothing was filed from the chain.
    /// Throws when a card cannot be saved or trusted; the cards already made are found again on the retry.
    func correctionCards(_ event: CaptureEvent, chain: [String], current: String, withdrawn: [(URL?, Proposal)], paths: [String: String],
                         verified: Bool = true, binders: [ShelfRow], commands: Commands, now: Date) throws -> [(URL?, String)]? {
        let ids = Set(chain)
        let newLines = Self.lines(of: event.text)
        typealias Lines = [(text: String, start: Int, end: Int)]
        var linesCache: [String: Lines?] = [:]
        var toCurrent: [String: [LineFate]?] = [:]
        func lines(_ id: String) -> Lines? {
            if let cached = linesCache[id] { return cached }
            let found = storedText(id, paths: paths).map(Self.lines(of:))
            linesCache[id] = .some(found)
            return found
        }
        /// The line of `id`'s text that holds offset `start`.
        func line(of start: Int, in id: String) -> Int? {
            lines(id)?.firstIndex { $0.start <= start && start < $0.end }
        }
        // Lines move from the event an item came from to the current text, then from the current text to the new one.
        let currentLines = lines(current)
        let step = currentLines.map { Self.diffLines($0.map(\.text), newLines.map(\.text)) }
        /// The current text's line for line `k` of event `id`'s text; nil when an earlier correction removed it.
        func inCurrent(_ id: String, _ k: Int) -> Int? {
            if id == current { return k }
            if toCurrent[id] == nil {
                toCurrent[id] = .some(lines(id).flatMap { old in currentLines.map { Self.diffLines(old.map(\.text), $0.map(\.text)).fates } })
            }
            guard let fates = toCurrent[id] ?? nil, k < fates.count else { return nil }
            switch fates[k] {
            case .same(let c), .changed(let c): return c
            case .removed: return nil
            }
        }

        let rows = binders.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID }
        let filed = rows.map { row in
            (row.folder, row.teka.items.compactMap(\.object).filter { o in
                (o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []).contains(where: ids.contains)
            })
        }.filter { !$0.1.isEmpty }
        guard !filed.isEmpty else { return nil }

        let closedAt = JSONValue.string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))
        var ops: [URL: [JSONObject]] = [:]
        var placedAt: [Int: URL] = [:]   // new line -> a binder holding an item filed from it
        for (folder, items) in filed {
            for o in items {
                guard let itemID = o["id"] else { continue }
                let title = o["title"]?.stringValue ?? ""
                // The item's own line: its title in the current text, else its span in the text it came from.
                var source: (event: String, line: Int)?
                let matches = (currentLines ?? []).indices.filter { String(currentLines![$0].text.prefix(200)) == title }
                if matches.count == 1 {
                    source = (current, matches[0])
                } else if let start = o["provenance"]?["span"]?["start"]?.numberValue?.safeInteger,
                          let from = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue).first(where: ids.contains),
                          let k = line(of: Int(start), in: from) {
                    source = (from, k)
                }
                var set = JSONObject()
                var drop = false
                if let source, let from = lines(source.event), let currentText = currentLines, let fates = step?.fates {
                    if let c = inCurrent(source.event, source.line) {
                        switch fates[c] {
                        case .same(let j), .changed(let j):
                            placedAt[j] = placedAt[j] ?? folder
                            // Only words that are still the line's own are rewritten.
                            let newTitle = String(newLines[j].text.prefix(200))
                            let own = [from[source.line].text, currentText[c].text].map { String($0.prefix(200)) }
                            if own.contains(title), newTitle != title { set.set("title", .string(newTitle)) }
                        case .removed:
                            drop = true
                        }
                    } else {
                        drop = true   // a line an earlier correction removed stays removed: its card is withdrawn below
                    }
                }
                if drop {
                    // A private correction closes nothing in the clear: the closure keeps the item's title, and the hub
                    // shows it once more, so the redaction goes first in the same batch (capture-event-v0 §3.3).
                    if event.isPrivate, o["redact"] != .bool(true) {
                        var redact = JSONObject([(key: "redact", value: .bool(true))])
                        if o["kind"] == nil { redact.set("kind", .str("other")) }
                        ops[folder, default: []].append(JSONObject([(key: "op", value: .str("update_item")),
                                                                   (key: "args", value: .obj([("id", itemID), ("set", .object(redact))]))]))
                    }
                    ops[folder, default: []].append(JSONObject([(key: "op", value: .str("drop")), (key: "args", value: .obj([
                        ("id", itemID), ("closed_at", closedAt), ("source", .str("capture"))]))]))
                    continue
                }
                // A private correction's words are redacted as they land, and so is what it leaves in place (§3.3).
                if event.isPrivate, o["redact"] != .bool(true) {
                    set.set("redact", .bool(true))
                    if o["kind"] == nil { set.set("kind", .str("other")) }
                }
                guard !set.entries.isEmpty else { continue }
                ops[folder, default: []].append(JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(set))]))]))
            }
        }

        // Lines to propose: new ones, and those whose waiting card was withdrawn above, each once.
        var propose: [Int: URL?] = [:]
        for (folder, p) in withdrawn {
            for op in p.ops where op["op"] == .str("add_item") {
                guard let span = op["spans"]?.arrayValue?.first, let from = span["event"]?.stringValue, ids.contains(from),
                      let start = span["start"]?.numberValue?.safeInteger, let k = line(of: Int(start), in: from),
                      let c = inCurrent(from, k), let fates = step?.fates, c < fates.count else { continue }
                switch fates[c] {
                case .same(let j), .changed(let j):
                    // Back where it waited when that binder is this Mac's, else unfiled.
                    let back = folder.flatMap { f in rows.contains { $0.folder == f } ? f : nil }
                    if placedAt[j] == nil, propose[j] == nil { propose[j] = .some(back) }
                case .removed: break
                }
            }
        }
        for j in step?.added ?? [] where propose[j] == nil {
            let before = placedAt.keys.filter { $0 < j }.max(), after = placedAt.keys.filter { $0 > j }.min()
            propose[j] = .some(before.flatMap { placedAt[$0] } ?? after.flatMap { placedAt[$0] })
        }
        // Lines not filed yet: those a withdrawn card listed so (where that card waited), then the lines to propose past
        // the tenth. Each new line once, and never one that is filed or proposed.
        var notFiled: [Int: (target: URL?, reason: String)] = [:]
        for (folder, p) in withdrawn {
            guard let from = p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue).first(where: ids.contains),
                  let spans = p.raw["provenance"]?["unfiled"]?.arrayValue, let fates = step?.fates else { continue }
            for span in spans {
                guard let start = span["start"]?.numberValue?.safeInteger, let k = line(of: Int(start), in: from),
                      let c = inCurrent(from, k), c < fates.count else { continue }
                switch fates[c] {
                case .same(let j), .changed(let j):
                    let back = folder.flatMap { f in rows.contains { $0.folder == f } ? f : nil }
                    if placedAt[j] == nil, propose[j] == nil, notFiled[j] == nil {
                        notFiled[j] = (back, span["reason"]?.stringValue ?? "more_lines")
                    }
                case .removed: break
                }
            }
        }
        for j in propose.keys.sorted().dropFirst(10) { notFiled[j] = (propose[j]!, "more_lines") }
        func unfiledSpans(_ target: URL?) -> [JSONValue] {
            notFiled.keys.sorted().filter { notFiled[$0]!.target == target }.map { j in
                .obj([("start", .int(newLines[j].start)), ("end", .int(newLines[j].end)), ("reason", .string(notFiled[j]!.reason))])
            }
        }
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
        var adds: [URL?: [JSONObject]] = [:]
        for j in propose.keys.sorted().prefix(10) {
            let target = propose[j]!
            var item = JSONObject()
            item.set("id", .string("$new:\((adds[target]?.count ?? 0) + 1)"))
            item.set("title", .string(String(newLines[j].text.prefix(200))))
            item.set("status", .str("open"))
            item.set("priority", .str("normal"))
            item.set("no_deadline", .bool(true))
            if event.isPrivate {
                item.set("redact", .bool(true))
                item.set("kind", .str("other"))
            }
            item.set("provenance", .obj([("events", .array([.string(event.id)])), ("proposed_by", .object(actor)),
                                         ("span", .obj([("start", .int(newLines[j].start)), ("end", .int(newLines[j].end))]))]))
            let span = JSONValue.obj([("event", .string(event.id)), ("start", .int(newLines[j].start)), ("end", .int(newLines[j].end))])
            adds[target, default: []].append(JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))])),
                                                         (key: "spans", value: .array([span]))]))
        }

        var provenance = JSONObject([(key: "events", value: .array([.string(event.id)])), (key: "supersedes", value: .array(chain.map(JSONValue.string))),
                                     (key: "filed_by", value: .str("code, no model"))])
        if event.isPrivate { provenance.set("private", .bool(true)) }
        if !verified { provenance.set("unverified_source", .bool(true)) }
        func cardProvenance(_ target: URL?) -> JSONObject {
            var p = provenance
            let spans = unfiledSpans(target)
            if !spans.isEmpty { p.set("unfiled", .array(spans)) }
            return p
        }
        var made: [(URL?, String)] = []
        for folder in rows.map(\.folder) {
            let cardOps = (ops[folder] ?? []) + (adds[folder] ?? [])
            guard !cardOps.isEmpty || !unfiledSpans(folder).isEmpty else { continue }
            // A retry after a partial failure keeps the card this correction already made here, never a second one.
            if let kept = madeCorrection(event.id, in: folder, commands: commands) {
                made.append((folder, kept))
                continue
            }
            let card = Proposal.make(title: "A note was corrected. Change what was filed from it?", actor: actor, ops: cardOps,
                                     provenance: cardProvenance(folder), now: now)
            try ProposalStore.save(card, in: folder)
            do {
                try commands.trustProposals([card.id], in: folder)
            } catch {
                // A card whose digest was not kept could never be approved: it goes, and the correction is tried again.
                let written = ProposalStore.dir(folder).appendingPathComponent("\(card.id).json")
                if (try? FileManager.default.removeItem(at: written)) == nil {
                    try? TekaStore(folder: folder).reject(card, reason: "its digest could not be kept", now: now)
                }
                throw error
            }
            made.append((folder, card.id))
        }
        let unfiledOps = adds[nil] ?? []
        if !unfiledOps.isEmpty || !unfiledSpans(nil).isEmpty {
            if let kept = unfiled().first(where: { Self.isCorrection($0, of: event.id) }) {
                made.append((nil, kept.id))
            } else {
                let noun = event.raw["source"]?["kind"]?.stringValue == "dictation" ? "dictation" : "note"
                let title = unfiledOps.isEmpty ? "Corrected \(noun): lines not filed yet"
                    : "Corrected \(noun): add \(unfiledOps.count == 1 ? "a new line" : "\(unfiledOps.count) new lines")"
                var card = Proposal.make(title: title, actor: actor, ops: unfiledOps, provenance: cardProvenance(nil), now: now).raw
                card.set("binder", .str("not sure"))
                try writeUnfiled(card)
                made.append((nil, card["id"]?.stringValue ?? ""))
            }
        }
        return made
    }

    /// A correction card of `event`: its only event, and it names what it supersedes.
    package static func isCorrection(_ p: Proposal, of event: String) -> Bool {
        p.raw["provenance"]?["events"] == .array([.string(event)]) && p.raw["provenance"]?["supersedes"] != nil
    }

    /// The correction card `event` already has in `folder`: one waiting as Sprava wrote it, or one the person
    /// approved; nil when there is none.
    func madeCorrection(_ event: String, in folder: URL, commands: Commands) -> String? {
        ProposalStore.list(in: folder).map(\.0).first { p in
            Self.isCorrection(p, of: event) && (p.state == "applied" || (p.state == "proposed" && commands.isTrusted(p.id, in: folder)))
        }?.id
    }
}

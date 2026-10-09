import BinderFormat
import BinderStore
import Foundation
import SpravaKit

/// Proposals (capture-event-v0 §6.5): the checked items become ops, one card per binder.
extension Clerk {
    public static let confidence: [String: Double] = ["high": 0.9, "medium": 0.75, "low": 0.5]

    /// One proposal per binder, plus one "not sure" proposal for the rest. Returned as (binder name or nil, proposal).
    public static func proposals(_ interp: Interpretation, event: ClerkInput, today: CalendarDate, client: String,
                                 now: Date = Date()) -> [(String?, Proposal)] {
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(client)), (key: "model", value: .string(interp.model))])
        var groups: [String?: [ClerkItem]] = [:]
        var order: [String?] = []
        for item in interp.items {
            if groups[item.binder] == nil { order.append(item.binder) }
            groups[item.binder, default: []].append(item)
        }
        if groups[nil] == nil, !interp.unfiled.isEmpty { order.append(nil); groups[nil] = [] }
        let noun = event.sourceKind == "dictation" ? "dictation" : "note"
        return order.map { binder in
            let items = groups[binder] ?? []
            let (ops, already, rejectedItems) = itemOps(items, event: event, today: today, actor: actor, interp: interp, now: now)
            var provenance = JSONObject([(key: "events", value: .array([.string(event.id)])), (key: "interpretation", value: .string(interp.id)),
                                         (key: "producer", value: .string(event.app)), (key: "tier", value: .str("1"))])
            if binder == nil, !interp.unfiled.isEmpty {
                provenance.set("unfiled", .array(interp.unfiled.map { .obj([("start", .int($0.span.start)), ("end", .int($0.span.end)),
                                                                            ("reason", .string($0.reason))]) }))
            }
            if interp.dropped > 0 { provenance.set("dropped_items", .int(interp.dropped)) }
            if !already.isEmpty { provenance.set("already_in_binder", .array(already.map(JSONValue.string))) }
            if !rejectedItems.isEmpty { provenance.set("left_out", .array(rejectedItems.map(JSONValue.string))) }
            if event.isPrivate { provenance.set("private", .bool(true)) }
            let band = items.map { confidence[$0.band] ?? 0.5 }.min() ?? 0.5
            let adds = ops.filter { $0["op"] == .str("add_item") }.count
            let title: String
            if ops.isEmpty {
                title = items.isEmpty ? "Parts of a \(noun) not filed yet" : !rejectedItems.isEmpty ? "To do by hand, from a \(noun)" : "Already in the binder"
            }
            else if ops.count == 1, adds == 1 { title = "Add \u{201C}\(ops[0]["args"]?["item"]?["title"]?.stringValue ?? "")\u{201D}" }
            else if adds == ops.count { title = "Add \(adds) items from a \(noun)" }
            else { title = ops.count == 1 ? "A change from a \(noun)" : "\(ops.count) changes from a \(noun)" }
            return (binder, Proposal.make(title: title, actor: actor, ops: ops, confidence: band, provenance: provenance, now: now))
        // A card with no ops stays when it tells the person something to do: unfiled parts, or items left out (a
        // recurring item to mark done by hand). One that only says "already in the binder" is left to the caller.
        }.filter { !($0.1.ops.isEmpty && $0.1.raw["provenance"]?["unfiled"] == nil && $0.1.raw["provenance"]?["left_out"] == nil) }
    }

    /// The ops for a group of checked items: new items, completions and changes; items already in the binder, and
    /// items the v0 rules refuse or a completion of a recurring item, are returned by title. New items are numbered
    /// from `firstNumber`.
    package static func itemOps(_ items: [ClerkItem], event: ClerkInput, today: CalendarDate, actor: JSONObject, interp: Interpretation,
                        now: Date, firstNumber: Int = 1) -> (ops: [JSONObject], already: [String], rejected: [String]) {
        var ops: [JSONObject] = []
        var already: [String] = []
        var rejectedItems: [String] = []
        var number = firstNumber - 1
        var joins: [String: Int] = [:]   // an existing item's key: the op a later sentence about it joins
        var completed: Set<String> = []
        func op(_ name: String, _ args: JSONObject) -> JSONObject {
            JSONObject([(key: "op", value: .string(name)), (key: "args", value: .object(args))])
        }
        for item in items {
            var relation = item.match?.relation
            var built: [JSONObject] = []
            if relation == "update", let candidate = item.match?.candidate {
                var set = JSONObject()
                let t = teka(item, number: 0, today: today, event: event, actor: actor, interp: interp)
                let startsWait = t["status"] == .str("waiting") && !["waiting", "blocked"].contains(candidate.status ?? "open")
                // Only what the sentence changes is written. A default the new item would derive (its follow-up) is
                // set only when the wait starts here; an item already waiting keeps the reminder it has (binder-v0 §5.3).
                let derived = Set(t["derived"]?.arrayValue?.compactMap(\.stringValue) ?? [])
                for key in ["due", "expected_by", "follow_up_at", "waiting_on"] where t[key] != nil && (startsWait || !derived.contains(key)) {
                    set.set(key, t[key]!)
                }
                if set.entries.isEmpty {
                    relation = "related"   // nothing to change: a new task beside the candidate, never an empty update
                } else {
                    // update_item may not change status, so a wait that starts on an open item is a set_status
                    // with its party and dates (binder-v0 §6.3); a date stays with update_item.
                    if startsWait {
                        var args = JSONObject([(key: "id", value: candidate.id), (key: "status", value: .str("waiting"))])
                        for key in ["waiting_on", "follow_up_at", "expected_by"] where t[key] != nil {
                            args.set(key, t[key]!)
                            set.remove(key)
                        }
                        if let derived = t["derived"] { args.set("derived", derived) }
                        built.append(op("set_status", args))
                    }
                    // What a private capture writes into an existing item is redacted with it (capture-event-v0 §3.3).
                    if event.isPrivate {
                        set.set("redact", .bool(true))
                        if candidate.kind == nil { set.set("kind", .str("other")) }
                    }
                    if !set.entries.isEmpty {
                        var args = JSONObject([(key: "id", value: candidate.id), (key: "set", value: .object(set))])
                        // A date replaces "no deadline" (binder-v0 §4.4: due XOR no_deadline).
                        if set["due"] != nil, candidate.noDeadline { args.set("unset", .array([.str("no_deadline")])) }
                        built.append(op("update_item", args))
                    }
                }
            }
            switch relation {
            case "same":
                if !already.contains(item.match!.candidate.title) { already.append(item.match!.candidate.title) }
                continue
            case "done" where item.match!.candidate.recurring:
                // A completion of a recurring item would need its next date, and the hub keeps those for now: the
                // person marks it done by hand, and the card says so (an op the binder refuses would block the card).
                if !rejectedItems.contains(item.title) { rejectedItems.append(item.title) }
                continue
            case "done":
                built = [op("complete", JSONObject([(key: "id", value: item.match!.candidate.id),
                                                    (key: "closed_at", value: .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))),
                                                    (key: "source", value: .str("capture"))]))]
            case "update":
                break
            default:
                let new = teka(item, number: number + 1, today: today, event: event, actor: actor, interp: interp)
                // Every built item is checked against the v0 rules before the card is stored (CI-14).
                var probe = new
                probe.set("id", .str("probe-1"))
                let problems = ItemRules.check(items: [.object(probe)], log: [], v0: true)
                if !problems.isEmpty {
                    rejectedItems.append(item.title)
                    continue
                }
                number += 1
                built = [op("add_item", JSONObject([(key: "item", value: .object(new))]))]
            }
            let span = JSONValue.obj([("event", .string(event.id)), ("start", .int(item.sentence.start)), ("end", .int(item.sentence.end))])
            // One existing item gets one change: a second sentence about it ("Paid the permit fee. The permit fee is
            // paid.") adds its span to the change already built, since a second completion would find the item gone
            // and block the whole card. A completion after an update still follows it; the first update wins.
            if let key = item.match?.candidate.key, relation == "done" || relation == "update" {
                if let i = joins[key], relation == "update" || completed.contains(key) {
                    ops[i].set("spans", .array((ops[i]["spans"]?.arrayValue ?? []) + [span]))
                    var card = ops[i]["card"]?.objectValue ?? JSONObject()
                    let flag = JSONValue.str("another sentence speaks of the same item")
                    if card["flags"]?.arrayValue?.contains(flag) != true { card.set("flags", .array((card["flags"]?.arrayValue ?? []) + [flag])) }
                    ops[i].set("card", .object(card))
                    continue
                }
                joins[key] = ops.count
                if relation == "done" { completed.insert(key) }
            }
            for var o in built {
                if let amount = item.amountText { o.set("note", .string(amount)) }
                o.set("confidence", .number(JSONNumber(text: String(format: "%.2f", confidence[item.band] ?? 0.5))))
                o.set("spans", .array([span]))
                var card = JSONObject()
                if let m = item.match, relation == "related" { card.set("related", .string(m.candidate.title)) }
                card.set("signals", .array(item.signals.map(JSONValue.string)))
                card.set("band", .string(item.band))
                if let g = item.guess, item.binder == nil { card.set("guess", .string(g)) }
                if !item.flags.isEmpty { card.set("flags", .array(item.flags.map(JSONValue.string))) }
                if let w = item.whenText, item.whenResolved == nil { card.set("when_text", .string(w)) }
                o.set("card", .object(card))
                ops.append(o)
            }
        }
        return (ops, already, rejectedItems)
    }

    /// The binder item for one clerk item (capture-event-v0 §6.5).
    static func teka(_ item: ClerkItem, number: Int, today: CalendarDate, event: ClerkInput, actor: JSONObject, interp: Interpretation) -> JSONObject {
        var o = JSONObject()
        o.set("id", .string("$new:\(number)"))
        o.set("title", .string(item.title))
        let waiting = item.action == "wait" && !item.people.isEmpty
        o.set("status", .string(waiting ? "waiting" : "open"))
        o.set("priority", .str("normal"))
        if waiting { o.set("waiting_on", .string(item.people[0])) }
        var derived: [String] = []
        if let d = item.whenResolved {
            switch item.whenRole ?? .due {
            case .due: o.set("due", .string(d.description))
            case .expected: o.set(waiting ? "expected_by" : "due", .string(d.description))
            case .follow_up: o.set(waiting ? "follow_up_at" : "due", .string(d.description))
            }
        }
        if waiting, o["follow_up_at"] == nil {
            let base = o["expected_by"]?.stringValue.flatMap(CalendarDate.strict).map { $0.checkedAdding(days: 1) ?? $0 } ?? today.adding(days: 7)
            var follow = base
            if let due = o["due"]?.stringValue.flatMap(CalendarDate.strict), due < follow { follow = due }
            if follow < today { follow = today }
            o.set("follow_up_at", .string(follow.description))
            derived.append("follow_up_at")
        }
        if o["due"] == nil { o.set("no_deadline", .bool(true)) }   // due XOR no_deadline, waiting items too (binder-v0 §4.4)
        let kind: String
        switch item.action {
        case "pay": kind = "payment"
        case "file": kind = "filing"
        case "meet": kind = "appointment"
        case "decide": kind = "decision"
        case "send" where !item.people.isEmpty: kind = "reply-owed"
        case "wait" where ["report", "draft", "statement", "rapport", "relevé"].contains(where: { item.sentence.text.lowercased().contains($0) }): kind = "document-request"
        default: kind = "other"
        }
        o.set("kind", .string(kind))
        if event.isPrivate { o.set("redact", .bool(true)) }
        if !derived.isEmpty { o.set("derived", .array(derived.map(JSONValue.string))) }
        // The item keeps its sentence's span, so a correction of the note finds the item's own line (§6.5).
        o.set("provenance", .obj([("events", .array([.string(event.id)])), ("interpretation", .string(interp.id)), ("proposed_by", .object(actor)),
                                  ("span", .obj([("start", .int(item.sentence.start)), ("end", .int(item.sentence.end))]))]))
        return o
    }
}

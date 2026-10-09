import BinderFormat
import BinderStore
import Clerk
import Foundation
import Shelf
import SpravaKit

// The hand-off to the clerk: its queue, and the cards it keeps in place of the code-built one (architecture 3.4,
// 5.3, 8).
extension CaptureInbox {
    public struct ClerkWork: Sendable {
        public let event: CaptureEvent
        public let hint: String?
        package let tier0: String
        package let tier0Binder: String?
    }

    /// Picks the oldest capture waiting for the clerk whose code-built card is still untouched, and records the
    /// attempt before any model call (the poison rule: two unfinished attempts and the capture keeps its card).
    public func nextForClerk() -> ClerkWork? {
        guard var state = try? readState() else { return nil }
        var clerk = state.clerk ?? [:]
        var attempts = state.attempts ?? [:]
        defer {
            state.clerk = clerk
            state.attempts = attempts
            try? save(state)
        }
        for id in clerk.filter({ $0.value == "pending" || $0.value == "retry" }).keys.sorted() {
            // A hand-off cut short is settled by the sweep first (`settleHandoffs`); no new reading is made meanwhile.
            if state.handoffs?[id] != nil { continue }
            guard let card = state.cards[id], let path = state.paths?[id] else { clerk[id] = "kept"; continue }
            let binder = state.cardBinder?[id]
            if !tier0Pending(card, binder: binder) { clerk[id] = "acted"; continue }
            if attempts[id, default: 0] >= 2 {
                let failed = clerk[id] == "retry"
                clerk[id] = failed ? "failed" : "poison"
                journal([("event", .string(id)), ("stage", .str("clerk_set_aside")),
                         ("reason", .str(failed ? "the clerk could not read this" : "crashed the clerk twice"))])
                continue
            }
            let parts = path.split(separator: "/").map(String.init)
            let device = root.appendingPathComponent(parts[0], isDirectory: true)
            guard parts.count == 2, case (.complete(.capture), let event?) = CaptureEvent.check(device.appendingPathComponent(parts[1]), deviceFolder: device)
            else { clerk[id] = "kept"; continue }
            attempts[id, default: 0] += 1
            // The attempt is on disk before any model call, or there is no call this run (the poison rule).
            state.clerk = clerk
            state.attempts = attempts
            guard (try? save(state)) != nil else { return nil }
            journal([("event", .string(id)), ("stage", .str("clerk_attempt")), ("n", .int(attempts[id]!))])
            return ClerkWork(event: Self.asFiled(event, privates: Set(state.privates ?? [])), hint: state.hints?[id], tier0: card, tier0Binder: binder)
        }
        return nil
    }

    func tier0Pending(_ card: String, binder: String?) -> Bool {
        tier0Card(card, binder: binder) != nil
    }

    /// The code-built card while it still waits: in its binder, or in the Inbox.
    func tier0Card(_ card: String, binder: String?) -> Proposal? {
        if let binder {
            return ProposalStore.list(in: URL(fileURLWithPath: binder, isDirectory: true)).map(\.0).first { $0.id == card && $0.state == "proposed" }
        }
        return unfiled().first { $0.id == card }
    }

    public struct ClerkOutcome: Equatable, Sendable {
        public var items = 0
        public var filed = 0
        public var unsure = 0
        public var replaced = false
    }

    /// Stores the clerk's cards and withdraws the code-built one, unless the person acted on it meanwhile.
    public func commitClerk(_ work: ClerkWork, _ interp: Interpretation, filing: [FilingBinder], rows: [ShelfRow],
                            commands: Commands, seconds: Double, now: Date = Date()) -> ClerkOutcome {
        var outcome = ClerkOutcome()
        // A cursor that cannot be read is never saved over: nothing to do this time.
        guard var state = try? readState() else { return outcome }
        var clerk = state.clerk ?? [:]
        defer {
            state.clerk = clerk
            try? save(state)
        }
        let id = work.event.id
        guard state.handoffs?[id] == nil else { return outcome }
        guard ["pending", "retry"].contains(clerk[id] ?? ""), tier0Pending(work.tier0, binder: work.tier0Binder) else {
            if clerk[id] == "pending" || clerk[id] == "retry" { clerk[id] = "acted" }
            return outcome
        }
        func log(_ stage: String) {
            journal([("event", .string(id)), ("stage", .string(stage)), ("outcome", .string(interp.outcome)), ("items", .int(interp.items.count)),
                     ("filed", .int(outcome.filed)), ("not_sure", .int(outcome.unsure)), ("dropped", .int(interp.dropped)),
                     ("unfiled_spans", .int(interp.unfiled.count)), ("calls", .int(interp.calls)), ("ms", .int(Int(seconds * 1000)))])
        }
        // The interpretation the cards will name is on disk first (decisions.md C3); if it cannot be written, the
        // code-built card stays and the reading is tried again.
        do {
            try AtomicFile.makePrivateFolder(dir.appendingPathComponent("interpretations", isDirectory: true))
            try AtomicFile.write(Data(JSONWriter.pretty(.object(Self.record(interp))).utf8),
                                 to: dir.appendingPathComponent("interpretations/\(id).json"))
        } catch {
            clerk[id] = "retry"
            log("clerk_write_failed")
            return outcome
        }
        outcome.items = interp.items.count
        guard !interp.items.isEmpty else {
            // A model failure gets one more try under the background budget (architecture 3.4, 8); otherwise
            // the code-built card is the best there is.
            clerk[id] = interp.unfiled.contains(where: { ["invalid_output", "refused", "truncated"].contains($0.reason) }) ? "retry" : "kept"
            log("clerk")
            return outcome
        }
        // A raise to private that came while the clerk was reading holds for its cards too (capture-event-v0 §3.2).
        let event = Self.asFiled(work.event, privates: Set(state.privates ?? []))
        let today = Clerk.captureDay(event.raw["captured_at"]?.stringValue ?? "") ?? CalendarDate.today(now: now)
        var cards = Clerk.proposals(interp, event: event, today: today, client: commands.client, now: now)
        // A source the code-built card marked unverified stays marked on every card that replaces it (architecture 8).
        if tier0Card(work.tier0, binder: work.tier0Binder)?.raw["provenance"]?["unverified_source"] == .bool(true) {
            cards = cards.map { binder, proposal in
                var raw = proposal.raw
                var provenance = raw["provenance"]?.objectValue ?? JSONObject()
                provenance.set("unverified_source", .bool(true))
                raw.set("provenance", .object(provenance))
                return (binder, Proposal(raw: raw))
            }
        }
        guard !cards.isEmpty else {
            // Everything the clerk read is already in the binder: the code-built card stays, saying so.
            clerk[id] = "kept"
            let already = interp.items.compactMap { $0.match?.relation == "same" ? $0.match?.candidate.title : nil }
            annotateTier0(work, already: already, commands: commands)
            log("clerk_already")
            return outcome
        }
        // A binder name resolves through the filing list (where a disclosure-none binder has only its label), else
        // to an adopted binder this Mac manages that is not at disclosure none, as the privacy ratchet reads it.
        let placed = cards.map { binder, proposal in
            (proposal, binder.flatMap { name in
                filing.first { $0.name == name }?.folder ?? rows.first {
                    $0.teka.isAdopted && $0.name == name && !$0.teka.writesBlocked && Owner.device(of: $0.folder) == commands.deviceID
                        && PrivacyRatchet.disclosure($0) != "none"
                }?.folder
            })
        }
        // The cards are named in the cursor before any is saved, so a hand-off cut short by a crash is settled by the
        // next sweep (`settleHandoffs`) and never made a second time; without that record nothing is saved.
        let planned = placed.map { State.Replacement(binder: $0.1?.path, card: $0.0.id) }
        state.handoffs = (state.handoffs ?? [:]).merging([id: planned]) { $1 }
        state.clerk = clerk
        guard (try? save(state)) != nil else {
            state.handoffs?[id] = nil
            log("clerk_write_failed")
            return outcome
        }
        // The cards are taken back when the hand-off fails; a record whose cards could not all be taken back stays
        // for the next sweep, so the clerk's cards never wait beside the code-built one.
        func giveUp(_ stage: String, next: String) -> ClerkOutcome {
            if takeBack(planned, now: now) { state.handoffs?[id] = nil }
            clerk[id] = next
            outcome = ClerkOutcome(items: outcome.items)
            log(stage)
            return outcome
        }
        // The "not sure" cards are written first, then the binders'.
        for (proposal, folder) in placed.filter({ $0.1 == nil }) + placed.filter({ $0.1 != nil }) {
            if let folder, (try? ProposalStore.save(proposal, in: folder)) != nil {
                // A card counts as made only once it is trusted: an untrusted one could never be approved, so
                // everything saved is taken back and the code-built card stays; the reading is tried again.
                guard (try? commands.trustProposals([proposal.id], in: folder)) != nil else {
                    return giveUp("clerk_trust_failed", next: (state.attempts?[id] ?? 0) >= 2 ? "kept" : "retry")
                }
                outcome.filed += proposal.ops.count
            } else {
                var raw = proposal.raw
                raw.set("binder", .str("not sure"))
                // The code-built card stays; nothing is lost.
                guard (try? writeUnfiled(raw)) != nil else { return giveUp("clerk_write_failed", next: "kept") }
                outcome.unsure += proposal.ops.count
            }
        }
        // The code-built card gives way to the clerk's reading; the reading counts as done only once it has. When it
        // cannot, or the person acted on it meanwhile, the clerk's cards are taken back instead.
        switch withdrawTier0(work.tier0, binder: work.tier0Binder, commands: commands, now: now) {
        case .withdrawn:
            break
        case .acted:
            return giveUp("clerk_acted", next: "acted")
        case .failed:
            return giveUp("clerk_withdraw_failed", next: (state.attempts?[id] ?? 0) >= 2 ? "kept" : "retry")
        }
        state.handoffs?[id] = nil
        outcome.replaced = true
        clerk[id] = "done"
        log("clerk")
        return outcome
    }

    /// Notes on the code-built card that the clerk found its items already in the binder.
    func annotateTier0(_ work: ClerkWork, already: [String], commands: Commands) {
        guard !already.isEmpty else { return }
        func annotated(_ p: Proposal) -> Proposal {
            var raw = p.raw
            var prov = raw["provenance"]?.objectValue ?? JSONObject()
            prov.set("already_in_binder", .array(already.map(JSONValue.string)))
            raw.set("provenance", .object(prov))
            return Proposal(raw: raw)
        }
        if let binder = work.tier0Binder {
            // A card another program changed since Sprava wrote it is left as it is, unverified (architecture 4.6).
            do { try commands.rewriteTrusted(work.tier0, in: URL(fileURLWithPath: binder, isDirectory: true), transform: annotated) }
            catch is ProposalStore.Tampered { journal([("event", .string(work.event.id)), ("stage", .str("card_changed_outside"))]) }
            catch {}
        } else if let p = unfiled().first(where: { $0.id == work.tier0 }) {
            try? writeUnfiled(annotated(p).raw)
        }
    }

    /// The interpretation as kept in Sprava's own capture store (decisions.md C3).
    public static func record(_ interp: Interpretation) -> JSONObject {
        var o = JSONObject()
        o.set("id", .string(interp.id))
        o.set("event", .string(interp.event))
        o.set("model", .string(interp.model))
        o.set("outcome", .string(interp.outcome))
        o.set("dropped_items", .int(interp.dropped))
        o.set("items", .array(interp.items.map { i in
            var item = JSONObject()
            item.set("title", .string(i.title))
            item.set("action", .string(i.action))
            item.set("source_span", .obj([("start", .int(i.sentence.start)), ("end", .int(i.sentence.end)), ("anchored", .bool(true))]))
            if let w = i.whenText { item.set("when_text", .string(w)) }
            if let r = i.whenRole { item.set("when_role", .string(r.rawValue)) }
            if let d = i.whenResolved { item.set("when_resolved", .string(d.description)) }
            item.set("people", .array(i.people.map(JSONValue.string)))
            if let a = i.amount { item.set("amount", .obj([("value", .number(JSONNumber(text: String(a.value)))), ("text", .string(i.amountText ?? ""))])) }
            item.set("binder_guess", .obj([("name", i.binder.map(JSONValue.string) ?? .null), ("signals", .array(i.signals.map(JSONValue.string))),
                                           ("confidence_band", .string(i.band))]))
            return .object(item)
        }))
        o.set("unfiled", .array(interp.unfiled.map { .obj([("start", .int($0.span.start)), ("end", .int($0.span.end)), ("reason", .string($0.reason))]) }))
        return o
    }
}

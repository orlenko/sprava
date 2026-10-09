import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// Raises to private: the cursor's record, and the cards rewritten and redacted (capture-event-v0 §3.2, §3.3).
extension CaptureInbox {
    // Two guarantees keep a private chain private, whatever the order of crashes, disconnects and retries:
    // - no card is approved in the clear: `cardForApproval` works out, from the cursor at that moment, whether the
    //   chains a card comes from are private, and redacts or refuses it;
    // - every item a private chain made or changed is offered for redaction: the chain owes a privacy debt (`debts`,
    //   by chain key) from the save that first holds the raise, cleared only by one complete pass with every binder
    //   in reach and every card readable (`payDebt`); `settle` pays it in a binder before an approval there.
    // Rewriting the cards that wait is a convenience on top: a card missed there is redacted at approval.

    /// A raise to private for event `id` and the chain `chain` (key `key`): the events are marked private and the
    /// chain owes a privacy debt, in the cursor, before anything is saved; then the debt is paid if it can be.
    func raise(_ chain: [String], for id: String, key: String, state: inout State, binders: [ShelfRow], commands: Commands, now: Date) {
        // From now on the chain is private: for cards made later, and for the clerk's reading already under way.
        markPrivate(chain + [id], state: &state)
        owePrivacy(key, state: &state)
        try? save(state)
        if payDebt(key, binders: knownRows(binders, commands: commands), state: state, commands: commands, now: now) {
            state.debts?.removeAll { $0 == key }
        } else {
            journal([("event", .string(id)), ("stage", .str("privacy_raise_failed"))])
        }
    }

    /// Records that the chain `key` owes a complete privacy pass.
    func owePrivacy(_ key: String, state: inout State) {
        if !(state.debts ?? []).contains(key) { state.debts = (state.debts ?? []) + [key] }
    }

    /// Every event with the chain key `key`: the registered chain's, and those from any other folder.
    func privacyMembers(_ key: String, state: State) -> [String] {
        var members = state.chainsByKey?[key] ?? []
        for id in state.keyEvents?[key] ?? [] where !members.contains(id) { members.append(id) }
        return members
    }

    /// The chain key an event was taken in under, when the cursor knows it.
    func chainKey(of id: String, state: State) -> String? {
        state.keyEvents?.first { $0.value.contains(id) }?.key ?? state.chainsByKey?.first { $0.value.contains(id) }?.key
    }

    /// One pass of a chain's privacy debt over `binders` (and the Inbox): every waiting card made private, every item
    /// the chain made or changed offered for redaction. True only when all of it is done, every card could be read,
    /// and no binder this Mac knows is out of reach (it may hold the chain's items).
    func payDebt(_ key: String, binders: [ShelfRow], state: State, commands: Commands, now: Date) -> Bool {
        let members = privacyMembers(key, state: state)
        guard !members.isEmpty else { return true }
        let done = raisePrivacy(chain: members, binders: binders, commands: commands, now: now)
        // The binders this Mac knows come partly from the record of the cards it wrote: while that cannot be read, a
        // binder off the shelf may still hold the chain's items, so the debt stays.
        return done && (try? commands.loadDigests()) != nil && unreachableBinders(binders, commands: commands).isEmpty
    }

    /// Pays every privacy debt it can; a debt is cleared only by a complete pass.
    func payDebts(_ binders: [ShelfRow], state: inout State, commands: Commands, now: Date) {
        // A raise an older cursor kept by event becomes its chain's debt.
        for (id, chain) in state.raises ?? [:] {
            let snapshot = state
            if let key = ([id] + chain).compactMap({ chainKey(of: $0, state: snapshot) }).first {
                owePrivacy(key, state: &state)
            }
            state.raises?[id] = nil
        }
        let rows = knownRows(binders, commands: commands)
        for key in state.debts ?? [] where payDebt(key, binders: rows, state: state, commands: commands, now: now) {
            state.debts?.removeAll { $0 == key }
        }
    }

    /// Whether the chain of event `id` still owes a privacy pass.
    package func privacyOwed(for id: String) -> Bool {
        let state = loadState()
        return chainKey(of: id, state: state).map { (state.debts ?? []).contains($0) } ?? false
    }

    /// Records events as private in the cursor; nothing ever takes one out (capture-event-v0 §3.3).
    func markPrivate(_ ids: [String], state: inout State) {
        let known = Set(state.privates ?? [])
        guard !known.isSuperset(of: ids) else { return }
        state.privates = known.union(ids).sorted()
    }

    /// The event as its cards file it: private when it is, or when it or its chain was raised to private before;
    /// sensitivity never goes down (capture-event-v0 §3.3).
    static func asFiled(_ event: CaptureEvent, privates: Set<String>, chain: [String] = []) -> CaptureEvent {
        guard !event.isPrivate, privates.contains(event.id) || chain.contains(where: privates.contains) else { return event }
        var raw = event.raw
        raw.set("sensitivity", .str("private"))
        return CaptureEvent(raw: raw, url: event.url, digest: event.digest)
    }

    /// A raise to private (capture-event-v0 §3.2, §3.3): waiting cards from the chain become private and redacted
    /// at once; cards in binders are rewritten by Sprava and trusted again. Returns false when any rewrite or
    /// redaction card could not be saved, and when not every card or item could be seen: a card file that cannot be
    /// read now, a binder whose catalog or op log cannot be read. The raise then stays owed until it can.
    package func raisePrivacy(chain: [String], binders: [ShelfRow], commands: Commands, now: Date) -> Bool {
        var complete = cardsListedCompletely(binders: binders, deviceID: commands.deviceID)
        let (unfiled, filed) = pendingCards(chain: chain, binders: binders, deviceID: commands.deviceID)
        for p in unfiled where p.raw["provenance"]?["private"] != .bool(true) {
            if (try? writeUnfiled(Self.privateCopy(p, catalog: nil).raw)) == nil { complete = false }
        }
        // Only a card still as Sprava wrote it is rewritten and trusted again; one another program changed stays
        // unverified, so it can never be approved, and covers nothing below.
        var changed = Set<String>()
        for (folder, p) in filed where p.raw["provenance"]?["private"] != .bool(true) {
            // A rewritten card that cannot be trusted again is not approvable, so the raise is retried.
            do { try BinderWrite.rewriteTrusted(p.id, in: folder, commands: commands) { Self.privateCopy($0, catalog: Teka.read(folder).catalog) } }
            catch is ProposalStore.Tampered { changed.insert(p.id) }
            catch { complete = false }
        }
        if !changed.isEmpty { journal([("stage", .str("card_changed_outside")), ("cards", .int(changed.count))]) }
        // Items already filed from the chain get a card that redacts them (capture-event-v0 §3.2, §3.3), unless a
        // card waiting from the chain already does (a retry after a partial failure).
        let ids = Set(chain)
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            // Only a card that does nothing but redact covers an item: any other card of the chain is withdrawn by its
            // next correction or retraction, and its redaction would go with it.
            let waiting = filed.filter { folder, p in
                folder.standardizedFileURL == row.folder.standardizedFileURL && commands.isTrusted(p.id, in: folder) && Self.onlyRedacts(p)
            }.map { _, p in
                p.raw["provenance"]?["private"] == .bool(true) ? p : Self.privateCopy(p, catalog: row.teka.catalog)
            }
            let covered = Set(waiting.flatMap(\.ops).compactMap { op -> String? in
                guard op["op"] == .str("update_item"), op["args"]?["set"]?["redact"] == .bool(true), let id = op["args"]?["id"] else { return nil }
                return canonicalText(id)
            })
            // A binder whose catalog or op log cannot be read shows no items, which is not "nothing to redact".
            guard !row.teka.writesBlocked, let touched = Self.itemsTouched(by: ids, in: row.folder) else {
                complete = false
                continue
            }
            let ops = row.teka.items.compactMap { item -> JSONObject? in
                guard let o = item.object, o["redact"] != .bool(true), let itemID = o["id"], !covered.contains(canonicalText(itemID)) else { return nil }
                let events = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
                guard events.contains(where: ids.contains) || touched.contains(canonicalText(itemID)) else { return nil }
                var set = JSONObject([(key: "redact", value: .bool(true))])
                if o["kind"] == nil { set.set("kind", .str("other")) }
                return JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(set))]))])
            }
            guard !ops.isEmpty else { continue }
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
            let card = Proposal.make(title: "A note became private. Redact what was filed from it?", actor: actor, ops: ops,
                                     provenance: JSONObject([(key: "events", value: .array(chain.map(JSONValue.string))), (key: "private", value: .bool(true)),
                                                             (key: "remains", value: .str("titles already published to the hub until the next publish"))]),
                                     now: now)
            if (try? BinderWrite.save(card, in: row.folder, deviceID: commands.deviceID)) != nil, (try? commands.trustProposals([card.id], in: row.folder)) != nil {} else { complete = false }
        }
        journal([("stage", .str("sensitivity_raised")), ("cards", .int(unfiled.count + filed.count))])
        return complete
    }

    /// A card made private (capture-event-v0 §3.3): every item it writes to is redacted in the same batch. A new
    /// item is redacted as it lands; an `update_item` sets `redact` with its other changes; a status change,
    /// completion or drop is preceded by an `update_item` that redacts the item, unless the card or the item
    /// already does. A redaction needs a kind, so an item without one gets `other`, as the clerk does for a
    /// private update; without the catalog (an unfiled card), the kind is left to the guard to ask for.
    /// The items, by the id's canonical text, that the approved cards of a chain's events wrote to: added, or changed
    /// by an update, a status change, a completion or a drop. Read from the binder's op log, so it is what was applied
    /// (with the person's edits), not what a card proposed; an item a capture changed keeps the provenance of the one
    /// that made it, so its own `events` never name the capture that changed it.
    /// Nil when the op log cannot be read and a card of the chain was approved: what it changed is not known.
    static func itemsTouched(by events: Set<String>, in folder: URL) -> Set<String>? {
        let cards = Set(ProposalStore.list(in: folder).map(\.0).filter { p in
            p.state == "applied" && p.raw["provenance"]?["events"]?.arrayValue?.contains { events.contains($0.stringValue ?? "") } == true
        }.map(\.id))
        guard !cards.isEmpty else { return [] }
        guard let log = try? TekaStore(folder: folder).readOpLog().ops else { return nil }
        let itemOps: Set<String> = ["add_item", "update_item", "set_status", "complete", "drop", "reopen", "dismiss", "undismiss"]
        return Set(log.compactMap { line -> String? in
            guard let proposal = line["proposal"]?.stringValue, cards.contains(proposal), itemOps.contains(line["op"]?.stringValue ?? ""),
                  let id = line["args"]?["item"]?["id"] ?? line["args"]?["id"] else { return nil }
            return canonicalText(id)
        })
    }

    static func privateCopy(_ p: Proposal, catalog: JSONObject?) -> Proposal {
        var raw = p.raw
        var prov = raw["provenance"]?.objectValue ?? JSONObject()
        prov.set("private", .bool(true))
        raw.set("provenance", .object(prov))
        let items = catalog?["open_items"]?.arrayValue ?? []
        func item(_ id: JSONValue) -> JSONValue? { items.first { $0["id"] == id } }
        func needsKind(_ id: JSONValue) -> Bool { catalog != nil && id.stringValue?.hasPrefix("$new:") != true && item(id)?["kind"] == nil }
        var redacted = Set<String>()   // items this card already redacts or adds, by the id's canonical text
        var ops: [JSONValue] = []
        for op in p.ops {
            guard var args = op["args"]?.objectValue else { ops.append(.object(op)); continue }
            var o = op
            switch op["op"]?.stringValue {
            case "add_item":
                guard var new = args["item"]?.objectValue else { break }
                new.set("redact", .bool(true))
                if new["kind"] == nil { new.set("kind", .str("other")) }
                if let id = new["id"] { redacted.insert(canonicalText(id)) }
                args.set("item", .object(new))
                o.set("args", .object(args))
            case "update_item":
                guard let id = args["id"] else { break }
                var set = args["set"]?.objectValue ?? JSONObject()
                set.set("redact", .bool(true))
                if set["kind"] == nil, needsKind(id) { set.set("kind", .str("other")) }
                args.set("set", .object(set))
                // Nothing this card writes takes the redaction or its kind away again.
                if let unset = args["unset"]?.arrayValue?.filter({ !["redact", "kind"].contains($0.stringValue ?? "") }) {
                    if unset.isEmpty { args.remove("unset") } else { args.set("unset", .array(unset)) }
                }
                o.set("args", .object(args))
                redacted.insert(canonicalText(id))
            case "set_status", "complete", "drop":
                guard let id = args["id"], !redacted.contains(canonicalText(id)), item(id)?["redact"] != .bool(true) else { break }
                var set = JSONObject([(key: "redact", value: .bool(true))])
                if needsKind(id) { set.set("kind", .str("other")) }
                ops.append(.obj([("op", .str("update_item")), ("args", .obj([("id", id), ("set", .object(set))]))]))
                redacted.insert(canonicalText(id))
            default:
                break
            }
            ops.append(.object(o))
        }
        raw.set("ops", .array(ops))
        return Proposal(raw: raw)
    }
}

import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// Raises to private: the cursor's record, and the cards rewritten and redacted (capture-event-v0 §3.2, §3.3).
extension CaptureInbox {
    /// Applies a raise to private for event `id`; one that could not be written is kept in the cursor and tried
    /// again by every sweep until it is, so an unredacted card never stays approvable.
    func raise(_ chain: [String], for id: String, state: inout State, binders: [ShelfRow], commands: Commands, now: Date) {
        // From now on the chain is private: for cards made later, and for the clerk's reading already under way.
        markPrivate(chain + [id], state: &state)
        try? save(state)
        guard !raisePrivacy(chain: chain, binders: binders, commands: commands, now: now) else { return }
        state.raises = (state.raises ?? [:]).merging([id: chain]) { $1 }
        journal([("event", .string(id)), ("stage", .str("privacy_raise_failed"))])
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
    /// redaction card could not be saved.
    package func raisePrivacy(chain: [String], binders: [ShelfRow], commands: Commands, now: Date) -> Bool {
        var complete = true
        let (unfiled, filed) = pendingCards(chain: chain, binders: binders, deviceID: commands.deviceID)
        for p in unfiled where p.raw["provenance"]?["private"] != .bool(true) {
            if (try? writeUnfiled(Self.privateCopy(p, catalog: nil).raw)) == nil { complete = false }
        }
        // Only a card still as Sprava wrote it is rewritten and trusted again; one another program changed stays
        // unverified, so it can never be approved, and covers nothing below.
        var changed = Set<String>()
        for (folder, p) in filed where p.raw["provenance"]?["private"] != .bool(true) {
            // A rewritten card that cannot be trusted again is not approvable, so the raise is retried.
            do { try commands.rewriteTrusted(p.id, in: folder) { Self.privateCopy($0, catalog: Teka.read(folder).catalog) } }
            catch is ProposalStore.Tampered { changed.insert(p.id) }
            catch { complete = false }
        }
        if !changed.isEmpty { journal([("stage", .str("card_changed_outside")), ("cards", .int(changed.count))]) }
        // Items already filed from the chain get a card that redacts them (capture-event-v0 §3.2, §3.3), unless a
        // card waiting from the chain already does (a retry after a partial failure).
        let ids = Set(chain)
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let waiting = filed.filter { folder, p in
                folder.standardizedFileURL == row.folder.standardizedFileURL && commands.isTrusted(p.id, in: folder)
            }.map { _, p in
                p.raw["provenance"]?["private"] == .bool(true) ? p : Self.privateCopy(p, catalog: row.teka.catalog)
            }
            let covered = Set(waiting.flatMap(\.ops).compactMap { op -> String? in
                guard op["op"] == .str("update_item"), op["args"]?["set"]?["redact"] == .bool(true), let id = op["args"]?["id"] else { return nil }
                return canonicalText(id)
            })
            let ops = row.teka.items.compactMap { item -> JSONObject? in
                guard let o = item.object, o["redact"] != .bool(true), let itemID = o["id"], !covered.contains(canonicalText(itemID)),
                      let events = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue), events.contains(where: ids.contains) else { return nil }
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
            if (try? ProposalStore.save(card, in: row.folder)) != nil, (try? commands.trustProposals([card.id], in: row.folder)) != nil {} else { complete = false }
        }
        journal([("stage", .str("sensitivity_raised")), ("cards", .int(unfiled.count + filed.count))])
        return complete
    }

    /// A card made private (capture-event-v0 §3.3): every item it writes to is redacted in the same batch. A new
    /// item is redacted as it lands; an `update_item` sets `redact` with its other changes; a status change,
    /// completion or drop is preceded by an `update_item` that redacts the item, unless the card or the item
    /// already does. A redaction needs a kind, so an item without one gets `other`, as the clerk does for a
    /// private update; without the catalog (an unfiled card), the kind is left to the guard to ask for.
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

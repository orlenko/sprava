import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// Capture work a binder missed while it could not be reached (a volume disconnected, a binder off the shelf): a raise
// to private, a retraction, a correction whose old cards it holds. The work is recorded per binder and finished when
// the binder is back, before anything in it from those chains can be approved (capture-event-v0 §3.2, §3.3).
extension CaptureInbox {
    /// The binders given, and every other binder Sprava trusted a card in (from the digest list), as rows.
    func knownRows(_ binders: [ShelfRow], commands: Commands) -> [ShelfRow] {
        var rows = binders
        var have = Set(binders.map { $0.folder.standardizedFileURL.path })
        for key in (try? commands.loadDigests())?.keys ?? [:].keys {
            guard let cut = key.lastIndex(of: "#") else { continue }
            let folder = URL(fileURLWithPath: String(key[..<cut]), isDirectory: true).standardizedFileURL
            guard have.insert(folder.path).inserted else { continue }
            rows.append(ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder)))
        }
        return rows
    }

    /// The binders this Mac knows that the sweep cannot write now: on the shelf but not readable as an adopted binder,
    /// or holding a card Sprava trusted but not on the shelf. A binder another Mac owns is not this Mac's to change.
    func unreachableBinders(_ binders: [ShelfRow], commands: Commands) -> [String] {
        let reachable = Set(binders.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID }
            .map { $0.folder.standardizedFileURL.path })
        var known = Set(binders.map { $0.folder.standardizedFileURL.path })
        for key in (try? commands.loadDigests())?.keys ?? [:].keys {
            guard let cut = key.lastIndex(of: "#") else { continue }
            known.insert(URL(fileURLWithPath: String(key[..<cut]), isDirectory: true).standardizedFileURL.path)
        }
        return known.subtracting(reachable).filter { path in
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let teka = Teka.read(folder)
            return !(teka.isAdopted && Owner.device(of: folder) != commands.deviceID)
        }.sorted()
    }

    /// Records that every binder the sweep cannot reach now missed the latest work of the chain `chain` (with `event`,
    /// what changed it). The chain is recorded by one of its own members, never by the event that changed it, which
    /// may belong to no chain (a private event from an unregistered folder raises a registered chain it is not in);
    /// the work is worked out again from the chain, as it is then, when the binder is back.
    func deferWork(of event: String, chain: [String], binders: [ShelfRow], commands: Commands, state: inout State) {
        let members = Set(chain + [event])
        // One member of each stored chain, and each event in no chain (an unregistered event the raise also reaches).
        let chains = Array(state.chainsByKey?.values ?? [:].values)
        var stored: [String] = []
        for id in chain + [event] where !stored.contains(where: { s in chains.contains { $0.contains(s) && $0.contains(id) } }) && !stored.contains(id) {
            stored.append(id)
        }
        for path in unreachableBinders(binders, commands: commands) {
            var ids = (state.deferred?[path] ?? []).filter { !members.contains($0) }
            ids.append(contentsOf: stored)
            state.deferred = (state.deferred ?? [:]).merging([path: ids]) { $1 }
        }
    }

    /// Records that every binder this Mac writes still owes `event`'s chain its work, when part of it failed there (a
    /// withdrawal that could not be written): it is finished like work a binder missed while away.
    func owe(_ event: String, binders: [ShelfRow], commands: Commands, state: inout State) {
        let paths = binders.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID }
            .map { $0.folder.standardizedFileURL.path } + [Self.inboxKey]
        for path in paths {
            var ids = state.deferred?[path] ?? []
            if !ids.contains(event) { ids.append(event) }
            state.deferred = (state.deferred ?? [:]).merging([path: ids]) { $1 }
        }
    }

    /// What the inbox still owes a binder before anything in it may be approved, all read from the cursor: a chain's
    /// privacy debt (it may cover any binder), work the binder missed while away, and a retraction left part done.
    enum Obligation: Equatable {
        case debt(key: String)
        case missed(event: String)
        case retraction(event: String, chain: [String])
    }

    func obligations(in folder: URL, state: State) -> [Obligation] {
        let path = folder.standardizedFileURL.path
        let debts = (state.debts ?? []).map { Obligation.debt(key: $0) }
        let missed = (state.deferred?[path] ?? []).map { Obligation.missed(event: $0) }
        // A retraction's part is the events before it; a later restore's cards are never its to withdraw.
        let clocks = state.clocks ?? [:]
        let retractions = state.ingested.filter { $0.value == "retracting" }.keys.sorted().map { id in
            Obligation.retraction(event: id, chain: (state.chainsByKey?.values.first { $0.contains(id) } ?? []).filter {
                $0 != id && (clocks[$0] ?? "") < (clocks[id] ?? "")
            })
        }
        return debts + missed + retractions
    }

    /// Whether the inbox still owes `folder` anything (`obligations`). The approval of any card in it waits for
    /// `settle`.
    public func hasDeferredWork(in folder: URL) -> Bool {
        !obligations(in: folder, state: loadState()).isEmpty
    }

    /// Finishes everything the inbox owes `folder` (`obligations`): privacy debts, work it missed while away, and
    /// retractions left part done. Call it before approving a card in that binder, and read the card again after it:
    /// false means some of it is still left (the binder cannot be written, or the cursor cannot be read or saved), and
    /// the approval must wait, since an old card there may still add what a chain made private or retracted.
    public func settle(binder folder: URL, commands: Commands, now: Date = Date()) -> Bool {
        guard var state = try? readState() else { return false }
        let path = folder.standardizedFileURL.path
        let owed = obligations(in: folder, state: state)
        guard !owed.isEmpty else { return true }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let row = ShelfRow(folder: url, source: .picked, archived: false, teka: Teka.read(url))
        // A binder this Mac cannot write now cannot have its cards made private: nothing in it is approved meanwhile.
        guard row.teka.isAdopted, Owner.device(of: url) == commands.deviceID else { return false }
        var complete = true
        for obligation in owed {
            switch obligation {
            case .debt(let key):
                // Paid in this binder at least; the debt is cleared when every binder this Mac knows could have it paid.
                if !raisePrivacy(chain: privacyMembers(key, state: state), binders: [row], commands: commands, now: now) { complete = false }
                else if payDebt(key, binders: knownRows([row], commands: commands), state: state, commands: commands, now: now) {
                    state.debts?.removeAll { $0 == key }
                }
            case .missed:
                break
            case .retraction(let event, let chain):
                if !retract(chain: chain, retraction: event, state: &state, binders: [row], commands: commands, now: now) { complete = false }
            }
        }
        settleDeferred([row], state: &state, commands: commands, now: now)
        guard (try? save(state)) != nil else { return false }
        return complete && state.deferred?[path]?.isEmpty != false
    }

    /// The approval gate: the card `id` in `folder` as it may be approved now, or nil when it may not. It settles the
    /// binder first (`settle`), then works out from the cursor, at this moment, whether any chain the card comes from is
    /// private (its events, the chains they belong to, and every event with the same app and ref). A card of a private
    /// chain that is not fully redacted is rewritten redacted (and trusted again) and checked once more; one whose chains
    /// cannot be told (an event the cursor does not know, a cursor that cannot be read) is refused. A card of no
    /// capture passes as it is. The approval path calls this, and approves only what it returns.
    public func cardForApproval(_ id: String, in folder: URL, commands: Commands, now: Date = Date()) -> Proposal? {
        guard settle(binder: folder, commands: commands, now: now), let state = try? readState(),
              let card = try? commands.loadTrusted(id, in: folder), card.state == "proposed",
              let isPrivate = derivesFromPrivateChain(card, state: state) else { return nil }
        guard isPrivate else { return card }
        let catalog = Teka.read(folder).catalog
        if Self.fullyRedacted(card, catalog: catalog) { return card }
        guard let rewritten = try? commands.rewriteTrusted(id, in: folder, transform: { Self.privateCopy($0, catalog: catalog) }),
              Self.fullyRedacted(rewritten, catalog: catalog) else { return nil }
        journal([("stage", .str("redacted_at_approval")), ("card", .string(id))])
        return rewritten
    }

    /// Whether a card comes from a chain that is private now: true or false from the cursor, nil when it cannot be told.
    func derivesFromPrivateChain(_ card: Proposal, state: State) -> Bool? {
        let events = card.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let privates = Set(state.privates ?? [])
        var isPrivate = card.raw["provenance"]?["private"] == .bool(true)
        for event in events {
            guard state.ingested[event] != nil else { return nil }
            var related = [event]
            if let key = chainKey(of: event, state: state) {
                related += privacyMembers(key, state: state)
                if (state.privateKeys ?? []).contains(key) { isPrivate = true }
            }
            if related.contains(where: privates.contains) { isPrivate = true }
        }
        return isPrivate
    }

    /// Whether nothing a card writes is in the clear: every item it adds is redacted, every item it changes, closes or
    /// reopens is redacted already or by an earlier op of the card, nothing takes a redaction away, and every document
    /// it files is redacted.
    static func fullyRedacted(_ card: Proposal, catalog: JSONObject?) -> Bool {
        let items = catalog?["open_items"]?.arrayValue ?? []
        var redacted = Set(items.filter { $0["redact"] == .bool(true) }.compactMap { $0["id"].map(canonicalText) })
        for op in card.ops {
            let args = op["args"]
            switch op["op"]?.stringValue {
            case "add_item":
                guard args?["item"]?["redact"] == .bool(true) else { return false }
                if let id = args?["item"]?["id"] { redacted.insert(canonicalText(id)) }
            case "update_item":
                guard let id = args?["id"] else { return false }
                if args?["unset"]?.arrayValue?.contains(.str("redact")) == true || args?["set"]?["redact"] == .bool(false) { return false }
                if args?["set"]?["redact"] == .bool(true) { redacted.insert(canonicalText(id)) }
                guard redacted.contains(canonicalText(id)) else { return false }
            case "set_status", "complete", "drop", "reopen", "dismiss", "undismiss":
                guard let id = args?["id"], redacted.contains(canonicalText(id)) else { return false }
            case "file_document":
                guard args?["document"]?["redact"] == .bool(true) else { return false }
            default:
                continue
            }
        }
        return true
    }

    /// The event whose words, or retraction, stand for the chain now: the newest that holds them, a duplicate counted
    /// at its own stamp as the event it repeats. So a retraction taken for a copy of an earlier one (the event between
    /// them came later) still ends the chain after that event.
    static func standing(_ chain: [String], state: State) -> String? {
        let clocks = state.clocks ?? [:]
        func original(_ e: String) -> String { state.ingested[e] == "duplicate" ? (state.dupOf?[e] ?? e) : e }
        let held = chain.filter { !["ingested", "stale_revision", "duplicate"].contains(state.ingested[original($0)] ?? "ingested") }
        return held.max(by: { (clocks[$0] ?? "") < (clocks[$1] ?? "") }).map(original)
    }

    /// The key under which the Inbox's owed work is kept beside the binders'.
    static let inboxKey = "(inbox)"

    /// Finishes the deferred work of every binder in `binders` that is reachable again, and the Inbox's.
    func settleDeferred(_ binders: [ShelfRow], state: inout State, commands: Commands, now: Date) {
        if let ids = state.deferred?[Self.inboxKey], !ids.isEmpty {
            let left = ids.filter { !finishInInbox($0, state: &state, commands: commands, now: now) }
            state.deferred?[Self.inboxKey] = left.isEmpty ? nil : left
        }
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let path = row.folder.standardizedFileURL.path
            guard let ids = state.deferred?[path], !ids.isEmpty else { continue }
            var left: [String] = []
            for id in ids where !finishDeferred(id, in: row, state: &state, commands: commands, now: now) { left.append(id) }
            state.deferred?[path] = left.isEmpty ? nil : left
            journal([("stage", .str(left.isEmpty ? "deferred_settled" : "deferred_left")), ("cards", .int(ids.count - left.count))])
        }
    }

    /// The chain's work in the Inbox, worked out from the chain as it is now: each card made from words that are no
    /// longer the chain's current ones goes, through the gate. True once done.
    func finishInInbox(_ id: String, state: inout State, commands: Commands, now: Date) -> Bool {
        let chain = state.chainsByKey?.values.first(where: { $0.contains(id) }) ?? [id]
        guard !chain.contains(where: { state.ingested[$0] == "ingested" }),
              Self.cardsReadable(in: unfiledDir), (try? unfiledDigests()) != nil else { return false }
        guard let newest = Self.standing(chain, state: state) else { return true }
        guard let current = currentWords(chain, state: state) else { return false }
        let retracted = ["retracted", "retracting"].contains(state.ingested[newest] ?? "")
        let outdated = unfiled().filter { p in
            let events = p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return events.count == 1 && chain.contains(events[0]) && (retracted || state.texts?[events[0]] != state.texts?[newest])
        }
        return withdraw(outdated.map { (nil, $0) }, reason: "replaced by a corrected note", replacement: current, state: state,
                        binders: [], commands: commands, now: now)
    }

    /// The chain's work in one binder, worked out from the chain as it is now: a retracted chain is retracted there
    /// (its waiting cards withdrawn, its filed items offered for removal, redacted first when private); otherwise each
    /// waiting card made from words that are no longer the chain's current ones is withdrawn through the gate, what it
    /// holds of the current words carried first. True once all of it is done.
    func finishDeferred(_ id: String, in row: ShelfRow, state: inout State, commands: Commands, now: Date) -> Bool {
        // An event in no chain is its own: its cards in this binder still get the work.
        let chain = state.chainsByKey?.values.first(where: { $0.contains(id) })
            ?? state.chains?.values.first(where: { $0.contains(id) }) ?? [id]
        // An event of the chain still being ingested (a crash cut its sweep short) decides what is current; the work
        // waits until a sweep has finished it.
        guard !chain.contains(where: { state.ingested[$0] == "ingested" }) else { return false }
        guard let newest = Self.standing(chain, state: state) else { return true }
        if ["retracted", "retracting"].contains(state.ingested[newest] ?? "") {
            return retract(chain: chain.filter { $0 != newest }, retraction: newest, state: &state, binders: [row], commands: commands, now: now)
        }
        // Withdrawn only through the gate: what a card holds of the current words is carried first, so a line it held
        // that the correction (made while this binder was away) could not see is not lost. Until that is done here,
        // the work stays owed to this binder.
        guard Self.cardsReadable(in: ProposalStore.dir(row.folder)), let current = currentWords(chain, state: state) else { return false }
        let text = state.texts?[newest]
        let outdated = ProposalStore.list(in: row.folder).map(\.0).filter { p in
            guard p.state == "proposed", !Self.onlyRedacts(p), p.raw["provenance"]?["retraction"] == nil else { return false }
            let events = p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
            return events.count == 1 && chain.contains(events[0]) && state.texts?[events[0]] != text
        }
        return withdraw(outdated.map { (row.folder, $0) }, reason: "replaced by a corrected note", replacement: current, state: state,
                        binders: [row], commands: commands, now: now)
    }
}

import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// Capture work a binder missed while it could not be reached (a volume disconnected, a binder off the shelf): a raise
// to private, a retraction, a correction whose old cards it holds. The work is recorded per binder and finished when
// the binder is back, before anything in it from those chains can be approved (capture-event-v0 §3.2, §3.3).
extension CaptureInbox {
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

    /// Records that every binder the sweep cannot reach now missed the latest work of `event`'s chain. One event per
    /// chain is kept: the work is worked out again from the chain when the binder is back.
    func deferWork(of event: String, chain: [String], binders: [ShelfRow], commands: Commands, state: inout State) {
        let members = Set(chain + [event])
        for path in unreachableBinders(binders, commands: commands) {
            var ids = (state.deferred?[path] ?? []).filter { !members.contains($0) }
            ids.append(event)
            state.deferred = (state.deferred ?? [:]).merging([path: ids]) { $1 }
        }
    }

    /// Records that every binder this Mac writes still owes `event`'s chain its work, when part of it failed there (a
    /// withdrawal that could not be written): it is finished like work a binder missed while away.
    func owe(_ event: String, binders: [ShelfRow], commands: Commands, state: inout State) {
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let path = row.folder.standardizedFileURL.path
            var ids = state.deferred?[path] ?? []
            if !ids.contains(event) { ids.append(event) }
            state.deferred = (state.deferred ?? [:]).merging([path: ids]) { $1 }
        }
    }

    /// What the inbox still owes a binder before anything in it may be approved, all read from the cursor: a raise to
    /// private not yet written everywhere (it may cover any binder), work the binder missed while away, and a
    /// retraction left part done (its removal card redacts first when the chain is private).
    enum Obligation: Equatable {
        case raise(event: String, chain: [String])
        case missed(event: String)
        case retraction(event: String, chain: [String])
    }

    func obligations(in folder: URL, state: State) -> [Obligation] {
        let path = folder.standardizedFileURL.path
        let raises = (state.raises ?? [:]).sorted { $0.key < $1.key }.map { Obligation.raise(event: $0.key, chain: $0.value) }
        let missed = (state.deferred?[path] ?? []).map { Obligation.missed(event: $0) }
        // A retraction's part is the events before it; a later restore's cards are never its to withdraw.
        let clocks = state.clocks ?? [:]
        let retractions = state.ingested.filter { $0.value == "retracting" }.keys.sorted().map { id in
            Obligation.retraction(event: id, chain: (state.chainsByKey?.values.first { $0.contains(id) } ?? []).filter {
                $0 != id && (clocks[$0] ?? "") < (clocks[id] ?? "")
            })
        }
        return raises + missed + retractions
    }

    /// Whether the inbox still owes `folder` anything (`obligations`). The approval of any card in it waits for
    /// `settle`.
    public func hasDeferredWork(in folder: URL) -> Bool {
        !obligations(in: folder, state: loadState()).isEmpty
    }

    /// Finishes everything the inbox owes `folder` (`obligations`): raises to private, work it missed while away, and
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
            case .raise(_, let chain):
                // Done here; the raise stays pending for the sweep until every binder and the Inbox have it.
                if !raisePrivacy(chain: chain, binders: [row], commands: commands, now: now) { complete = false }
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

    /// Finishes the deferred work of every binder in `binders` that is reachable again.
    func settleDeferred(_ binders: [ShelfRow], state: inout State, commands: Commands, now: Date) {
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let path = row.folder.standardizedFileURL.path
            guard let ids = state.deferred?[path], !ids.isEmpty else { continue }
            var left: [String] = []
            for id in ids where !finishDeferred(id, in: row, state: &state, commands: commands, now: now) { left.append(id) }
            state.deferred?[path] = left.isEmpty ? nil : left
            journal([("stage", .str(left.isEmpty ? "deferred_settled" : "deferred_left")), ("cards", .int(ids.count - left.count))])
        }
    }

    /// The chain's work in one binder, worked out from the chain as it is now: a retracted chain is retracted there
    /// (its waiting cards withdrawn, its filed items offered for removal, redacted first when private); otherwise a
    /// private chain is raised there, and each waiting card made from words that are no longer the chain's current
    /// ones is withdrawn. True once all of it is done.
    func finishDeferred(_ id: String, in row: ShelfRow, state: inout State, commands: Commands, now: Date) -> Bool {
        guard let chain = state.chainsByKey?.values.first(where: { $0.contains(id) })
                ?? state.chains?.values.first(where: { $0.contains(id) }) else { return true }
        // An event of the chain still being ingested (a crash cut its sweep short) decides what is current; the work
        // waits until a sweep has finished it.
        guard !chain.contains(where: { state.ingested[$0] == "ingested" }) else { return false }
        let clocks = state.clocks ?? [:]
        let holding = chain.filter { !["ingested", "stale_revision", "duplicate"].contains(state.ingested[$0] ?? "ingested") }
        guard let newest = holding.max(by: { (clocks[$0] ?? "") < (clocks[$1] ?? "") }) else { return true }
        if ["retracted", "retracting"].contains(state.ingested[newest] ?? "") {
            return retract(chain: chain.filter { $0 != newest }, retraction: newest, state: &state, binders: [row], commands: commands, now: now)
        }
        var complete = true
        if chain.contains(where: Set(state.privates ?? []).contains) {
            complete = raisePrivacy(chain: chain, binders: [row], commands: commands, now: now)
        }
        let current = state.texts?[newest]
        for (p, _) in ProposalStore.list(in: row.folder) where p.state == "proposed" && !Self.onlyRedacts(p)
            && p.raw["provenance"]?["retraction"] == nil {
            let events = p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard events.count == 1, chain.contains(events[0]), state.texts?[events[0]] != current else { continue }
            if (try? TekaStore(folder: row.folder).reject(p, reason: "replaced by a corrected note", now: now)) == nil { complete = false }
        }
        return complete
    }
}

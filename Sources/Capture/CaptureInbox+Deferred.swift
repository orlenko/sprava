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

    /// Whether `folder` has capture work it missed while away. The approval of any card in it waits for `settle`.
    public func hasDeferredWork(in folder: URL) -> Bool {
        loadState().deferred?[folder.standardizedFileURL.path]?.isEmpty == false
    }

    /// Finishes the capture work `folder` missed while away. Call it before approving a card in that binder: false
    /// means some of it is still left (the binder cannot be written, or the cursor cannot be read or saved), and the
    /// approval must wait, since an old card there may still add what a chain made private or retracted.
    public func settle(binder folder: URL, commands: Commands, now: Date = Date()) -> Bool {
        guard var state = try? readState() else { return false }
        let path = folder.standardizedFileURL.path
        guard state.deferred?[path]?.isEmpty == false else { return true }
        let row = ShelfRow(folder: URL(fileURLWithPath: path, isDirectory: true), source: .picked, archived: false,
                           teka: Teka.read(URL(fileURLWithPath: path, isDirectory: true)))
        settleDeferred([row], state: &state, commands: commands, now: now)
        guard (try? save(state)) != nil else { return false }
        return state.deferred?[path]?.isEmpty != false
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

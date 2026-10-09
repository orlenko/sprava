import BinderFormat
import BinderStore
import Foundation
import SpravaKit

// The clerk's cards taking the place of the code-built one, kept in the cursor until the swap is whole, so the two
// never both wait for the person (architecture 5.3).
extension CaptureInbox {
    enum Tier0Withdrawal { case withdrawn, acted, failed }

    /// Withdraws the code-built card the clerk's cards replace: `.withdrawn` once it no longer waits, `.acted` when
    /// the person approved it or filed it into a binder, `.failed` when it is still there.
    func withdrawTier0(_ card: String, binder: String?, commands: Commands, now: Date) -> Tier0Withdrawal {
        // Not found in a folder that cannot be looked at is not "gone".
        guard canInspect(binder: binder) else { return .failed }
        if let binder {
            let folder = URL(fileURLWithPath: binder, isDirectory: true)
            guard let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == card }) else { return .withdrawn }
            // The clerk's cards read the same words again: what it makes no item of and that looks actionable it lists
            // as not filed yet (capture-event-v0 §6.4), so they carry what the code-built card held.
            switch p.state {
            case "proposed":
                return withdraw([(folder, p)], reason: "replaced by the clerk's reading", replacement: .sameReading, binders: [],
                                commands: commands, now: now) ? .withdrawn : .failed
            case "rejected": return .withdrawn
            default: return .acted
            }
        }
        guard let file = unfiledFile(card) else { return .withdrawn }
        if FileManager.default.fileExists(atPath: file.path) {
            guard let p = unfiled().first(where: { $0.id == card }) else { return .failed }
            return withdraw([(nil, p)], reason: "replaced by the clerk's reading", replacement: .sameReading, binders: [],
                            commands: commands, now: now) ? .withdrawn : .failed
        }
        // Gone from the Inbox: filed by the person (it is trusted in a binder now), else discarded or withdrawn.
        let filed = (try? commands.loadDigests())?.keys.contains { $0.hasSuffix("#" + card) } ?? true
        return filed ? .acted : .withdrawn
    }

    /// Whether a card the clerk kept still waits as written: trusted in its binder, or in the Inbox.
    func waits(_ r: State.Replacement, commands: Commands) -> Bool {
        if let binder = r.binder {
            let folder = URL(fileURLWithPath: binder, isDirectory: true)
            if ProposalStore.list(in: folder).contains(where: { $0.0.id == r.card && $0.0.state == "proposed" }),
               commands.isTrusted(r.card, in: folder) { return true }
        }
        return unfiled().contains { $0.id == r.card }
    }

    /// The reason on a clerk's card Sprava took back itself, never the person.
    static let takenBack = "the clerk's cards could not all be saved"

    /// Takes back the clerk's cards that still wait, in a binder or the Inbox (a binder save falls back to the
    /// Inbox). Returns true once none of them waits. They go through the gate as the same words read again: the
    /// code-built card stays in their place, waiting or acted on by the person.
    func takeBack(_ cards: [State.Replacement], commands: Commands, now: Date) -> Bool {
        var complete = true
        for r in cards {
            if let binder = r.binder {
                let folder = URL(fileURLWithPath: binder, isDirectory: true)
                if let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == r.card }), p.state == "proposed",
                   !withdraw([(folder, p)], reason: Self.takenBack, replacement: .sameReading, binders: [], commands: commands, now: now) {
                    complete = false
                }
            }
            if let file = unfiledFile(r.card), FileManager.default.fileExists(atPath: file.path) {
                if let p = unfiled().first(where: { $0.id == r.card }) {
                    if !withdraw([(nil, p)], reason: Self.takenBack, replacement: .sameReading, binders: [], commands: commands, now: now) { complete = false }
                } else if (try? FileManager.default.removeItem(at: file)) == nil, FileManager.default.fileExists(atPath: file.path) {
                    // A card file that cannot be read as one (cut short as it was written) holds nothing to carry.
                    complete = false
                }
            }
        }
        return complete
    }

    /// Whether a card the clerk kept was written: it waits as written, or the person already approved or rejected it
    /// in its binder, or filed it there from the Inbox. A card never written, one saved but never trusted, and one
    /// Sprava took back itself were not.
    func written(_ r: State.Replacement, commands: Commands) -> Bool {
        if waits(r, commands: commands) { return true }
        // Saved in its binder: the person approved it, or rejected it (a rejection by Sprava's own take-back is not theirs).
        if let binder = r.binder,
           let (p, _) = ProposalStore.list(in: URL(fileURLWithPath: binder, isDirectory: true)).first(where: { $0.0.id == r.card }) {
            return p.state == "applied" || (p.state == "rejected" && p.raw["rejected_reason"] != .string(Self.takenBack))
        }
        // Kept in the Inbox, then filed by the person into a binder, where Sprava trusted it.
        return (try? commands.loadDigests())?.keys.contains { $0.hasSuffix("#" + r.card) } ?? false
    }

    /// Settles each hand-off cut short by a crash or a failure. It goes forward, and the code-built card gives way as
    /// the commit would have done, when the commit had saved every card (recorded in the cursor), when every card is
    /// found written (waiting, or already acted on by the person), or when the code-built card is already gone: the
    /// clerk's cards then hold the capture, and none of them is taken back. Otherwise the clerk's cards go, the
    /// code-built card stays, and the capture is read again under the poison rule. When the person acted on the
    /// code-built card itself, its content is theirs and the clerk's cards still waiting go. One that cannot be
    /// settled now stays recorded.
    func settleHandoffs(state: inout State, commands: Commands, now: Date) {
        for (id, cards) in (state.handoffs ?? [:]).sorted(by: { $0.key < $1.key }) {
            let tier0 = state.cards[id]
            let binder = state.cardBinder?[id]
            let committed = state.committed?.contains(id) == true
            // What happened to a card in a binder that cannot be read now is not known: the record waits for it, unless
            // the commit had saved every card and only the code-built card is left to give way.
            let away = !(cards.map(\.binder) + [binder]).allSatisfy { canInspect(binder: $0) }
            if away && !committed { continue }
            let forward = committed || tier0.map { !tier0Pending($0, binder: binder) } ?? true
                || cards.allSatisfy { written($0, commands: commands) }
            if forward {
                switch tier0.map({ withdrawTier0($0, binder: binder, commands: commands, now: now) }) ?? .withdrawn {
                case .withdrawn:
                    state.handoffs?[id] = nil
                    state.committed?.removeAll { $0 == id }
                    state.clerk = (state.clerk ?? [:]).merging([id: "done"]) { $1 }
                    journal([("event", .string(id)), ("stage", .str("clerk_handoff_finished"))])
                    continue
                case .failed:
                    continue
                case .acted:
                    break
                }
            }
            guard takeBack(cards, commands: commands, now: now) else { continue }
            state.handoffs?[id] = nil
            state.committed?.removeAll { $0 == id }
            journal([("event", .string(id)), ("stage", .str("clerk_handoff_taken_back"))])
        }
    }
}

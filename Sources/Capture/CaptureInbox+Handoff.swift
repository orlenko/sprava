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
        if let binder {
            let folder = URL(fileURLWithPath: binder, isDirectory: true)
            guard let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == card }) else { return .withdrawn }
            switch p.state {
            case "proposed": return (try? TekaStore(folder: folder).reject(p, reason: "replaced by the clerk's reading", now: now)) != nil ? .withdrawn : .failed
            case "rejected": return .withdrawn
            default: return .acted
            }
        }
        guard let file = unfiledFile(card) else { return .withdrawn }
        if FileManager.default.fileExists(atPath: file.path) {
            return (try? FileManager.default.removeItem(at: file)) != nil ? .withdrawn : .failed
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

    /// Takes back the clerk's cards that still wait, in a binder or the Inbox (a binder save falls back to the
    /// Inbox). Returns true once none of them waits.
    func takeBack(_ cards: [State.Replacement], now: Date) -> Bool {
        var complete = true
        for r in cards {
            if let binder = r.binder {
                let folder = URL(fileURLWithPath: binder, isDirectory: true)
                if let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == r.card }), p.state == "proposed",
                   (try? TekaStore(folder: folder).reject(p, reason: "the clerk's cards could not all be saved", now: now)) == nil {
                    complete = false
                }
            }
            if let file = unfiledFile(r.card), (try? FileManager.default.removeItem(at: file)) == nil,
               FileManager.default.fileExists(atPath: file.path) {
                complete = false
            }
        }
        return complete
    }

    /// Settles each hand-off cut short by a crash or a failure. When every card the clerk kept waits as written, the
    /// code-built card gives way, as the commit would have done; otherwise the clerk's cards go, the code-built card
    /// stays, and the capture is read again under the poison rule. One that cannot be settled now stays recorded.
    func settleHandoffs(state: inout State, commands: Commands, now: Date) {
        for (id, cards) in (state.handoffs ?? [:]).sorted(by: { $0.key < $1.key }) {
            if let tier0 = state.cards[id], cards.allSatisfy({ waits($0, commands: commands) }),
               case .withdrawn = withdrawTier0(tier0, binder: state.cardBinder?[id], commands: commands, now: now) {
                state.handoffs?[id] = nil
                state.clerk = (state.clerk ?? [:]).merging([id: "done"]) { $1 }
                journal([("event", .string(id)), ("stage", .str("clerk_handoff_finished"))])
                continue
            }
            guard takeBack(cards, now: now) else { continue }
            state.handoffs?[id] = nil
            journal([("event", .string(id)), ("stage", .str("clerk_handoff_taken_back"))])
        }
    }
}

import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

// Withdrawing what waits from a chain, and retractions (capture-event-v0 §3.2).
extension CaptureInbox {
    /// Withdraws what still waits from a chain, and ends the clerk's work on it. A card that only redacts stays: a
    /// raise to private holds whatever comes after it, and so does the removal card of `retraction`, the one being
    /// resumed. Returns false when a card could not be withdrawn.
    @discardableResult
    func withdraw(chain: [String], reason: String, keeping retraction: String? = nil, state: inout State, binders: [ShelfRow],
                  deviceID: String, now: Date) -> Bool {
        var complete = true
        for (folder, p) in withdrawable(chain: chain, binders: binders, deviceID: deviceID)
        where retraction == nil || p.raw["provenance"]?["retraction"]?.stringValue != retraction {
            if let folder {
                if (try? TekaStore(folder: folder).reject(p, reason: reason, now: now)) == nil { complete = false }
            } else if let file = unfiledFile(p.id), (try? FileManager.default.removeItem(at: file)) == nil,
                      FileManager.default.fileExists(atPath: file.path) {
                complete = false
            }
        }
        var clerk = state.clerk ?? [:]
        for id in chain where clerk[id] != nil { clerk[id] = "superseded" }
        state.clerk = clerk
        return complete
    }

    /// The cards `withdraw` would take from a chain, without touching them: every unfiled one, and each one waiting
    /// in a binder unless it only redacts.
    func withdrawable(chain: [String], binders: [ShelfRow], deviceID: String) -> [(URL?, Proposal)] {
        let (unfiled, filed) = pendingCards(chain: chain, binders: binders, deviceID: deviceID)
        func onlyRedacts(_ p: Proposal) -> Bool {
            !p.ops.isEmpty && p.ops.allSatisfy { $0["op"] == .str("update_item") && $0["args"]?["set"]?["redact"] == .bool(true) }
        }
        return unfiled.map { (nil, $0) } + filed.filter { !onlyRedacts($0.1) }.map { ($0.0, $0.1) }
    }

    /// A retraction (capture-event-v0 §3.2): what waits is withdrawn, Sprava's own copies are forgotten, and items
    /// already filed get a card that offers to drop them. Returns false when any of it could not be done; run again,
    /// it does only what is left, and never makes a second card.
    func retract(chain: [String], retraction: String, state: inout State, binders: [ShelfRow], commands: Commands, now: Date) -> Bool {
        // A retry never withdraws the removal card this retraction already made: that is the person's to decide.
        var complete = withdraw(chain: chain, reason: "the note was deleted where it was taken", keeping: retraction, state: &state,
                                binders: binders, deviceID: commands.deviceID, now: now)
        var clerk = state.clerk ?? [:]
        for id in chain {
            clerk[id] = "retracted"
            let interpretation = dir.appendingPathComponent("interpretations/\(id).json")
            if (try? FileManager.default.removeItem(at: interpretation)) == nil, FileManager.default.fileExists(atPath: interpretation.path) {
                complete = false
            }
        }
        state.clerk = clerk
        let ids = Set(chain)
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let filed = row.teka.items.compactMap { item -> JSONObject? in
                guard let o = item.object, let events = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue),
                      events.contains(where: ids.contains), let itemID = o["id"] else { return nil }
                return JSONObject([(key: "op", value: .str("drop")), (key: "args", value: .obj([
                    ("id", itemID), ("closed_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))), ("source", .str("capture"))]))])
            }
            guard !filed.isEmpty else { continue }
            // A card this retraction already made, waiting or acted on, is kept; a leftover that was never trusted
            // could not be approved, so it goes and the card is made again.
            let leftover = "its digest could not be kept"
            var made = false
            for (p, _) in ProposalStore.list(in: row.folder) where p.raw["provenance"]?["retraction"] == .string(retraction) {
                if p.state == "proposed", !commands.isTrusted(p.id, in: row.folder) {
                    if (try? TekaStore(folder: row.folder).reject(p, reason: leftover, now: now)) == nil { complete = false }
                } else if p.raw["rejected_reason"] != .string(leftover) {
                    made = true
                }
            }
            guard !made else { continue }
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
            let card = Proposal.make(title: "A note was deleted where it was taken. Remove what was filed from it?", actor: actor, ops: filed,
                                     provenance: JSONObject([(key: "events", value: .array(chain.map(JSONValue.string))),
                                                             (key: "retraction", value: .string(retraction)),
                                                             (key: "remains", value: .str("the event files in the capture folder, the titles in this binder's history, and backups"))]),
                                     now: now)
            do {
                try ProposalStore.save(card, in: row.folder)
            } catch {
                complete = false
                continue
            }
            if (try? commands.trustProposals([card.id], in: row.folder)) == nil {
                let written = ProposalStore.dir(row.folder).appendingPathComponent("\(card.id).json")
                if (try? FileManager.default.removeItem(at: written)) == nil {
                    try? TekaStore(folder: row.folder).reject(card, reason: leftover, now: now)
                }
                complete = false
            }
        }
        return complete
    }
}

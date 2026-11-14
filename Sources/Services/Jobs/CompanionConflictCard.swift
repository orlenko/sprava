import BinderStore
import Companion
import CryptoKit
import Foundation
import SpravaKit

/// companion-v0 §9.5: a phone request the Mac will not apply by itself becomes an ordinary card in the binder, holding
/// the phone's op, which the person approves (the binder's guard runs as for any card) or rejects. The decision
/// record keeps the card's exact bytes, so a crash between recording and writing it writes the same card.
enum CompanionConflictCard {
    enum Reason { case changed, repeating, refused, interrupted }

    /// The card's id comes from the request's `(D, R)`, so there is at most one card per request (§9.5).
    static func id(device: String, request: String) -> String {
        var bytes = Array(SHA256.hash(data: Data("sprava-companion-card\u{0}\(device)/\(request)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // version 8: derived, not random
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4), hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }

    /// The op the phone asked for, as a card holds it; nil for a note, which never becomes a card.
    static func op(_ action: CompanionRequestedAction) -> JSONObject? {
        guard let item = action.itemID else { return nil }
        let args: JSONObject
        let type: String
        switch action.kind {
        case .done: type = "complete"; args = JSONObject([("id", item), ("source", .str("user"))])
        case .drop: type = "drop"; args = JSONObject([("id", item), ("source", .str("user"))])
        case .followUp, .postpone:
            guard let date = action.date else { return nil }
            type = "update_item"
            args = JSONObject([("id", item), ("set", .obj([(action.kind == .followUp ? "follow_up_at" : "due", .string(date))]))])
        case .arrived: type = "set_status"; args = JSONObject([("id", item), ("status", .str("open"))])
        case .note: return nil
        }
        return JSONObject([("op", .string(type)), ("args", .object(args))])
    }

    /// The card's exact bytes, with `expect` taken from `catalog`, the binder as read under its write lock.
    static func bytes(for request: CompanionAuthenticatedRequest, label: String, reason: Reason, catalog: JSONObject,
                      client: String, now: Date) throws -> Data {
        guard let action = request.action, let op = op(action) else { throw CompanionDecisionError.invalid }
        let item = (catalog["open_items"]?.arrayValue ?? []).first { same($0["id"], action.itemID) }
            ?? (catalog["processing_log"]?.arrayValue ?? []).first { same($0["id"], action.itemID) }
        var card = Proposal.make(title: title(action, item: item, label: label, reason: reason),
            actor: JSONObject([("kind", .str("user")), ("client", .string(client))]), ops: [op],
            provenance: JSONObject([("companion", .obj([("device_id", .string(request.deviceID)),
                                                         ("request_id", .string(request.requestID))]))]), now: now)
        card.raw.set("id", .string(id(device: request.deviceID, request: request.requestID)))
        card.raw.set("expect", .object(Proposal.fingerprints([op], catalog: catalog)))
        return Data(JSONWriter.compact(.object(card.raw)).utf8)
    }

    /// Writes the recorded card once and records it as Sprava's own. A card already there with exactly these bytes
    /// (an earlier attempt that stopped before recording it) is trusted; one with other bytes, which the person already
    /// approved or rejected, is left as it is.
    static func write(_ recorded: Data, in folder: URL, commands: Commands) throws {
        guard case .object(let raw)? = try? JSONParser.parse(recorded).value else { throw CompanionDecisionError.invalid }
        let card = Proposal(raw: raw)
        guard ProposalStore.isValidID(card.id), card.raw["expect"] != nil else { throw CompanionDecisionError.invalid }
        let written = Data(JSONWriter.pretty(.object(raw)).utf8)
        let digest = "sha256:" + SHA256.hash(data: written).map { String(format: "%02x", $0) }.joined()
        // Only this card's own file is read, never the whole proposals folder, which may hold anything.
        do { try commands.trustChecked(card.id, digest: digest, in: folder); return }
        catch is ProposalStore.Tampered { return }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile {}
        try ProposalStore.save(card, in: folder)
        try commands.trustProposals([card.id], in: folder)
    }

    /// Ids are compared by their exact JSON text, as the phone's view names them (companion-v0 §8.5).
    static func same(_ a: JSONValue?, _ b: JSONValue?) -> Bool {
        guard let a, let b else { return false }
        return Data(JSONWriter.compact(a).utf8) == Data(JSONWriter.compact(b).utf8)
    }

    private static func title(_ action: CompanionRequestedAction, item: JSONValue?, label: String, reason: Reason) -> String {
        var name = item?["title"]?.stringValue ?? item?["final"]?["title"]?.stringValue ?? ""
        if name.unicodeScalars.count > 80 { name = String(String.UnicodeScalarView(name.unicodeScalars.prefix(80))) + "…" }
        let what: String
        switch action.kind {
        case .done: what = "marked done"
        case .drop: what = "dropped"
        case .followUp: what = "follow up on \(action.date ?? "?")"
        case .arrived: what = "marked arrived"
        case .postpone: what = "postponed to \(action.date ?? "?")"
        case .note: what = "note"
        }
        let why: String
        switch reason {
        case .changed: why = "changed since your phone saw it"
        case .repeating: why = "a repeating to-do: check its dates before approving"
        case .refused: why = "the binder would not take it as it is"
        case .interrupted: why = "Sprava stopped in the middle; check whether it is already done"
        }
        return "On \(label): \(what) \u{201C}\(name.isEmpty ? "untitled" : name)\u{201D}, \(why)"
    }
}

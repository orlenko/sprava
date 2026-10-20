import BinderFormat
import Foundation
import SpravaKit

/// Undo of a whole batch, such as one turn of a binder's conversation (binder-v0 §6.10): its ops are reversed in
/// reverse `seq` order as one new batch, each against the records as the reversals before it leave them. An op that
/// cannot be undone, because it changed since, records a fact or was undone already, is left as it is and reported;
/// the others apply.
extension TekaStore {
    public struct BatchUndoOutcome {
        public let ops: [JSONObject]
        /// For each op undone in part, by id, the fields it left alone because they changed since.
        public let kept: [String: [String]]
        /// The ops of the batch left as they are, by id, each with the reason.
        public let notUndone: [(op: String, reason: String)]
    }

    public func undoBatch(_ batch: String, now: Date = Date()) throws -> BatchUndoOutcome {
        var kept: [String: [String]] = [:]
        var notUndone: [(op: String, reason: String)] = []
        let ops = try apply(building: { catalog, log in
            kept = [:]
            notUndone = []
            let aborted = Set(log.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
            let members = log.filter { $0["batch"] == .string(batch) && !aborted.contains($0["id"]?.stringValue ?? "") }
                .sorted { ($0["seq"]?.numberValue?.safeInteger ?? 0) > ($1["seq"]?.numberValue?.safeInteger ?? 0) }
            guard !members.isEmpty else { throw Refused(reason: "no such change") }
            let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
            let used = Set(IDMint.usedIDs(opLog: log))
            var state = catalog
            var bodies: [OpBody] = []
            // A record whose later op in the batch was left, whole or in part, keeps what the person sees now: its
            // earlier ops are left too, so no earlier reversal writes over a value a skipped one protected.
            var held = Set<String>()
            for target in members {
                guard let id = target["id"]?.stringValue else { continue }
                let record = Self.record(of: target)
                if let record, held.contains(record) {
                    notUndone.append((id, "a later change to the same record in this batch was left as it is"))
                    continue
                }
                do {
                    // Each reversal is checked by the guard on the state the ones before it leave, so one that no
                    // longer matches is left out alone instead of refusing the whole Undo.
                    let built = try compensatingBodies(id, catalog: state, log: log, now: now)
                    let lines = built.bodies.map { provisionalLine($0, at: at, now: now) }
                    state = try TransactionGuard.check(lines, on: state, knownIDs: used).catalog
                    bodies += built.bodies
                    if !built.kept.isEmpty {
                        kept[id] = built.kept
                        if let record { held.insert(record) }
                    }
                } catch {
                    notUndone.append((id, "\(error)"))
                    if let record { held.insert(record) }
                }
            }
            guard !bodies.isEmpty else {
                throw Refused(reason: "nothing in this change can be undone: " + notUndone.map(\.reason).joined(separator: "; "))
            }
            return bodies
        }, batch: UUIDv7.make(now: now), now: now)
        return BatchUndoOutcome(ops: ops, kept: kept, notUndone: notUndone)
    }

    /// The record an op changes, keyed by kind so an item and a document with the same id stay apart.
    static func record(of op: JSONObject) -> String? {
        let args = op["args"]?.objectValue ?? JSONObject()
        switch op["op"]?.stringValue {
        case "add_item", "reopen": return args["item"]?["id"].map { "item:" + canonicalText($0) }
        case "update_item", "set_status", "complete", "drop", "dismiss", "undismiss": return args["id"].map { "item:" + canonicalText($0) }
        case "file_document": return args["document"]?["id"].map { "document:" + canonicalText($0) }
        case "update_document", "move_document": return args["id"].map { "document:" + canonicalText($0) }
        case "set_meta": return "meta"
        default: return nil
        }
    }

    /// An op line as `applyOnce` writes it, for the guard to judge before the batch is built.
    func provisionalLine(_ body: OpBody, at: String, now: Date) -> JSONObject {
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .string(at))
        var actor = body.actor
        if actor["client"] == nil { actor.set("client", .string(client)) }
        line.set("actor", .object(actor))
        for (k, v) in body.extra where k != "note" { line.set(k, v) }
        line.set("op", .string(body.op))
        line.set("args", .object(body.args))
        return line
    }
}

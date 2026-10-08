import Foundation
import SpravaKit

/// Undo appends a compensating op that names the op it reverses (binder-v0 §6.10). Nothing is deleted.
public enum Undo {
    public struct Unsupported: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// The ops `compensate` can reverse; every other op records a fact or is corrected by another op (binder-v0 §6.10).
    public static func supported(_ op: JSONObject) -> Bool {
        ["add_item", "update_item", "set_status", "dismiss", "undismiss", "complete", "drop"].contains(op["op"]?.stringValue ?? "")
    }

    /// The compensating op body for `target`, given the catalog now and the op log. `stateBefore` is the catalog as
    /// it was just before `target` (from replay), used to restore earlier values. `stateAfter`, the catalog just after
    /// it, guards against undoing through a newer change: when a field the target wrote has changed since, the undo
    /// is refused rather than overwriting that change.
    public static func compensate(_ target: JSONObject, catalog: JSONObject, opLog: [JSONObject], stateBefore: JSONObject,
                                  stateAfter: JSONObject? = nil, year: Int, now: Date) throws -> (op: String, args: JSONObject) {
        let args = target["args"]?.objectValue ?? JSONObject()
        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        func itemBefore(_ id: JSONValue) -> JSONObject? {
            stateBefore["open_items"]?.arrayValue?.first { $0["id"] == id }?.objectValue
        }
        func unchangedSince(_ id: JSONValue, _ fields: [String]) throws {
            guard let stateAfter else { return }
            let then = stateAfter["open_items"]?.arrayValue?.first { $0["id"] == id }
            let current = catalog["open_items"]?.arrayValue?.first { $0["id"] == id }
            for field in fields where current?[field] != then?[field] {
                throw Unsupported(message: "\(field) changed since; edit it instead")
            }
        }
        switch target["op"]?.stringValue {
        case "add_item":
            guard let id = args["item"]?["id"] else { throw Unsupported(message: "no item id") }
            var a = JSONObject()
            a.set("id", id)
            a.set("closed_at", .string(at))
            a.set("source", .str("user"))
            a.set("reason", .str("undo"))
            return ("drop", a)

        case "update_item":
            guard let id = args["id"], let before = itemBefore(id) else { throw Unsupported(message: "the item's earlier state is unknown") }
            let set = args["set"]?.objectValue ?? JSONObject()
            let unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
            try unchangedSince(id, set.keys + unset)
            var restore = JSONObject()
            var remove: [String] = []
            for key in set.keys + unset {
                if let old = before[key] { restore.set(key, old) } else { remove.append(key) }
            }
            if let derived = before["derived"] { restore.set("derived", derived) } else if !restore.contains("derived") { remove.append("derived") }
            var a = JSONObject()
            a.set("id", id)
            if !restore.entries.isEmpty { a.set("set", .object(restore)) }
            let current = catalog["open_items"]?.arrayValue?.first { $0["id"] == id }
            let reallyRemove = remove.filter { current?[$0] != nil && !restore.contains($0) }
            if !reallyRemove.isEmpty { a.set("unset", .array(reallyRemove.map(JSONValue.string))) }
            return ("update_item", a)

        case "set_status":
            guard let id = args["id"], let before = itemBefore(id) else { throw Unsupported(message: "the item's earlier state is unknown") }
            try unchangedSince(id, ["status", "waiting_on", "follow_up_at", "expected_by"])
            var a = JSONObject()
            a.set("id", id)
            a.set("status", before["status"] ?? .str("open"))
            for key in ["waiting_on", "follow_up_at", "expected_by"] { if let v = before[key] { a.set(key, v) } }
            a.set("derived", before["derived"] ?? .array([]))
            return ("set_status", a)

        case "dismiss", "undismiss":
            guard let id = args["id"] else { throw Unsupported(message: "no item id") }
            return (target["op"]?.stringValue == "dismiss" ? "undismiss" : "dismiss", JSONObject([(key: "id", value: id)]))

        case "complete" where args["next_due"] != nil:
            guard let id = args["id"], let due = args["occurrence_due"] else { throw Unsupported(message: "no occurrence") }
            return ("update_item", JSONObject([(key: "id", value: id), (key: "set", value: .obj([("due", due)]))]))

        case "complete", "drop":
            // Reopen under a new id: the title and kind from the closure entry, the rest from its `final`.
            guard let closedID = args["id"],
                  let entry = catalog["processing_log"]?.arrayValue?.last(where: {
                      ($0["id"] ?? $0["item"]) == closedID && $0["op_id"] == target["id"] })?.objectValue
            else { throw Unsupported(message: "the closure entry is not in the processing log") }
            var item = JSONObject()
            item.set("id", .string(try IDMint.next(catalog: catalog, opLog: opLog, year: year)))
            item.set("title", entry["title"] ?? .str(""))
            if let kind = entry["kind"] { item.set("kind", kind) }
            // Nulls are dropped and compact or week dates written out, so the reopened item meets the v0 rules.
            for e in entry["final"]?.objectValue?.entries ?? []
            where !["provenance", "created_at", "updated_at", "derived", "dismissed", "recurrence"].contains(e.key) && e.value != .null {
                if ["due", "follow_up_at", "expected_by"].contains(e.key), case .string(let text) = e.value {
                    guard let date = CalendarDate.strict(text) ?? CalendarDate.lenient(text) else { continue }
                    item.set(e.key, .string(date.description))
                } else {
                    item.set(e.key, e.value)
                }
            }
            if item["due"] == nil { item.set("no_deadline", .bool(true)) } else { item.remove("no_deadline") }
            if item["status"] == nil || item["status"] == .str("done") { item.set("status", .str("open")) }
            if item["priority"] == nil { item.set("priority", .str("normal")) }
            item.set("created_at", .string(at))
            item.set("updated_at", .string(at))
            item.set("provenance", .obj([("reopened_from", closedID), ("approved_by", .str("user"))]))
            return ("reopen", JSONObject([(key: "id", value: closedID), (key: "item", value: .object(item))]))

        case let other:
            throw Unsupported(message: "\(other ?? "this op") records a fact and cannot be undone")
        }
    }
}

extension TekaStore {
    /// Undoes one applied op by appending its compensating op (actor user), with `compensates` set.
    @discardableResult
    public func undo(opID: String, now: Date = Date()) throws -> [JSONObject] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let actor = JSONObject([(key: "kind", value: .str("user"))])
        // The compensation is built from the catalog and log read under the lock, after outside edits were absorbed,
        // so an edit made meanwhile is seen and never overwritten with older values.
        return try apply(building: { catalog, log in
            guard let index = log.firstIndex(where: { $0["id"]?.stringValue == opID }) else { throw Refused(reason: "no such op") }
            if log.contains(where: { $0["compensates"]?.stringValue == opID }) { throw Refused(reason: "already undone") }
            guard index > 0 else { throw Refused(reason: "the import snapshot cannot be undone") }
            let before = try Replay.run(Array(log[..<index]))
            let after = try Replay.run(Array(log[...index]))
            let (op, args) = try Undo.compensate(log[index], catalog: catalog, opLog: log, stateBefore: before, stateAfter: after,
                                                 year: calendar.component(.year, from: now), now: now)
            var bodies: [OpBody] = [.init(op: op, args: args, actor: actor, extra: [("compensates", .string(opID)), ("note", .str("undo"))])]
            // set_status keeps waiting fields it is not given unless the status is open, so fields the undone op
            // introduced are removed by a second op in the same batch.
            if op == "set_status", let id = args["id"],
               let now_ = catalog["open_items"]?.arrayValue?.first(where: { $0["id"] == id })?.objectValue,
               let was = before["open_items"]?.arrayValue?.first(where: { $0["id"] == id })?.objectValue,
               args["status"]?.stringValue != "open" {
                let introduced = ["waiting_on", "follow_up_at", "expected_by"].filter { now_[$0] != nil && was[$0] == nil }
                if !introduced.isEmpty {
                    bodies.append(.init(op: "update_item", args: JSONObject([(key: "id", value: id), (key: "unset", value: .array(introduced.map(JSONValue.string)))]),
                                        actor: actor, extra: [("compensates", .string(opID)), ("note", .str("undo"))]))
                }
            }
            return bodies
        }, batch: UUIDv7.make(now: now), now: now)
    }
}

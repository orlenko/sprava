import BinderStore
import SpravaKit

extension Commands {
    /// One Save may update the text/date and the waiting state. Validate the whole batch before writing either
    /// op, so a refused follow-up never leaves half of the person's edit saved (binder-v0 §6.9).
    static func itemEdit(_ args: JSONObject, actor: JSONObject) throws -> [TekaStore.OpBody] {
        guard let id = args["id"] else { throw Failure(message: "an item edit needs an id") }
        let fields: Set<String> = ["title", "details", "priority", "due", "no_deadline"]
        if let set = args["set"], set.objectValue == nil { throw Failure(message: "the edited fields must be an object") }
        if let unset = args["unset"], unset.arrayValue?.allSatisfy({ $0.stringValue != nil }) != true {
            throw Failure(message: "the removed fields must be a list of names")
        }
        let set = args["set"]?.objectValue ?? JSONObject()
        let unset = args["unset"]?.arrayValue ?? []
        guard Set(set.keys).isSubset(of: fields), Set(unset.compactMap(\.stringValue)).isSubset(of: fields) else {
            throw Failure(message: "that field is not part of an item edit")
        }
        var bodies: [TekaStore.OpBody] = []
        if !set.entries.isEmpty || !unset.isEmpty {
            var update = JSONObject([(key: "id", value: id)])
            if !set.entries.isEmpty { update.set("set", .object(set)) }
            if !unset.isEmpty { update.set("unset", .array(unset)) }
            bodies.append(.init(op: "update_item", args: update, actor: actor))
        }
        if let status = args["status"] {
            var statusArgs = JSONObject([(key: "id", value: id), (key: "status", value: status)])
            for key in ["waiting_on", "follow_up_at", "expected_by"] {
                if let value = args[key] { statusArgs.set(key, value) }
            }
            bodies.append(.init(op: "set_status", args: statusArgs, actor: actor))
        } else if ["waiting_on", "follow_up_at", "expected_by"].contains(where: { args[$0] != nil }) {
            throw Failure(message: "waiting details need an item status")
        }
        guard !bodies.isEmpty else { throw Failure(message: "the item edit contains no changes") }
        return bodies
    }
}

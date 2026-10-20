import Foundation
import SpravaKit

extension ConversationClass {
    /// The privacy markers of the records a turn touches, as each op of the turn leaves them, so every op is judged
    /// against the record as it will stand when that op applies (§6.1; architecture 4.5).
    struct TurnPrivacy {
        let catalog: JSONObject
        private var items: [JSONValue: JSONObject] = [:]
        private var documents: [JSONValue: JSONObject] = [:]

        init(catalog: JSONObject) { self.catalog = catalog }

        func item(_ id: JSONValue) -> JSONObject? {
            items[id] ?? catalog["open_items"]?.arrayValue?.first { $0["id"] == id }?.objectValue
        }

        func document(_ id: JSONValue) -> JSONObject? {
            documents[id] ?? catalog["documents"]?.arrayValue?.first { $0["id"] == id }?.objectValue
        }

        /// The fields as `set` and `unset` leave them.
        static func changed(_ record: JSONObject?, by args: JSONObject) -> JSONObject {
            var after = record ?? JSONObject()
            for name in args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? [] { after.remove(name) }
            for entry in args["set"]?.objectValue?.entries ?? [] { after.set(entry.key, entry.value) }
            return after
        }

        mutating func apply(_ op: String, args: JSONObject) {
            switch op {
            case "update_item": if let id = args["id"] { items[id] = Self.changed(item(id), by: args) }
            case "add_item", "reopen": if let new = args["item"]?.objectValue, let id = new["id"] { items[id] = new }
            case "file_document": if let new = args["document"]?.objectValue, let id = new["id"] { documents[id] = new }
            case "update_document": if let id = args["id"] { documents[id] = Self.changed(document(id), by: args) }
            default: break
            }
        }

        /// Why `op` would loosen what the hub, the phone or a brain sees, or nil: `redact` cleared, the hub title
        /// added, changed or removed, a tag on a redacted item that it did not have, the kind removed from a redacted
        /// item, or a document's `sensitivity` lowered. A new or reopened item is judged against nothing shown, or the
        /// closed item's last state.
        func loosening(_ op: String, args: JSONObject) -> String? {
            switch op {
            case "update_item":
                guard let id = args["id"] else { return nil }
                return Self.loosening(from: item(id), to: Self.changed(item(id), by: args))
            case "add_item":
                return Self.loosening(from: nil, to: args["item"]?.objectValue ?? JSONObject())
            case "reopen":
                return Self.loosening(from: closedFinal(args["id"]), to: args["item"]?.objectValue ?? JSONObject())
            case "update_document":
                guard let id = args["id"] else { return nil }
                let before = document(id), after = Self.changed(before, by: args)
                return before?["sensitivity"] == .str("private") && after["sensitivity"] != .str("private")
                    ? "lowering a document's sensitivity" : nil
            default:
                return nil
            }
        }

        static func loosening(from before: JSONObject?, to after: JSONObject) -> String? {
            let wasRedacted = before?["redact"] == .bool(true), redacted = after["redact"] == .bool(true)
            if wasRedacted, !redacted { return "clearing a privacy marker" }
            if before?["slice_title"] != after["slice_title"] { return "changing the hub title" }
            if redacted, !Set(after["tags"]?.arrayValue ?? []).isSubset(of: Set(before?["tags"]?.arrayValue ?? [])) {
                return "adding a tag to a redacted item"
            }
            if redacted, before?["kind"] != nil, after["kind"] == nil { return "removing a redacted item's kind" }
            return nil
        }

        /// The last state of a closed item, from its closure entry's `final` (binder-v0 §5.10), redacted when the
        /// state is not recorded, so a reopen never shows more than the item did.
        func closedFinal(_ id: JSONValue?) -> JSONObject? {
            guard let id else { return nil }
            let entry = catalog["processing_log"]?.arrayValue?.last { ($0["id"] ?? $0["item"]) == id }
            return entry?["final"]?.objectValue ?? JSONObject([(key: "redact", value: .bool(true))])
        }
    }
}

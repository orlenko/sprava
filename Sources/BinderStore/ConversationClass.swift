import Foundation
import SpravaKit

/// The class rule of a binder's conversation (conversation.md §6.1, decisions.md D3): code decides, from the op,
/// what it touches and what started the work, whether a change applies at once with Undo (A), waits for the
/// person's tap (B) or is never applied from the conversation (C). An engine may ask for any op; its words never
/// change the class.
public enum ConversationClass {
    public enum Class: String, Sendable, Equatable { case a, b, c }

    /// What started the work, as the runtime itself recorded it for the turn (§6.1).
    public enum Start: Sendable, Equatable {
        /// A message, drop, import or tap in the app's window for this binder.
        case personTurn
        /// The intake pipeline filing a drop or an arrival.
        case intakePipeline
        /// Work Sprava starts itself: review batches, a drop's follow-up, brief upkeep, tasks, a Terminal session.
        case spravaWork
    }

    /// What the runtime knows about a turn beyond the ops' bodies, from its own trusted records and the catalog.
    public struct Context {
        public var start: Start
        public var catalog: JSONObject
        /// Documents this binder's conversation filed, by id (with its JSON type).
        public var filedByConversation: Set<JSONValue>
        /// Items this binder's conversation created, by id, with when.
        public var createdByConversation: [JSONValue: Date]
        /// Whether each op's words are the person's own, as code checked them against the person's line (never a
        /// model's say-so); it matters for `add_item` and `add_log_entry`.
        public var personsWords: (_ index: Int) -> Bool
        public var now: Date

        public init(start: Start, catalog: JSONObject, filedByConversation: Set<JSONValue> = [],
                    createdByConversation: [JSONValue: Date] = [:], personsWords: @escaping (Int) -> Bool = { _ in false },
                    now: Date) {
            self.start = start
            self.catalog = catalog
            self.filedByConversation = filedByConversation
            self.createdByConversation = createdByConversation
            self.personsWords = personsWords
            self.now = now
        }
    }

    public struct Decision: Sendable, Equatable {
        public let kind: Class
        /// A plain sentence for the transcript, never quoting the op's text.
        public let reason: String
    }

    /// Items an own creation stays correctable in place for (§6.1, proposed).
    public static let ownItemWindow: TimeInterval = 24 * 3600
    /// More new items or documents than this in one turn wait for the person's tap (§6.1, proposed).
    public static let newRecordsPerTurn = 20

    /// The class of every op of one turn, in order.
    public static func classify(_ ops: [(op: String, args: JSONObject)], context: Context) -> [Decision] {
        // Items an earlier op of this turn redacts count as redacted for the ops after it.
        var redacting: Set<JSONValue> = []
        var decisions: [Decision] = []
        for (index, op) in ops.enumerated() {
            decisions.append(classify(op.op, args: op.args, index: index, context: context, redacting: redacting))
            if op.op == "update_item", op.args["set"]?["redact"] == .bool(true), let id = op.args["id"] { redacting.insert(id) }
        }
        let added = ops.indices.filter { ["add_item", "file_document"].contains(ops[$0].op) }
        if context.start == .personTurn, added.count > newRecordsPerTurn {
            for index in added where decisions[index].kind == .a {
                decisions[index] = Decision(kind: .b, reason: "more than \(newRecordsPerTurn) new items or documents in one turn")
            }
        }
        return decisions
    }

    static func classify(_ op: String, args: JSONObject, index: Int, context: Context, redacting: Set<JSONValue> = []) -> Decision {
        if let widening = widening(op, args: args, catalog: context.catalog, redacting: redacting) { return Decision(kind: .c, reason: widening) }
        func a(_ why: String) -> Decision { Decision(kind: .a, reason: why) }
        func b(_ why: String) -> Decision { Decision(kind: .b, reason: why) }
        let id = args["id"]
        let ownDocument = id.map(context.filedByConversation.contains) ?? false
        let ownItem = id.flatMap { context.createdByConversation[$0] }.map { context.now.timeIntervalSince($0) <= ownItemWindow } ?? false

        switch (context.start, op) {
        case (_, "set_disclosure"), (_, "rename_teka"), (_, "expunge"), (_, "set_meta"), (_, "external_edit"),
             (_, "import_snapshot"), (_, "migrate"), (_, "abort"):
            return Decision(kind: .c, reason: "only the app's own controls make this change")

        case (.personTurn, "file_document"), (.intakePipeline, "file_document"):
            if isFromIntake(args) { return a("filing a document from this binder's intake") }
            if context.start == .personTurn, isNewDraft(args) { return a("a new draft in drafts/") }
            return b("filing a document from elsewhere")
        case (.spravaWork, "file_document"):
            return isNewDraft(args) ? a("a task's new draft in drafts/") : b("work Sprava started files nothing without a tap")

        case (.personTurn, "add_item"):
            return context.personsWords(index) ? a("an item in the person's own words") : b("a suggestion; a document's obligations wait for a tap")
        case (_, "add_log_entry"):
            return context.start == .personTurn && context.personsWords(index)
                ? a("a log entry in the person's own words")
                : Decision(kind: .c, reason: "a log entry comes only from the person's own words")

        case (.personTurn, "update_document"), (.personTurn, "move_document"), (.personTurn, "unfile_document"):
            return ownDocument ? a("correcting a document this conversation filed") : b("changing a document this conversation did not file")
        case (.personTurn, "update_item"), (.personTurn, "set_status"), (.personTurn, "drop"):
            return ownItem ? a("correcting an item this conversation made today") : b("changing an item this conversation did not just make")

        case (_, "transfer_document"):
            return b("moving a document to another binder")
        case (_, "add_item"), (_, "update_item"), (_, "set_status"), (_, "complete"), (_, "drop"), (_, "reopen"),
             (_, "dismiss"), (_, "undismiss"), (_, "update_document"), (_, "move_document"), (_, "unfile_document"):
            return b(context.start == .personTurn ? "changing an existing item or document" : "work Sprava started changes nothing without a tap")
        default:
            return Decision(kind: .c, reason: "not a change a conversation can make")
        }
    }

    /// A change that loosens what the hub, the phone or a brain sees, checked before any other class (§6.1;
    /// architecture 4.5): `redact` cleared, the hub title changed, added or removed, a tag added to a redacted item,
    /// its kind removed, or a document's `sensitivity` lowered.
    static func widening(_ op: String, args: JSONObject, catalog: JSONObject, redacting: Set<JSONValue> = []) -> String? {
        let set = args["set"]?.objectValue ?? JSONObject()
        let unset = Set(args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        switch op {
        case "update_item":
            guard let id = args["id"] else { return nil }
            let item = catalog["open_items"]?.arrayValue?.first { $0["id"] == id }?.objectValue
            let redacted = item?["redact"] == .bool(true)
            if redacted, unset.contains("redact") || (set["redact"].map { $0 != .bool(true) } ?? false) { return "clearing a privacy marker" }
            if set["slice_title"] != nil || unset.contains("slice_title") { return "changing the hub title" }
            // Tags are judged against the item as it will be: redacted by this op or an earlier one of the turn too.
            let redactedAfter = redacted || redacting.contains(id) || set["redact"] == .bool(true)
            if redactedAfter, let tags = set["tags"]?.arrayValue,
               !Set(tags).isSubset(of: Set(item?["tags"]?.arrayValue ?? [])) { return "adding a tag to a redacted item" }
            if redacted, unset.contains("kind") { return "removing a redacted item's kind" }
            return nil
        case "update_document":
            guard let id = args["id"] else { return nil }
            let document = catalog["documents"]?.arrayValue?.first { $0["id"] == id }?.objectValue
            if document?["sensitivity"] == .str("private"),
               unset.contains("sensitivity") || (set["sensitivity"].map { $0 != .str("private") } ?? false) {
                return "lowering a document's sensitivity"
            }
            return nil
        default:
            return nil
        }
    }

    /// A filing from this binder's own `intake/`, the only place class A files from (§6.1).
    static func isFromIntake(_ args: JSONObject) -> Bool {
        guard case .string(let from)? = args["from"] else { return false }
        return folded(from).hasPrefix("intake/") && !from.contains("/../") && !from.hasPrefix("intake/../")
    }

    /// A new document a model wrote, filed without a source under `drafts/` and marked `sensitivity: private`, the
    /// narrowest marker such a document starts at (§6.1, §10).
    static func isNewDraft(_ args: JSONObject) -> Bool {
        guard args["from"] == nil, args["document"]?["sensitivity"] == .str("private"),
              case .string(let path)? = args["document"]?["path"] else { return false }
        return folded(path).hasPrefix("drafts/") && !path.split(separator: "/").contains("..")
    }

    static func folded(_ path: String) -> String {
        path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil)
    }
}

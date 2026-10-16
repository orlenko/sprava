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
        /// A task the person started, whose new draft in `drafts/` is its result (§10).
        case task
        /// Other work Sprava starts itself: review batches, a drop's follow-up, brief upkeep, a Terminal session.
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

    /// The class of every op of one turn, in order. Each op is judged against the records as the turn's earlier ops
    /// leave them, so a marker set and cleared within one turn, or raised and lowered, is seen as what it is.
    public static func classify(_ ops: [(op: String, args: JSONObject)], context: Context) -> [Decision] {
        var state = TurnPrivacy(catalog: context.catalog)
        var decisions: [Decision] = []
        for (index, op) in ops.enumerated() {
            decisions.append(classify(op.op, args: op.args, index: index, context: context, state: state))
            state.apply(op.op, args: op.args)
        }
        // Any start that can add records at once shows a large batch first (§6.2 item 5).
        let added = ops.indices.filter { ["add_item", "file_document"].contains(ops[$0].op) }
        if added.count > newRecordsPerTurn {
            for index in added where decisions[index].kind == .a {
                decisions[index] = Decision(kind: .b, reason: "more than \(newRecordsPerTurn) new items or documents in one turn")
            }
        }
        return decisions
    }

    static func classify(_ op: String, args: JSONObject, index: Int, context: Context, state: TurnPrivacy) -> Decision {
        if let widening = state.loosening(op, args: args) { return Decision(kind: .c, reason: widening) }
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
            // Intake documents start private (adaptation-layer 2), so only a private filing applies at once.
            if isFromIntake(args), args["document"]?["sensitivity"] == .str("private") { return a("filing a document from this binder's intake") }
            if context.start == .personTurn, isNewDraft(args) { return a("a new draft in drafts/") }
            return b("filing a document from elsewhere")
        case (.task, "file_document"):
            return isNewDraft(args) ? a("a task's new draft in drafts/") : b("a task files nothing else without a tap")

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
             (_, "dismiss"), (_, "undismiss"), (_, "update_document"), (_, "move_document"), (_, "unfile_document"),
             (_, "file_document"):
            return b(context.start == .personTurn ? "changing an existing item or document" : "work Sprava started changes nothing without a tap")
        default:
            return Decision(kind: .c, reason: "not a change a conversation can make")
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

@testable import BinderStore
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// The class rule of conversation.md §6.1 as code: what applies at once with Undo, what waits for a tap, and what
/// the conversation never does, decided by the op, its target and what started the work. Invented records only.
@Suite struct ConversationClassTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    static let item = JSONValue.str("acme-2026-001"), redactedItem = JSONValue.str("acme-2026-002")
    static let document = JSONValue.str("acme-doc-2026-001"), privateDocument = JSONValue.int(7)

    var catalog: JSONObject {
        JSONObject([
            (key: "open_items", value: .array([
                .obj([("id", Self.item), ("title", .str("Send the invented invoice")), ("status", .str("open")), ("priority", .str("normal"))]),
                .obj([("id", Self.redactedItem), ("title", .str("Invented private matter")), ("status", .str("open")),
                      ("priority", .str("normal")), ("redact", .bool(true)), ("kind", .str("payment")), ("tags", .array([.str("a")]))]),
            ])),
            (key: "documents", value: .array([
                .obj([("id", Self.document), ("title", .str("Invented lease")), ("path", .str("leases/lease.pdf"))]),
                .obj([("id", Self.privateDocument), ("title", .str("Invented note")), ("path", .str("notes/note.txt")), ("sensitivity", .str("private"))]),
            ])),
        ])
    }

    func context(_ start: ConversationClass.Start, ownDocuments: Set<JSONValue> = [], ownItems: [JSONValue: Date] = [:],
                 words: Bool = false) -> ConversationClass.Context {
        ConversationClass.Context(start: start, catalog: catalog, filedByConversation: ownDocuments,
                                  createdByConversation: ownItems, personsWords: { _ in words }, now: now)
    }

    func kind(_ op: String, _ args: [(String, JSONValue)], _ context: ConversationClass.Context) -> ConversationClass.Class {
        ConversationClass.classify([(op, JSONObject(args.map { (key: $0.0, value: $0.1) }))], context: context)[0].kind
    }

    func set(_ id: JSONValue, _ fields: [(String, JSONValue)]) -> [(String, JSONValue)] { [("id", id), ("set", .obj(fields))] }

    @Test func aPersonsTurnAppliesItsOwnAdditionsAndFilingsAtOnce() {
        let person = context(.personTurn, words: true)
        #expect(kind("add_item", [("item", .obj([("title", .str("Call the invented notary"))]))], person) == .a)
        #expect(kind("add_log_entry", [("entry", .obj([("text", .str("Spoke to the invented notary"))]))], person) == .a)
        #expect(kind("file_document", [("from", .str("intake/scan.pdf")), ("document", .obj([("path", .str("leases/scan.pdf")), ("sensitivity", .str("private"))]))], person) == .a)
        #expect(kind("file_document", [("from", .str("intake/scan.pdf")), ("document", .obj([("path", .str("leases/scan.pdf"))]))], person) == .b)   // not marked private
        #expect(kind("file_document", [("document", .obj([("path", .str("drafts/letter.md")), ("sensitivity", .str("private"))]))], person) == .a)
        #expect(kind("file_document", [("document", .obj([("path", .str("drafts/letter.md"))]))], person) == .b)   // not marked private
        #expect(kind("file_document", [("document", .obj([("path", .str("leases/elsewhere.pdf"))]))], person) == .b)
        #expect(kind("file_document", [("from", .str("intake/../catalog.json")), ("document", .obj([("path", .str("x.pdf"))]))], person) == .b)
    }

    @Test func wordsFromADocumentAreSuggestionsAndNeverLogEntries() {
        let document = context(.personTurn, words: false)
        #expect(kind("add_item", [("item", .obj([("title", .str("Pay the invented assessment"))]))], document) == .b)
        #expect(kind("add_log_entry", [("entry", .obj([("text", .str("Invented"))]))], document) == .c)
    }

    @Test func correctionsAreClassAOnlyForTheConversationsOwnRecords() {
        let own = context(.personTurn, ownDocuments: [Self.document], ownItems: [Self.item: now.addingTimeInterval(-3600)])
        #expect(kind("update_document", set(Self.document, [("title", .str("Invented lease, renewed"))]), own) == .a)
        #expect(kind("move_document", [("id", Self.document), ("path", .str("leases/2026/lease.pdf"))], own) == .a)
        #expect(kind("unfile_document", [("id", Self.document)], own) == .a)
        #expect(kind("update_item", set(Self.item, [("due", .str("2026-10-30"))]), own) == .a)
        #expect(kind("drop", [("id", Self.item)], own) == .a)

        let stale = context(.personTurn, ownItems: [Self.item: now.addingTimeInterval(-25 * 3600)])
        #expect(kind("update_item", set(Self.item, [("due", .str("2026-10-30"))]), stale) == .b)
        #expect(kind("update_document", set(Self.document, [("title", .str("Invented"))]), stale) == .b)
        #expect(kind("unfile_document", [("id", Self.document)], stale) == .b)
        #expect(kind("complete", [("id", Self.item)], own) == .b)
        // A reopen whose closed state is not recorded could show more than the item did (aReopenNeverShows...).
        #expect(kind("reopen", [("id", Self.item)], own) == .c)
        #expect(kind("transfer_document", [("id", Self.document)], own) == .b)
        // An integer id is not its string twin (binder-v0 §5.6).
        let twin = context(.personTurn, ownDocuments: [.str("7")])
        #expect(kind("update_document", set(Self.privateDocument, [("title", .str("Invented"))]), twin) == .b)
    }

    @Test func wideningsAndTheAppsOwnControlsAreNeverFromTheConversation() {
        let own = context(.personTurn, ownDocuments: [Self.privateDocument], ownItems: [Self.redactedItem: now], words: true)
        #expect(kind("update_item", [("id", Self.redactedItem), ("unset", .array([.str("redact")]))], own) == .c)
        #expect(kind("update_item", set(Self.redactedItem, [("redact", .bool(false))]), own) == .c)
        #expect(kind("update_item", set(Self.item, [("slice_title", .str("Invented hub title"))]), own) == .c)
        #expect(kind("update_item", set(Self.redactedItem, [("tags", .array([.str("a"), .str("b")]))]), own) == .c)
        #expect(kind("update_item", set(Self.redactedItem, [("tags", .array([.str("a")]))]), own) == .a)
        #expect(kind("update_item", [("id", Self.redactedItem), ("unset", .array([.str("kind")]))], own) == .c)
        #expect(kind("update_document", [("id", Self.privateDocument), ("unset", .array([.str("sensitivity")]))], own) == .c)
        for op in ["set_disclosure", "rename_teka", "expunge", "set_meta", "external_edit", "migrate", "abort", "import_snapshot", "run_script"] {
            #expect(kind(op, [], own) == .c, "\(op)")
        }
    }

    @Test func intakeAndSpravasOwnWorkHaveTheNarrowestReach() {
        let intake = context(.intakePipeline, ownItems: [Self.item: now], words: true)
        #expect(kind("file_document", [("from", .str("intake/mail/letter.pdf")), ("document", .obj([("path", .str("letters/letter.pdf")), ("sensitivity", .str("private"))]))], intake) == .a)
        #expect(kind("file_document", [("document", .obj([("path", .str("drafts/letter.md"))]))], intake) == .b)
        #expect(kind("add_item", [("item", .obj([("title", .str("Invented"))]))], intake) == .b)
        #expect(kind("add_log_entry", [("entry", .obj([("text", .str("Invented"))]))], intake) == .c)

        // A hostile document read during a review cannot drop, update or unfile anything (§6.1).
        let review = context(.spravaWork, ownDocuments: [Self.document], ownItems: [Self.item: now], words: true)
        let privateDraft: [(String, JSONValue)] = [("document", .obj([("path", .str("drafts/summary.md")), ("sensitivity", .str("private"))]))]
        #expect(kind("file_document", privateDraft, review) == .b)   // only a task's own result is filed at once
        #expect(kind("file_document", privateDraft, context(.task)) == .a)
        #expect(kind("file_document", [("from", .str("intake/scan.pdf")), ("document", .obj([("path", .str("x/scan.pdf"))]))], review) == .b)
        for op in ["drop", "update_item", "unfile_document", "update_document", "add_item"] {
            #expect(kind(op, [("id", op.hasSuffix("document") ? Self.document : Self.item)], review) == .b, "\(op)")
        }
    }

    @Test func tagsAreJudgedAgainstTheItemAsItWillBe() {
        let own = context(.personTurn, ownItems: [Self.item: now], words: true)
        #expect(kind("update_item", set(Self.item, [("redact", .bool(true)), ("tags", .array([.str("revealing")]))]), own) == .c)
        let turn = ConversationClass.classify([
            (op: "update_item", args: JSONObject(set(Self.item, [("redact", .bool(true)), ("kind", .str("payment"))]).map { (key: $0.0, value: $0.1) })),
            (op: "update_item", args: JSONObject(set(Self.item, [("tags", .array([.str("revealing")]))]).map { (key: $0.0, value: $0.1) })),
        ], context: own)
        #expect(turn.map(\.kind) == [.a, .c])

        let draft = ConversationClass.classify([
            (op: "file_document", args: JSONObject([(key: "document", value: .obj([("id", .str("$new:1")), ("path", .str("drafts/a.md")),
                                                                                  ("sensitivity", .str("private"))]))])),
            (op: "update_document", args: JSONObject([(key: "id", value: .str("$new:1")), (key: "unset", value: .array([.str("sensitivity")]))])),
        ], context: own)
        #expect(draft.map(\.kind) == [.a, .c])
    }

    func ops(_ list: [(String, [(String, JSONValue)])]) -> [(op: String, args: JSONObject)] {
        list.map { (op: $0.0, args: JSONObject($0.1.map { (key: $0.0, value: $0.1) })) }
    }

    @Test func eachOpIsJudgedAgainstTheRecordAsTheTurnLeavesIt() {
        let own = context(.personTurn, ownDocuments: [Self.document], ownItems: [Self.item: now], words: true)
        // Redacted, then cleared within one turn.
        #expect(ConversationClass.classify(ops([
            ("update_item", set(Self.item, [("title", .str("Invented private title")), ("redact", .bool(true)), ("kind", .str("payment"))])),
            ("update_item", [("id", Self.item), ("unset", .array([.str("redact")]))]),
        ]), context: own).map(\.kind) == [.a, .c])
        // A document marked private, then unmarked.
        #expect(ConversationClass.classify(ops([
            ("update_document", set(Self.document, [("path", .str("leases/other.pdf")), ("sensitivity", .str("private"))])),
            ("update_document", [("id", Self.document), ("unset", .array([.str("sensitivity")]))]),
        ]), context: own).map(\.kind) == [.a, .c])
        // A refused op changes nothing the next is judged by, so repeating it is refused again.
        let redactedOwn = context(.personTurn, ownItems: [Self.redactedItem: now], words: true)
        let reveal = set(Self.redactedItem, [("tags", .array([.str("a"), .str("revealing")]))])
        #expect(ConversationClass.classify(ops([("update_item", reveal), ("update_item", reveal)]), context: redactedOwn).map(\.kind) == [.c, .c])
        // A new item that is redacted yet carries tags, or names a hub title.
        #expect(kind("add_item", [("item", .obj([("id", .str("$new:1")), ("title", .str("Invented")), ("redact", .bool(true)),
                                                 ("kind", .str("payment")), ("tags", .array([.str("revealing")]))]))], own) == .c)
        #expect(kind("add_item", [("item", .obj([("id", .str("$new:1")), ("title", .str("Invented")), ("slice_title", .str("Hub"))]))], own) == .c)
        #expect(kind("add_item", [("item", .obj([("id", .str("$new:1")), ("title", .str("Invented")), ("tags", .array([.str("errand")]))]))], own) == .a)
    }

    @Test func aReopenNeverShowsMoreThanTheClosedItemDid() {
        var withLog = catalog
        withLog.set("processing_log", .array([.obj([("id", .str("acme-2026-003")), ("action", .str("dropped")),
                                                     ("final", .obj([("redact", .bool(true)), ("kind", .str("payment"))]))])]))
        let person = ConversationClass.Context(start: .personTurn, catalog: withLog, now: now)
        func reopen(_ item: [(String, JSONValue)]) -> ConversationClass.Class {
            ConversationClass.classify(ops([("reopen", [("id", .str("acme-2026-003")), ("item", .obj(item))])]), context: person)[0].kind
        }
        #expect(reopen([("id", .str("acme-2026-009")), ("title", .str("Invented")), ("redact", .bool(true)), ("kind", .str("payment"))]) == .b)
        #expect(reopen([("id", .str("acme-2026-009")), ("title", .str("Invented")), ("kind", .str("payment"))]) == .c)
        #expect(reopen([("id", .str("acme-2026-009")), ("title", .str("Invented")), ("redact", .bool(true)), ("kind", .str("payment")),
                        ("tags", .array([.str("revealing")]))]) == .c)
    }

    @Test func aTurnOverTheCapWaitsForATap() {
        let person = context(.personTurn, words: true)
        let ops = (0...ConversationClass.newRecordsPerTurn).map { n in
            (op: "add_item", args: JSONObject([(key: "item", value: .obj([("title", .string("Invented item \(n)"))]))]))
        }
        #expect(ConversationClass.classify(Array(ops.prefix(ConversationClass.newRecordsPerTurn)), context: person).allSatisfy { $0.kind == .a })
        #expect(ConversationClass.classify(ops, context: person).allSatisfy { $0.kind == .b })
        // Arrivals are capped too, so a large hostile arrival is shown first.
        let arrivals = (0...ConversationClass.newRecordsPerTurn).map { n in
            (op: "file_document", args: JSONObject([(key: "from", value: .string("intake/scan-\(n).pdf")),
                                                    (key: "document", value: .obj([("path", .string("scans/\(n).pdf")), ("sensitivity", .str("private"))]))]))
        }
        #expect(ConversationClass.classify(arrivals, context: context(.intakePipeline)).allSatisfy { $0.kind == .b })
    }
}

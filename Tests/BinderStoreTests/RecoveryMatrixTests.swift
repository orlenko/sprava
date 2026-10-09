@testable import BinderStore
import BinderFormat
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Recovery from an outside save of an old copy, tried systematically (binder-v0 §6.7 step 6, architecture 4.5):
/// for each sequence of approvals, every catalog the binder held along the way is saved back over it with an
/// unrelated change of the other program's own, then recovery runs and its card is approved. Every value the
/// person approved must be back, and the other program's own change kept. Invented data only.
@Suite struct RecoveryMatrixTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])
    /// The item no sequence touches, which the other program retitles.
    let bystander = "estate-example-2026-012"
    let outsideTitle = "Invented title the other program wrote"

    /// One approval: its ops, given the ids the sequence's earlier approvals created, in order.
    typealias Step = ([String]) -> [JSONObject]

    func op(_ type: String, _ args: [(String, JSONValue)]) -> JSONObject {
        JSONObject([(key: "op", value: .string(type)), (key: "args", value: .obj(args))])
    }
    func add(_ title: String) -> Step {
        { _ in [self.op("add_item", [("item", .obj([("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")),
                                                       ("priority", .str("normal")), ("no_deadline", .bool(true))]))])] }
    }
    func update(_ id: String, _ set: [(String, JSONValue)]) -> Step { { _ in [self.op("update_item", [("id", .string(id)), ("set", .obj(set))])] } }
    func updateNew(_ n: Int, _ set: [(String, JSONValue)]) -> Step { { c in [self.op("update_item", [("id", .string(c[n])), ("set", .obj(set))])] } }
    func simple(_ type: String, _ id: String, _ extra: [(String, JSONValue)] = []) -> Step { { _ in [self.op(type, [("id", .string(id))] + extra)] } }
    func simpleNew(_ type: String, _ n: Int) -> Step { { c in [self.op(type, [("id", .string(c[n]))])] } }

    var sequences: [(String, [Step])] {
        [
            ("add", [add("Invented new task")]),
            ("update", [update("estate-example-2026-007", [("title", .str("Invented title B"))]),
                        update("estate-example-2026-007", [("title", .str("Invented title C")), ("priority", .str("low"))])]),
            ("set_status", [simple("set_status", "estate-example-2026-007", [("status", .str("waiting")), ("waiting_on", .str("Invented office")),
                                                                              ("follow_up_at", .str("2026-10-20"))]),
                            simple("set_status", "estate-example-2026-007", [("status", .str("open"))])]),
            ("complete", [simple("complete", "estate-example-2026-007")]),
            ("complete recurring", [simple("complete", "estate-example-2026-010", [("next_due", .str("2026-12-14"))]),
                                    simple("complete", "estate-example-2026-010", [("next_due", .str("2027-01-14"))])]),
            ("drop", [simple("drop", "estate-example-2026-009", [("reason", .str("Invented reason"))])]),
            ("update_document", [{ _ in [self.op("update_document", [("id", .str("estate-example-doc-2026-002")),
                                                                     ("set", .obj([("title", .str("Invented letter B"))]))])] },
                                 { _ in [self.op("update_document", [("id", .str("estate-example-doc-2026-002")),
                                                                     ("set", .obj([("title", .str("Invented letter C"))]))])] }]),
            ("set_meta", [{ _ in [self.op("set_meta", [("set", .obj([("invented_note", .str("first"))]))])] },
                          { _ in [self.op("set_meta", [("set", .obj([("invented_note", .str("second"))]))])] }]),
            ("add, update, complete", [add("Invented short task"), updateNew(0, [("title", .str("Invented short task, renamed"))]),
                                       simpleNew("complete", 0)]),
            ("mixed", [update("estate-example-2026-007", [("title", .str("Invented title B"))]), simple("dismiss", "estate-example-2026-008"),
                       add("Invented mixed task"), simple("undismiss", "estate-example-2026-011"),
                       updateNew(0, [("priority", .str("high"))])]),
        ]
    }

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        store.testHookFullSync = { _ in 0 }   // a temporary folder needs no flush to the platter; keeps the matrix fast
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        return (folder, store)
    }

    func catalog(_ folder: URL) throws -> JSONObject {
        try #require(try JSONParser.parse(try Data(contentsOf: folder.appendingPathComponent("catalog.json"))).value.objectValue)
    }

    /// Approves each step as a card; returns the catalog file after each one (the first is the one before them).
    func run(_ steps: [Step], store: TekaStore, folder: URL) throws -> [Data] {
        var copies = [try Data(contentsOf: folder.appendingPathComponent("catalog.json"))]
        var created: [String] = []
        for step in steps {
            let applied = try store.approve(Proposal.make(title: "Invented card", actor: user, ops: step(created), now: now), now: now)
            created += applied.filter { $0["op"] == .str("add_item") }.compactMap { $0["args"]?["item"]?["id"]?.stringValue }
            copies.append(try Data(contentsOf: folder.appendingPathComponent("catalog.json")))
        }
        return copies
    }

    /// The catalog with the other program's own change: the bystander retitled.
    func withOutsideTitle(_ catalog: JSONObject) -> JSONObject {
        var c = catalog
        c.set("open_items", .array((c["open_items"]?.arrayValue ?? []).map { item in
            guard item["id"] == .string(bystander), case .object(var o) = item else { return item }
            o.set("title", .string(outsideTitle))
            return .object(o)
        }))
        return c
    }

    /// Saves `copy` over the catalog with the other program's own change.
    func saveOutside(_ copy: Data, in folder: URL) throws {
        let c = withOutsideTitle(try #require(try JSONParser.parse(copy).value.objectValue))
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
    }

    /// The catalog with what recovery cannot repeat left out: times and op ids, and the ids minted for records
    /// made again (`new`). Arrays are sorted, since a change made again lands after the ones that survived.
    func normalized(_ c: JSONObject, original: Set<JSONValue>) -> JSONValue {
        func fix(_ v: JSONValue?) -> JSONValue? { v.map { original.contains($0) ? $0 : .str("new") } }
        func clean(_ r: JSONValue, drop: Set<String>) -> JSONValue {
            guard case .object(var o) = r else { return r }
            o = JSONObject(o.entries.filter { !drop.contains($0.key) })
            for key in ["id", "item", "document"] { if let v = fix(o[key]) { o.set(key, v) } }
            return .object(o)
        }
        func sorted(_ a: [JSONValue]) -> JSONValue { .array(a.sorted { canonicalText($0) < canonicalText($1) }) }
        var out = c
        let stamps: Set<String> = ["created_at", "updated_at", "derived"]
        out.set("open_items", sorted((c["open_items"]?.arrayValue ?? []).map { clean($0, drop: stamps) }))
        out.set("documents", sorted((c["documents"]?.arrayValue ?? []).map { clean($0, drop: stamps) }))
        out.set("processing_log", sorted((c["processing_log"]?.arrayValue ?? []).map { clean($0, drop: ["at", "op_id", "final"]) }))
        return .object(out)
    }

    func ids(_ c: JSONObject) -> Set<JSONValue> {
        Set(["open_items", "documents", "processing_log"].flatMap { c[$0]?.arrayValue ?? [] }.compactMap { $0["id"] ?? $0["item"] ?? $0["document"] })
    }

    /// One sequence per argument, so the sequences run side by side.
    @Test(arguments: 0..<10) func everyOldCopyIsRecoveredWhole(_ index: Int) throws {
        try #require(sequences.count == 10)
        let (name, steps) = sequences[index]
        for k in 0..<steps.count {
            let (folder, store) = try adopted()
            let original = ids(try catalog(folder))
            let copies = try run(steps, store: store, folder: folder)
            let expected = withOutsideTitle(try catalog(folder))

            try saveOutside(copies[k], in: folder)
            // A copy whose approved values all came back by later approvals (open, waiting, open) loses nothing.
            let lossy = normalized(try catalog(folder), original: original) != normalized(expected, original: original)
            try store.settle(now: now)
            let card = ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil }
            #expect((card != nil) == lossy, "\(name), copy \(k): a recovery card \(lossy ? "is missing" : "for nothing")")
            guard let card else { continue }
            #expect(card.raw["provenance"]?["manual_repair"] == nil, "\(name), copy \(k): not rebuilt")
            // Approving it brings back every value the person approved, and keeps the other program's own.
            try store.approve(card, now: now)
            #expect(normalized(try catalog(folder), original: original) == normalized(expected, original: original),
                    "\(name), copy \(k): not every approved value is back")
        }
    }

    /// A write cut short and then aborted because of the outside save still lets the approvals before it be found.
    @Test func anAbortedWriteDoesNotHideEarlierLosses() throws {
        let (folder, store) = try adopted()
        let original = ids(try catalog(folder))
        let copies = try run([update("estate-example-2026-007", [("title", .str("Invented title A"))])], store: store, folder: folder)
        let afterA = try catalog(folder)
        let snapshot = try Data(contentsOf: folder.appendingPathComponent(".sprava/snapshot.json"))
        // B reaches the op log, then the process stops before the rename: the snapshot still shows A.
        try store.apply([.init(op: "dismiss", args: JSONObject([(key: "id", value: .str("estate-example-2026-008"))]), actor: user)], now: now)
        try snapshot.write(to: folder.appendingPathComponent(".sprava/snapshot.json"))
        // An editor that opened the catalog before A saves its copy.
        try saveOutside(copies[0], in: folder)
        try store.settle(now: now)
        #expect(try store.readOpLog().ops.contains { $0["op"] == .str("abort") })
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil })
        #expect(card.ops.count == 1 && card.ops[0]["op"] == .str("update_item"))
        try store.approve(card, now: now)
        #expect(normalized(try catalog(folder), original: original) == normalized(withOutsideTitle(afterA), original: original))
    }

    /// A card that changes a document is stale once that document changed.
    @Test func aDocumentCardIsStaleOnceTheDocumentChanged() throws {
        let (folder, store) = try adopted()
        let card = Proposal.make(title: "Invented card", actor: user, ops: [op("update_document", [("id", .str("estate-example-doc-2026-002")),
                                                                                                   ("set", .obj([("title", .str("Invented letter B"))]))])], now: now)
        try ProposalStore.save(card, in: folder)
        let stored = try ProposalStore.load(card.id, in: folder, expectedDigest: nil)
        try store.apply([.init(op: "update_document", args: JSONObject([(key: "id", value: .str("estate-example-doc-2026-002")),
                                                                        (key: "set", value: .obj([("title", .str("Invented newer title"))]))]),
                               actor: user)], now: now)
        #expect(throws: TekaStore.Refused.self) { try store.approve(stored, now: now) }
        #expect(try catalog(folder)["documents"]?.arrayValue?.contains { $0["title"] == .str("Invented newer title") } == true)
    }
}

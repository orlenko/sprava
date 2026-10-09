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
                        update("estate-example-2026-007", [("title", .str("Invented title C")), ("priority", .str("low")),
                                                           ("link", .str("documents/2026-08-20_will-certified-copy.pdf"))])]),
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
                                                                     ("set", .obj([("title", .str("Invented letter C")), ("date", .str("2026-10-02"))]))])] }]),
            ("set_meta", [{ _ in [self.op("set_meta", [("set", .obj([("invented_note", .str("first"))]))])] },
                          { _ in [self.op("set_meta", [("set", .obj([("invented_note", .str("second")), ("invented_other", .str("two"))]))])] }]),
            ("add, update, complete", [add("Invented short task"), updateNew(0, [("title", .str("Invented short task, renamed"))]),
                                       simpleNew("complete", 0)]),
            ("mixed", [update("estate-example-2026-007", [("title", .str("Invented title B"))]), simple("dismiss", "estate-example-2026-008"),
                       add("Invented mixed task"), simple("undismiss", "estate-example-2026-011"),
                       updateNew(0, [("priority", .str("high"))])]),
            ("add, log entry", [add("Invented logged task"),
                                { c in [self.op("add_log_entry", [("entry", .obj([("item", .string(c[0])), ("action", .str("note")),
                                                                                  ("note", .str("Invented note"))]))])] }]),
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
    /// made again, which become `new:` and the title of the record they name, so a reference to a record made again
    /// must name the new record. Arrays are sorted, since a change made again lands after the ones that survived,
    /// and the result is canonical text, since a field put back lands at the end of its record.
    func normalized(_ c: JSONObject, original: Set<JSONValue>) -> String {
        var titles: [JSONValue: String] = [:]
        for key in ["open_items", "documents", "processing_log"] {
            for r in c[key]?.arrayValue ?? [] { if let id = r["id"], let t = r["title"]?.stringValue { titles[id] = t } }
        }
        func fix(_ v: JSONValue?) -> JSONValue? { v.map { original.contains($0) ? $0 : .string("new:" + (titles[$0] ?? "?")) } }
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
        return (try? Canonical.serialize(.object(out))) ?? "unserializable"
    }

    func ids(_ c: JSONObject) -> Set<JSONValue> {
        Set(["open_items", "documents", "processing_log"].flatMap { c[$0]?.arrayValue ?? [] }.compactMap { $0["id"] ?? $0["item"] ?? $0["document"] })
    }

    /// `c` with one field of a record (`kind` "open_items" or "documents"), or of meta (`kind` "meta"), set to
    /// `value`, or removed when it is nil.
    func setting(_ c: JSONObject, _ kind: String, _ id: String?, _ field: String, _ value: JSONValue?) -> JSONObject {
        func change(_ o: JSONObject) -> JSONObject {
            var o = o
            if let value { o.set(field, value) } else { o.remove(field) }
            return o
        }
        var out = c
        if kind == "meta" {
            out.set("meta", .object(change(c["meta"]?.objectValue ?? JSONObject())))
        } else {
            out.set(kind, .array((c[kind]?.arrayValue ?? []).map { r in
                guard r["id"] == id.map(JSONValue.string), case .object(let o) = r else { return r }
                return .object(change(o))
            }))
        }
        return out
    }

    /// Runs `steps` as separate approvals, saves what `outside` makes of the catalogs along the way (with the other
    /// program's retitle of the bystander), runs recovery and approves its card. The catalog must then be what
    /// `expected` makes of the last approved one, with the retitle.
    func check(_ label: String, _ steps: [Step], outside: ([JSONObject]) -> JSONObject,
               expected: (JSONObject) -> JSONObject = { $0 }) throws {
        let (folder, store) = try adopted()
        let original = ids(try catalog(folder))
        let copies = try run(steps, store: store, folder: folder).map { try #require(try JSONParser.parse($0).value.objectValue) }
        let want = withOutsideTitle(expected(try #require(copies.last)))
        try saveOutside(Data(JSONWriter.pretty(.object(outside(copies))).utf8), in: folder)
        // A copy whose approved values all came back by later approvals (open, waiting, open) loses nothing.
        let lossy = normalized(try catalog(folder), original: original) != normalized(want, original: original)
        try store.settle(now: now)
        let card = ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil }
        #expect((card != nil) == lossy, "\(label): a recovery card \(lossy ? "is missing" : "for nothing")")
        guard let card else { return }
        #expect(card.raw["provenance"]?["manual_repair"] == nil, "\(label): not rebuilt")
        // Approving it brings back every value the person approved, and keeps the other program's own.
        try store.approve(card, now: now)
        #expect(normalized(try catalog(folder), original: original) == normalized(want, original: original),
                "\(label): not every approved value is back, or the other program's own value is gone")
    }

    /// One sequence per argument, so the sequences run side by side: every catalog along the way saved back.
    @Test(arguments: 0..<11) func everyOldCopyIsRecoveredWhole(_ index: Int) throws {
        try #require(sequences.count == 11)
        let (name, steps) = sequences[index]
        for k in 0..<steps.count {
            try check("\(name), copy \(k)", steps, outside: { $0[k] })
        }
    }

    /// The last catalog saved back without one optional field an approval wrote: the field comes back.
    @Test(arguments: 0..<11) func aDroppedApprovedFieldComesBack(_ index: Int) throws {
        let (name, steps) = sequences[index]
        let (folder, store) = try adopted()
        let copies = try run(steps, store: store, folder: folder).map { try #require(try JSONParser.parse($0).value.objectValue) }
        let first = TekaStore.cells(try #require(copies.first)), last = TekaStore.cells(try #require(copies.last))
        let required: Set<String> = ["id", "title", "status", "priority", "path", "created_at"]
        let dropped = last.filter { cell, value in
            first[cell] != value && !cell.field.isEmpty && !required.contains(cell.field) && cell.kind != "top"
                && (cell.kind == "meta" || last[TekaStore.Cell(kind: cell.kind, id: cell.id, field: "")] != nil)
        }.keys.sorted { ($0.kind, $0.field) < ($1.kind, $1.field) }
        for cell in dropped {
            try check("\(name), \(cell.field) dropped", steps,
                      outside: { self.setting($0.last!, cell.kind, cell.id?.stringValue, cell.field, nil) })
        }
    }

    /// A multi-field approval whose record the other program saved with one field back as before and another set to
    /// a value of its own: the first comes back, the other program's value stays.
    @Test func aRevertedFieldComesBackBesideTheOtherProgramsOwn() throws {
        let cases: [(Int, String, String?, String, String, JSONValue)] = [
            (1, "open_items", "estate-example-2026-007", "title", "priority", .str("normal")),
            (1, "open_items", "estate-example-2026-007", "link", "title", .str("Invented title of the other program")),
            (6, "documents", "estate-example-doc-2026-002", "title", "date", .str("2026-10-03")),
            (7, "meta", nil, "invented_note", "invented_other", .str("three")),
        ]
        for (index, kind, id, reverted, changed, value) in cases {
            let (name, steps) = sequences[index]
            try check("\(name): \(reverted) back, \(changed) the other program's", steps, outside: { copies in
                // The field as the copy before the last approval had it.
                let earlier = TekaStore.cells(copies[copies.count - 2])[TekaStore.Cell(kind: kind, id: id.map(JSONValue.string), field: reverted)]
                return self.setting(self.setting(copies.last!, kind, id, reverted, earlier), kind, id, changed, value)
            }, expected: { self.setting($0, kind, id, changed, value) })
        }
    }

    /// A lost op that can only be made again whole, over a value the other program wrote itself, is never replayed:
    /// the card asks for a repair by hand and the other program's value stays.
    @Test func aWholeReplayOverTheOtherProgramsValueIsRepairedByHand() throws {
        let (folder, store) = try adopted()
        let copies = try run(sequences[4].1, store: store, folder: folder).map { try #require(try JSONParser.parse($0).value.objectValue) }
        // A copy from before both occurrences, with a due date of the other program's own.
        let outside = setting(copies[0], "open_items", "estate-example-2026-010", "due", .str("2026-11-30"))
        try saveOutside(Data(JSONWriter.pretty(.object(outside)).utf8), in: folder)
        try store.settle(now: now)
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil })
        #expect(card.raw["provenance"]?["manual_repair"] == .bool(true))
        #expect(throws: TekaStore.Refused.self) { try store.approve(card, now: now) }
        let due = try catalog(folder)["open_items"]?.arrayValue?.first { $0["id"] == .str("estate-example-2026-010") }?["due"]
        #expect(due == .str("2026-11-30"))
    }

    /// An item from before the approvals that the other program removed takes the approved changes on it along: they
    /// are named on a card for a repair by hand, never dropped unseen.
    @Test func approvedChangesOnARemovedItemAreNamed() throws {
        let (folder, store) = try adopted()
        let copies = try run(sequences[1].1, store: store, folder: folder).map { try #require(try JSONParser.parse($0).value.objectValue) }
        var outside = try #require(copies.last)
        outside.set("open_items", .array((outside["open_items"]?.arrayValue ?? []).filter { $0["id"] != .str("estate-example-2026-007") }))
        try saveOutside(Data(JSONWriter.pretty(.object(outside)).utf8), in: folder)
        try store.settle(now: now)
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil })
        #expect(card.raw["provenance"]?["manual_repair"] == .bool(true))
    }

    /// The cells recovery keeps up op by op are the cells of each catalog read whole, for every sequence.
    @Test func cellsKeptUpOpByOpAreTheCellsReadWhole() throws {
        for (name, steps) in sequences {
            let (folder, store) = try adopted()
            _ = try run(steps, store: store, folder: folder)
            let (start, ops) = try #require(TekaStore.sinceAdoption(try store.readOpLog().ops))
            var state = start, flat = TekaStore.cells(start)
            for op in ops {
                let next = try OpApplier.apply(op, to: state)
                let (kept, looked) = TekaStore.cells(next, after: state, were: flat)
                let whole = TekaStore.cells(next)
                #expect(kept == whole, "\(name): \(op["op"]?.stringValue ?? "?")")
                #expect(Set(whole.keys).union(flat.keys).filter { flat[$0] != whole[$0] }.isSubset(of: looked), "\(name)")
                state = next
                flat = kept
            }
        }
    }

    /// An unrelated outside edit between an approval and a stale copy hides nothing: the approval is still found.
    @Test func anUnrelatedOutsideEditHidesNoEarlierLoss() throws {
        let (folder, store) = try adopted()
        let copies = try run([update("estate-example-2026-007", [("title", .str("Invented title B"))])], store: store, folder: folder)
        var unrelated = try catalog(folder)
        unrelated = setting(unrelated, "open_items", "estate-example-2026-008", "priority", .str("low"))
        try Data(JSONWriter.pretty(.object(unrelated)).utf8).write(to: folder.appendingPathComponent("catalog.json"))
        try store.settle(now: now)
        // The copy from before the approval, saved with another change of its own.
        try saveOutside(copies[0], in: folder)
        try store.settle(now: now)
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil })
        try store.approve(card, now: now)
        let items = try catalog(folder)["open_items"]?.arrayValue ?? []
        #expect(items.first { $0["id"] == .str("estate-example-2026-007") }?["title"] == .str("Invented title B"))
        #expect(items.first { $0["id"] == .string(bystander) }?["title"] == .string(outsideTitle))
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

@testable import BinderStore
import BinderFormat
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the third review of the binder writer (an id an outside edit renamed an item to, card files
/// that are links or FIFOs, and the times of an item copied from an earlier op). Invented data only.
@Suite(.serialized) struct LayerReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    func adopted() throws -> (URL, TekaStore) {
        let folder = try makeTeka(fixture: "sprava-v0")
        let store = TekaStore(folder: folder)
        try store.adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("test"))]), now: now)
        return (folder, store)
    }

    /// Edits the catalog's open items by hand, as another program would.
    func handEdit(_ folder: URL, _ change: (inout [JSONValue]) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var c = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        var items = c["open_items"]?.arrayValue ?? []
        change(&items)
        c.set("open_items", .array(items))
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: url)
    }

    func dismiss(_ id: String) -> TekaStore.OpBody {
        .init(op: "dismiss", args: JSONObject([(key: "id", value: .string(id))]), actor: user)
    }

    func addCard(created: String? = nil) -> Proposal {
        var item = JSONObject([(key: "id", value: .str("$new:1")), (key: "title", value: .str("Invented task")),
                               (key: "status", value: .str("open")), (key: "priority", value: .str("normal")),
                               (key: "no_deadline", value: .bool(true))])
        if let created {
            item.set("created_at", .string(created))
            item.set("updated_at", .string(created))
        }
        return Proposal.make(title: "Invented card", actor: user,
                             ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))]))])],
                             now: now)
    }

    // MARK: - 1. An id an outside edit renamed an item to is never minted again

    @Test func anIDAnOutsideRenameWroteIsNeverMinted() throws {
        let (folder, store) = try adopted()
        // Another program renames the first item to the id the next mint would give, then removes it.
        try handEdit(folder) { items in
            guard case .object(var first) = items[0] else { return }
            first.set("id", .str("estate-example-2026-013"))
            items[0] = .object(first)
        }
        try store.apply([dismiss("estate-example-2026-008")], now: now)
        let rename = try store.readOpLog().ops.first { $0["op"] == .str("external_edit") }
        #expect(rename?["args"]?["patch"]?.arrayValue?.first?["path"] == .str("/open_items/0/id"))
        try handEdit(folder) { items in items.removeFirst() }
        try store.apply([dismiss("estate-example-2026-009")], now: now)

        let log = try store.readOpLog().ops
        #expect(IDMint.usedIDs(opLog: log).contains(.str("estate-example-2026-013")))
        try store.approve(addCard(), now: now)
        let ids = try store.readCatalog().0["open_items"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
        #expect(!ids.contains("estate-example-2026-013"))
        #expect(ids.contains("estate-example-2026-014"))
    }

    // MARK: - 2. A card file that is a link or a FIFO is never read

    @Test func aLinkedOrFIFOCardIsNeitherListedNorLoaded() throws {
        let (folder, _) = try adopted()
        let outside = folder.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
        let card = addCard()
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try ProposalStore.save(card, in: outside)
        _ = try ProposalStore.checkedDir(folder, create: true)
        let link = ProposalStore.dir(folder).appendingPathComponent("\(card.id).json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ProposalStore.dir(outside).appendingPathComponent("\(card.id).json"))
        #expect(ProposalStore.list(in: folder).isEmpty)
        #expect(throws: (any Error).self) { try ProposalStore.load(card.id, in: folder, expectedDigest: nil) }

        // A FIFO under a card's name: listing and loading return at once instead of waiting for a writer.
        let fifoID = Proposal.make(title: "Invented", actor: user, ops: [], now: now).id
        let fifo = ProposalStore.dir(folder).appendingPathComponent("\(fifoID).json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(ProposalStore.list(in: folder).isEmpty)
        #expect(throws: ProposalStore.Tampered.self) { try ProposalStore.load(fifoID, in: folder, expectedDigest: nil) }
    }

    // MARK: - 3. An item copied from an earlier op takes the new op's times

    @Test func aCopiedItemTakesTheNewOpsTimes() throws {
        let (_, store) = try adopted()
        let applied = try store.approve(addCard(created: "2026-09-01T08:00:00Z"), now: now)
        let item = try #require(applied.first?["args"]?["item"])
        let at = try #require(applied.first?["at"])
        #expect(item["created_at"] == at)
        #expect(item["updated_at"] == at)
    }

    // MARK: - 4. A card edit is applied or refused, never dropped

    @Test func aTitleEditOnAnUpdateCardIsApplied() throws {
        let update = JSONObject([(key: "op", value: .str("update_item")),
                                 (key: "args", value: .obj([("id", .str("estate-example-2026-007")),
                                                            ("set", .obj([("title", .str("Invented proposed title"))]))]))])
        let edited = try CardEdits.apply([.obj([("index", .int(0)), ("title", .str(" Corrected task "))])], to: [update])
        #expect(edited[0]["args"]?["set"]?["title"] == .str("Corrected task"))

        // An edit the op cannot carry is refused.
        let add = addCard().ops[0]
        let complete = JSONObject([(key: "op", value: .str("complete")), (key: "args", value: .obj([("id", .str("estate-example-2026-007"))]))])
        #expect(throws: CardEdits.Failure.self) { try CardEdits.apply([.obj([("index", .int(0)), ("waiting_on", .str("Invented Office"))])], to: [add]) }
        #expect(throws: CardEdits.Failure.self) { try CardEdits.apply([.obj([("index", .int(0)), ("title", .str("Invented"))])], to: [complete]) }
        #expect(throws: CardEdits.Failure.self) { try CardEdits.apply([.obj([("index", .int(0)), ("folder", .str("documents"))])], to: [add]) }
        #expect(throws: CardEdits.Failure.self) { try CardEdits.apply([.obj([("index", .int(0)), ("title", .int(3))])], to: [update]) }
    }

    // MARK: - 5. A meta that is not an object is never written over

    @Test func aNonObjectMetaIsNeverReplaced() throws {
        let catalog = JSONObject([(key: "meta", value: .str("Invented project notes")), (key: "open_items", value: .array([]))])
        func line(_ op: String, _ args: JSONValue) -> JSONObject {
            JSONObject([(key: "id", value: .string(UUIDv7.make(now: now))), (key: "at", value: .str("2026-10-06T08:00:00Z")),
                        (key: "actor", value: .object(user)), (key: "op", value: .string(op)), (key: "args", value: args)])
        }
        let ops = [line("set_disclosure", .obj([("disclosure", .str("none"))])),
                   line("set_meta", .obj([("set", .obj([("lifecycle", .str("ongoing"))]))])),
                   line("rename_teka", .obj([("name", .str("invented-new")), ("former", .str("invented")), ("until", .str("2026-10-06"))]))]
        for op in ops {
            #expect(throws: OpApplier.Failure.self) { try OpApplier.apply(op, to: catalog) }
            #expect(throws: TransactionGuard.Rejection.self) { try TransactionGuard.check([op], on: catalog) }
        }
        // A catalog with no meta at all still gets one.
        let bare = JSONObject([(key: "open_items", value: .array([]))])
        #expect(try OpApplier.apply(ops[0], to: bare)["meta"]?["disclosure"] == .str("none"))
    }

    // MARK: - 6. A batch overwritten in part offers again only what was lost

    @Test func aPartlyOverwrittenBatchOffersTheLostPartAgain() throws {
        let (folder, store) = try adopted()
        func retitle(_ id: String, _ title: String, priority: String? = nil) -> TekaStore.OpBody {
            var set = JSONObject([(key: "title", value: .string(title))])
            if let priority { set.set("priority", .string(priority)) }
            return .init(op: "update_item", args: JSONObject([(key: "id", value: .string(id)), (key: "set", value: .object(set))]), actor: user)
        }
        let original = try #require(try store.readCatalog().0["open_items"]?.arrayValue?.first { $0["id"] == .str("estate-example-2026-007") }?["title"])
        let applied = try store.apply([retitle("estate-example-2026-007", "Invented title A", priority: "low"),
                                       retitle("estate-example-2026-008", "Invented title B")],
                                      batch: UUIDv7.make(now: now), now: now)
        // Another program puts back the first item's title only; its new priority and the second item's title stay.
        try handEdit(folder) { items in
            guard let i = items.firstIndex(where: { $0["id"] == .str("estate-example-2026-007") }), case .object(var first) = items[i] else { return }
            first.set("title", original)
            items[i] = .object(first)
        }
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: true))
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil })
        #expect(card.raw["provenance"]?["overwritten_ops"] == .array([try #require(applied[0]["id"])]))
        #expect(card.ops.count == 1)
        #expect(card.ops[0]["args"]?["id"] == .str("estate-example-2026-007"))
        #expect(card.ops[0]["args"]?["set"] == .obj([("title", .str("Invented title A"))]))

        // Approving it brings the title back and leaves what survived as it is.
        try store.approve(card, now: now)
        let items = try store.readCatalog().0["open_items"]?.arrayValue ?? []
        let first = items.first { $0["id"] == .str("estate-example-2026-007") }
        #expect(first?["title"] == .str("Invented title A") && first?["priority"] == .str("low"))
        #expect(items.first { $0["id"] == .str("estate-example-2026-008") }?["title"] == .str("Invented title B"))
    }

    // MARK: - 7. A copy saved from before several approvals undoes them all, and all are offered again

    @Test func aCopyFromBeforeTwoApprovalsOffersBothAgain() throws {
        let (folder, store) = try adopted()
        let found = try Data(contentsOf: folder.appendingPathComponent("catalog.json"))
        let first = try store.apply([dismiss("estate-example-2026-007")], now: now)
        let second = try store.apply([dismiss("estate-example-2026-008")], now: now)
        // Another program that read the catalog before both changes saves its copy over it.
        try found.write(to: folder.appendingPathComponent("catalog.json"))
        try store.settle(now: now)
        #expect(store.lastAbsorbed == .externalEdit(revertedLastBatch: true))
        let card = try #require(ProposalStore.list(in: folder).map(\.0).first { $0.raw["provenance"]?["overwritten_ops"] != nil })
        #expect(card.raw["provenance"]?["overwritten_ops"] == .array((first + second).compactMap { $0["id"] }))
        #expect(card.ops.map { $0["args"]?["id"] } == [.str("estate-example-2026-007"), .str("estate-example-2026-008")])
    }

    // MARK: - 8. Settling a catalog at an unknown level writes nothing

    @Test func settlingAnUnknownLevelWritesNothing() throws {
        let (folder, store) = try adopted()
        try store.apply([dismiss("estate-example-2026-007")], now: now)
        let url = folder.appendingPathComponent("catalog.json")
        var c = try #require(try JSONParser.parse(try Data(contentsOf: url)).value.objectValue)
        var meta = try #require(c["meta"]?.objectValue)
        meta.set("format_version", .str("1"))
        c.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(c)).utf8).write(to: url)
        let names = ["catalog.json", ".sprava/ops.ndjson", ".sprava/snapshot.json"]
        let before = try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) }

        #expect(throws: TekaStore.Refused.self) { try store.settle(now: now) }
        #expect(try names.map { try Data(contentsOf: folder.appendingPathComponent($0)) } == before)
        #expect(!FileManager.default.fileExists(atPath: ProposalStore.dir(folder).path)
                || ProposalStore.list(in: folder).allSatisfy { $0.0.raw["provenance"]?["overwritten_ops"] == nil })
    }
}

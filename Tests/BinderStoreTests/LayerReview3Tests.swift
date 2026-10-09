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
}

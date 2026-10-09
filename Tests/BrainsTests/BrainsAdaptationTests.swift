import BinderFormat
import BinderStore
@testable import Brains
import Capture
import Extract
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from adapting Brains to the reviewed lower layers: a client token that can never be all zeros, a
/// binder the hub may publish nothing from that brains see nothing of either, and a disclosure raised outside Sprava
/// that waits for the person's card before a brain sees more. Binders and Sprava's state live in temporary folders
/// only; no test opens a socket or touches the Keychain. Invented data only.
@Suite(.serialized) struct BrainsAdaptationTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let bb = BugbotMCPTests()

    // MARK: - The client token

    @Test func zeroBytesWouldMakeTheAllZeroToken() {
        // What a failed random source would have left: the token every such client would share.
        #expect(MCPClients.token([UInt8](repeating: 0, count: 32)) == "sprava_ct_" + String(repeating: "0", count: 64))
    }

    @Test func newTokensAreRandomAndWellFormed() throws {
        let tokens = (0..<64).map { _ in MCPClients.newToken() }
        #expect(Set(tokens).count == tokens.count)
        #expect(!tokens.contains(MCPClients.token([UInt8](repeating: 0, count: 32))))
        for token in tokens { #expect(token.wholeMatch(of: /sprava_ct_[0-9a-f]{64}/) != nil) }
        var clients = MCPClients()
        let a = try clients.register(id: "invented-a", name: "Invented A", binders: [:], now: now)
        let b = try clients.register(id: "invented-b", name: "Invented B", binders: [:], now: now)
        #expect(a != b)
        #expect(clients.authenticate(clientID: "invented-a", token: a)?.id == "invented-a")
        #expect(clients.authenticate(clientID: "invented-a", token: b) == nil)
    }

    // MARK: - What a brain sees is limited as the hub's slice is

    /// A careful reading waiting in the binder, with the clerk's title and summary, and the filing card it belongs to
    /// (a reading is offered only while its card stands).
    func waitingReading(_ s: BugbotMCPTests.Setup) throws {
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(s.commands.client))])
        let body = JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: bb.addItem(1)["args"] ?? .obj([]))])
        let card = Proposal.make(title: "Invented filing card", actor: actor, ops: [body], now: now)
        try ProposalStore.save(card, in: s.folder)
        var e = IntakeReadings.Entry(id: "reading-1", binder: s.folder.standardizedFileURL.path, name: "letter.pdf",
                                     sha256: String(repeating: "0", count: 64), card: card.id,
                                     reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented letter about a roof.", channel: "other"),
                                     now: now)
        e.escalation = "waiting"
        e.result = JSONObject([(key: "class", value: .str("letter")), (key: "title", value: .str("Invented roof letter")),
                               (key: "summary", value: .str("An invented summary."))])
        try IntakeReadings(support: s.commands.support).save(e)
    }

    func readDocument(_ s: BugbotMCPTests.Setup) throws -> JSONValue {
        try bb.tool(s.server, "read_document", .obj([("binder", .str("estate-example")), ("reading_id", .str("reading-1"))]))
    }

    func readings(_ s: BugbotMCPTests.Setup) throws -> [JSONValue] {
        try bb.tool(s.server, "list_readings", .obj([]))["structuredContent"]?["readings"]?.arrayValue ?? []
    }

    func binders(_ s: BugbotMCPTests.Setup) throws -> [JSONValue] {
        try bb.tool(s.server, "list_binders", .obj([]))["structuredContent"]?["binders"]?.arrayValue ?? []
    }

    func editMeta(_ folder: URL, _ change: (inout [String: Any]) -> Void) throws {
        let url = folder.appendingPathComponent("catalog.json")
        var catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var meta = try #require(catalog["meta"] as? [String: Any])
        change(&meta)
        catalog["meta"] = meta
        try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted]).write(to: url)
    }

    @Test func aBinderAtFullShowsItsDocuments() throws {
        // The control for the next test: the same binder at a valid `full` is read in full.
        let s = try bb.setup(documents: true) { c in
            var meta = c["meta"] as? [String: Any] ?? [:]
            meta["disclosure"] = "full"
            c["meta"] = meta
        }
        try waitingReading(s)
        #expect(try binders(s).count == 1)
        #expect(try readings(s).first?["summary"]?.stringValue == "An invented summary.")
        #expect(try readDocument(s)["structuredContent"]?["text"]?.stringValue == "An invented letter about a roof.")
    }

    @Test func aBinderWithoutADisclosureShowsBrainsNothing() throws {
        // A stamped catalog without meta.disclosure: an absent level reads as `full`, but nothing may leave it.
        let s = try bb.setup(documents: true) { c in
            var meta = c["meta"] as? [String: Any] ?? [:]
            meta["disclosure"] = nil
            c["meta"] = meta
        }
        #expect(Teka.read(s.folder).federationBlocked)
        try waitingReading(s)
        #expect(try binders(s).isEmpty)
        #expect(try readings(s).isEmpty)
        let read = try readDocument(s)
        #expect(read["isError"] == .bool(true))
        #expect(read["structuredContent"]?["text"] == nil)
        #expect(try bb.propose(s.server, ops: [bb.addItem(1)])["isError"] == .bool(true))
        #expect(!ProposalStore.list(in: s.folder).contains { $0.0.actor["kind"] == .str("brain") })
        let finish = try bb.tool(s.server, "finish_reading", .obj([("binder", .str("estate-example")), ("reading_id", .str("reading-1"))]))
        #expect(finish["isError"] == .bool(true))
        #expect(IntakeReadings(support: s.commands.support).load("reading-1")?.escalation == "waiting")
    }

    @Test func aBinderWhoseNameDiffersFromItsFolderShowsBrainsNothing() throws {
        let s = try bb.setup(documents: true) { c in
            var meta = c["meta"] as? [String: Any] ?? [:]
            meta["disclosure"] = "full"
            c["meta"] = meta
        }
        try waitingReading(s)
        try editMeta(s.folder) { $0["name"] = "estate-example-renamed" }
        #expect(Teka.read(s.folder).federationBlocked)
        #expect(try binders(s).isEmpty)
        #expect(try readings(s).isEmpty)
    }

    @Test func aDisclosureRaisedOutsideSpravaWaitsForTheCard() throws {
        // Adopted at `kind`; an outside edit raises it to `full`. The ratchet holds the confirmed `kind` until the
        // person approves the privacy card, so a brain sees the class of a reading only: no file name, no title, no
        // summary, no text.
        let s = try bb.setup(documents: true) { c in
            var meta = c["meta"] as? [String: Any] ?? [:]
            meta["disclosure"] = "kind"
            c["meta"] = meta
        }
        try waitingReading(s)
        try editMeta(s.folder) { $0["disclosure"] = "full" }
        let teka = Teka.read(s.folder)
        #expect(!teka.federationBlocked)
        #expect(PrivacyRatchet.view(folder: s.folder, catalog: try #require(teka.catalog)).widenedTo == "full")

        #expect(try binders(s).count == 1)
        let entry = try #require(try readings(s).first)
        #expect(entry["class"]?.stringValue == "letter")
        for hidden in ["file", "title", "summary"] { #expect(entry[hidden] == nil) }
        let read = try readDocument(s)
        #expect(read["isError"] == .bool(true))
        #expect(read["structuredContent"]?["text"] == nil)
    }

    @Test func aDisclosureRaisedFromTitleShowsNoSummaryOrText() throws {
        // Adopted at `title` (the fixture's level); raised outside to `full`: the title shows, the summary and text do not.
        let s = try bb.setup(documents: true)
        try waitingReading(s)
        try editMeta(s.folder) { $0["disclosure"] = "full" }
        let entry = try #require(try readings(s).first)
        #expect(entry["title"]?.stringValue == "Invented roof letter")
        #expect(entry["summary"] == nil)
        #expect(try readDocument(s)["isError"] == .bool(true))
    }
}

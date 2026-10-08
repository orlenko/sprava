import BinderFormat
import BinderStore
import Brains
import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Increment 7: intake files are read before they are carded, email messages come with their attachments, and
/// the clerk's document reading replaces the code-built card (docs/adaptation-layer.md §4). All examples invented.
@Suite(.serialized) struct IntakeReadingTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07

    struct Setup {
        let support: URL
        let commands: Commands
        let folder: URL
        let watcher: IntakeWatcher
    }

    func setup() throws -> Setup {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-reading-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        try adoptAsCommand(folder, commands: commands, now: now, today: today)
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake/mail"), withIntermediateDirectories: true)
        return Setup(support: support, commands: commands, folder: folder, watcher: IntakeWatcher(support: support))
    }

    func rows(_ s: Setup) -> [ShelfRow] { [ShelfRow(folder: s.folder, source: .picked, archived: false, teka: Teka.read(s.folder))] }

    func open(_ s: Setup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }

    func write(_ s: Setup, _ path: String, _ text: String) throws {
        let url = s.folder.appendingPathComponent("intake/" + path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Two scans with a reading between them, as the runtime does.
    func card(_ s: Setup) -> IntakeWatcher.ScanResult {
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now, requireReading: true)
        let prepared = s.watcher.prepare(binders: rows(s), deviceID: "dev", reader: .inProcess)
        return s.watcher.scan(binders: rows(s), commands: s.commands, now: now, prepared: prepared, requireReading: true)
    }

    func call(_ s: Setup, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func approve(_ s: Setup, _ card: Proposal, _ extra: [(String, JSONValue)] = []) throws -> JSONValue {
        let listed = try call(s, [("command", .str("proposals")), ("binder", .string(s.folder.path))])
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        return try call(s, [("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)),
                            ("digest", shown["digest"]!)] + extra)
    }

    static let notice = """
    INVENTED NOTICE, September 30, 2026. The special levy of $450.00 is due November 1, 2026. \
    Please reply by October 20, 2026 to confirm the payment method. Invoice no. AB-12345.
    """

    static let message = """
    ---
    subject: "Re: Invented levy notice"
    from: "Example Manager <manager@example.com>"
    to: "owner@example.com"
    date: "Thu, 01 Oct 2026 23:30:00 -0400"
    ---
    Hello, the levy notice is attached. Please confirm you received it.
    """

    @Test func aFileIsReadBeforeItIsCardedAndTheChannelIsAskedOnApproval() throws {
        let s = try setup()
        try write(s, "levy.txt", Self.notice)
        // Without a reading the file waits.
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now, requireReading: true)
        #expect(s.watcher.scan(binders: rows(s), commands: s.commands, now: now, requireReading: true).carded == 0)
        let prepared = s.watcher.prepare(binders: rows(s), deviceID: "dev", reader: .inProcess)
        #expect(s.watcher.scan(binders: rows(s), commands: s.commands, now: now, prepared: prepared, requireReading: true).carded == 1)
        let card = try #require(open(s).first)
        let intake = try #require(card.raw["provenance"]?["intake"])
        #expect(intake["preview"]?.stringValue?.hasPrefix("INVENTED NOTICE") == true)
        #expect(intake["facts"]?["dates"]?.arrayValue?.contains(.str("2026-11-01")) == true)
        #expect(intake["facts"]?["amounts"]?.arrayValue?.contains { $0.stringValue?.contains("450") == true } == true)
        #expect(intake["facts"]?["references"]?.arrayValue?.contains(.str("AB-12345")) == true)
        #expect(intake["obtained"]?["channel"] == .str("other"))
        #expect(card.cardNotes.contains { $0.hasPrefix("how did this reach you") })
        #expect(IntakeReadings(support: s.support).forCard(card.id)?.state == "pending")

        let r = try approve(s, card, [("obtained", .obj([("channel", .str("paper")), ("said", .str("came by post, scanned it"))]))])
        #expect(r["ok"] == .bool(true), "\(r)")
        let doc = Teka.read(s.folder).catalog?["documents"]?.arrayValue?.first { $0["path"]?.stringValue?.hasSuffix("levy.txt") == true }
        #expect(doc?["provenance"]?["obtained"]?["channel"] == .str("paper"))
        #expect(doc?["provenance"]?["obtained"]?["said"] == .str("came by post, scanned it"))
        #expect(doc?["provenance"]?["obtained"]?["text_from"] == .str("parsed"))
        // A channel outside the list is refused.
        try write(s, "second.txt", "Another invented letter.")
        _ = self.card(s)
        let second = try #require(open(s).first)
        #expect(try approve(s, second, [("obtained", .obj([("channel", .str("telepathy"))]))])["ok"] == .bool(false))
    }

    @Test func anEmailIsFiledWithItsAttachmentsAndItsChannelIsKnown() throws {
        let s = try setup()
        try write(s, "mail/2026-10-01_12_levy.md", Self.message)
        try write(s, "mail/2026-10-01_12_levy attachments/levy.txt", Self.notice)
        #expect(card(s).carded == 1)
        let card = try #require(open(s).first)
        #expect(card.ops.count == 2)
        let first = try #require(card.ops.first?["args"])
        #expect(first["document"]?["title"] == .str("Invented levy notice"))
        #expect(first["document"]?["kind"] == .str("email"))
        #expect(first["document"]?["date"] == .str("2026-10-01"))
        #expect(first["document"]?["source"] == .str("intake/mail"))
        #expect(first["document"]?["provenance"]?["obtained"]?["channel"] == .str("email"))
        #expect(first["document"]?["provenance"]?["obtained"]?["from"]?.stringValue?.contains("manager@example.com") == true)
        #expect(card.ops[1]["args"]?["from"] == .str("intake/mail/2026-10-01_12_levy attachments/levy.txt"))
        #expect(!card.cardNotes.contains { $0.hasPrefix("how did this reach you") })
        // The attachment's text is part of the reading.
        #expect(IntakeReadings(support: s.support).forCard(card.id)?.reading.text.contains("special levy") == true)
        let r = try approve(s, card)
        #expect(r["ok"] == .bool(true), "\(r)")
        let docs = Teka.read(s.folder).catalog?["documents"]?.arrayValue ?? []
        #expect(docs.contains { $0["path"]?.stringValue?.hasSuffix("2026-10-01_12_levy.md") == true })
        #expect(docs.contains { $0["path"]?.stringValue?.hasSuffix("/levy.txt") == true && $0["kind"] == .str("attachment") })
        #expect(!FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/mail/2026-10-01_12_levy.md").path))
    }

    func clerkReads(_ s: Setup, reply: Bool = true) async throws -> (DocumentReading, IntakeWatcher.ReadingOutcome) {
        try write(s, "levy.txt", Self.notice)
        _ = card(s)
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("The special levy of $450.00 is due November 1, 2026", "Pay the special levy", "pay", when: "November 1, 2026", amount: "$450.00"),
            item("INVENTED NOTICE, September 30, 2026", "Read the notice", "note"),
        ]))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Notice of special levy")), ("date_text", .str("September 30, 2026")),
                               ("summary", .str("An invented notice asking for a levy payment.")), ("reply_needed", .bool(reply))])
        let entry = try #require(s.watcher.nextForReading())
        let binder = FilingBinder(name: Teka.read(s.folder).name, description: "", folder: s.folder,
                                  openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))
        let doc = await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: binder, now: now)
        return (doc, s.watcher.commitReading(entry, doc, commands: s.commands, now: now))
    }

    @Test func theClerksReadingReplacesTheCodeBuiltCard() async throws {
        let s = try setup()
        let (doc, outcome) = try await clerkReads(s)
        #expect(doc.documentClass == "action")
        #expect(doc.date?.description == "2026-09-30")
        // The "note" item is left out; the reply the notice asks for is added by code.
        #expect(doc.items.map(\.title) == ["Pay the special levy", "Reply about \u{201C}Notice of special levy\u{201D}"])
        #expect(doc.items.last?.whenResolved?.description == "2026-10-20")
        #expect(doc.escalate.contains("a reply may be needed"))
        #expect(outcome.replaced && outcome.items == 2 && outcome.escalated)
        let cards = open(s)
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.title == "File \u{201C}Notice of special levy\u{201D} and add 2 items")
        #expect(card.ops[0]["args"]?["document"]?["date"] == .str("2026-09-30"))
        #expect(card.ops[1]["op"] == .str("add_item"))
        #expect(card.ops[1]["args"]?["item"]?["due"] == .str("2026-11-01"))
        #expect(card.ops[1]["args"]?["item"]?["kind"] == .str("payment"))
        #expect(card.cardNotes.contains { $0.contains("asks you to do something") })
        #expect(card.cardNotes.contains { $0.hasPrefix("a careful reading is recommended") })
        let r = try approve(s, card, [("obtained", .obj([("channel", .str("download"))]))])
        #expect(r["ok"] == .bool(true), "\(r)")
        #expect(Teka.read(s.folder).items.contains { $0.title == "Pay the special levy" })
    }

    @Test func aBrainReadsAndAnswersACarefulReadingWithinItsPermission() async throws {
        let s = try setup()
        _ = try await clerkReads(s)
        let name = Teka.read(s.folder).name
        _ = try call(s, [("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("set_disclosure")),
                         ("args", .obj([("disclosure", .str("full"))]))])
        func server(documents: Bool) -> MCPServer {
            var client = MCPClientRecord(id: "claude-code-1", name: "Claude Code", tokenSHA256: "",
                                         binders: [s.folder.standardizedFileURL.path: "propose"], createdAt: "", revoked: false)
            client.documents = documents ? true : nil
            return MCPServer(client: client, commands: s.commands, shelf: { Shelf.rows(registry: nil, picked: [s.folder]) }, now: { self.now })
        }
        func tool(_ srv: MCPServer, _ name: String, _ args: JSONValue) throws -> JSONValue {
            let line = JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", .int(1)), ("method", .str("tools/call")),
                                                ("params", .obj([("_meta", .obj([("io.modelcontextprotocol/protocolVersion", .str("2026-07-28")),
                                                                                  ("io.modelcontextprotocol/clientCapabilities", .obj([]))])),
                                                                 ("name", .string(name)), ("arguments", args)]))]))
            return try JSONParser.parse(try #require(srv.handle(line: line))).value["result"] ?? .null
        }
        let listed = try tool(server(documents: false), "list_readings", .obj([]))
        let reading = try #require(listed["structuredContent"]?["readings"]?.arrayValue?.first)
        #expect(reading["summary"] == .str("An invented notice asking for a levy payment."))
        let id = try #require(reading["reading_id"]?.stringValue)
        // Without the person's permission the text stays on the Mac.
        #expect(try tool(server(documents: false), "read_document", .obj([("binder", .string(name)), ("reading_id", .string(id))]))["isError"] == .bool(true))
        let text = try tool(server(documents: true), "read_document", .obj([("binder", .string(name)), ("reading_id", .string(id))]))
        #expect(text["structuredContent"]?["text"]?.stringValue?.contains("special levy") == true)
        let proposed = try tool(server(documents: true), "propose_ops", .obj([
            ("binder", .string(name)), ("title", .str("Confirm the payment method")), ("reading_id", .string(id)),
            ("ops", .array([.obj([("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Confirm the payment method")),
                                                                                            ("status", .str("open")), ("priority", .str("normal")), ("due", .str("2026-10-20"))]))]))])])),
        ]))
        #expect(proposed["isError"] == .bool(false), "\(proposed)")
        #expect(IntakeReadings(support: s.support).load(id)?.escalation == "answered")
        #expect(try tool(server(documents: true), "list_readings", .obj([]))["structuredContent"]?["readings"]?.arrayValue?.isEmpty == true)
    }
}

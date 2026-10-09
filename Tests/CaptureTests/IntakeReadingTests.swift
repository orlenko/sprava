import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
import Shelf
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

    @Test func aMailMessageAndItsAttachmentsAreOneCandidate() throws {
        let s = try setup()
        try write(s, "mail/.env", "IMAP_PASSWORD=invented")
        try write(s, "mail/state.json", "{}")
        try write(s, "mail/2026-10-01_12_levy.md", Self.message)
        try write(s, "mail/2026-10-01_12_levy attachments/levy.txt", Self.notice)
        try write(s, "mail/notes.log", "not a message")
        let c = IntakeWatcher.candidates(in: s.folder)
        #expect(c.map(\.name) == ["mail/2026-10-01_12_levy.md"])
        #expect(c.first?.attachments == ["mail/2026-10-01_12_levy attachments/levy.txt"])
        #expect(c.first?.channel == "email")
    }

    @Test func anUnreadableFileIsHeldWithACardThatSaysWhy() throws {
        let s = try setup()
        try Data([0x00, 0x13, 0x37, 0x00, 0xFE, 0xED, 0x00, 0x01]).write(to: s.folder.appendingPathComponent("intake/blob.jpg"))
        let r = card(s)
        #expect(r.carded == 1 && r.held == 1)
        let card = try #require(open(s).first)
        #expect(card.title.hasPrefix("Held:"))
        #expect(card.cardNotes.contains { $0.hasPrefix("held, not read") })
        #expect(IntakeReadings(support: s.support).forCard(card.id) == nil)
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

    @Test func aRejectedCardLeavesTheCarefulReadingQueue() async throws {
        let s = try setup()
        _ = try await clerkReads(s)
        #expect(IntakeReadings(support: s.support).escalations().count == 1)
        let card = try #require(open(s).first)
        try TekaStore(folder: s.folder).reject(card, now: now)
        #expect(IntakeReadings(support: s.support).escalations().isEmpty)
    }

    @Test func aFileThatGoesWithdrawsTheClerksCard() async throws {
        let s = try setup()
        _ = try await clerkReads(s, reply: false)
        #expect(open(s).count == 1)
        try FileManager.default.removeItem(at: s.folder.appendingPathComponent("intake/levy.txt"))
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now, requireReading: true)
        #expect(open(s).isEmpty)
    }
}

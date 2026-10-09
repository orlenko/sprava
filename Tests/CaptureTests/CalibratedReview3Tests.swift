import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the third calibrated review of the capture layer: what reaches a binder through intake is private
/// by default on every path, a binder that was away still gets a raise to private before anything in it is approved,
/// and a producer clock outside the reader's range is never used. Invented data only.
@Suite(.serialized) struct CalibratedReview3Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    struct Setup {
        let support: URL
        let commands: Commands
        let folder: URL
        let watcher: IntakeWatcher
    }

    func setup() throws -> Setup {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-review3-\(UUID().uuidString)")
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
    Hello, the levy of $450.00 is due November 1, 2026. Please pay it by then.
    """

    // MARK: - 1. Intake is private by default, on every path

    enum Channel: String, CaseIterable { case document, email, unreadable }
    enum Path: String, CaseIterable { case codeBuilt, clerk, escalated }

    /// Puts one file of `channel` into intake and cards it the way `path` does. Returns the cards it made.
    func cards(_ channel: Channel, _ path: Path, _ s: Setup) async throws -> [Proposal] {
        switch channel {
        case .document: try write(s, "levy.txt", Self.notice)
        case .email:
            try write(s, "mail/2026-10-01_12_levy.md", Self.message)
            try write(s, "mail/2026-10-01_12_levy attachments/levy.txt", Self.notice)
        case .unreadable: try Data([0x00, 0x13, 0x37, 0x00, 0xFE]).write(to: s.folder.appendingPathComponent("intake/scan.jpg"))
        }
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now, requireReading: true)
        let prepared = s.watcher.prepare(binders: rows(s), deviceID: "dev", reader: .inProcess)
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now, prepared: prepared, requireReading: true)
        guard path != .codeBuilt, let entry = s.watcher.nextForReading() else { return open(s) }
        let quote = channel == .email ? "the levy of $450.00 is due November 1, 2026" : "The special levy of $450.00 is due November 1, 2026"
        let model = ScriptedModel(extractions: [.obj([("items", .array([item(quote, "Pay the special levy", "pay", when: "November 1, 2026",
                                                                              amount: "$450.00")]))])])
        model.document = .obj([("class", .str(path == .escalated ? "governing" : "action")), ("title", .str("Notice of special levy")),
                               ("date_text", .str("September 30, 2026")), ("summary", .str("An invented notice.")),
                               ("reply_needed", .bool(path == .escalated))])
        let binder = FilingBinder(name: Teka.read(s.folder).name, description: "", folder: s.folder,
                                  openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))
        let doc = await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: binder, now: now)
        let outcome = s.watcher.commitReading(entry, doc, commands: s.commands, now: now)
        #expect(outcome.replaced, "\(channel) \(path): the clerk's card replaced the code-built one")
        if path == .escalated { #expect(outcome.escalated) }
        return open(s)
    }

    @Test(arguments: Channel.allCases, Path.allCases)
    func nothingFromIntakeIsFiledInTheClear(channel: Channel, path: Path) async throws {
        let s = try setup()
        let fixture = Set((Teka.read(s.folder).catalog?["documents"]?.arrayValue ?? []).compactMap { $0["id"]?.stringValue })
        let made = try await cards(channel, path, s)
        #expect(!made.isEmpty)
        for card in made {
            #expect(card.raw["provenance"]?["private"] == .bool(true), "\(channel) \(path): the card says private")
            for op in card.ops {
                switch op["op"]?.stringValue {
                case "file_document": #expect(op["args"]?["document"]?["redact"] == .bool(true), "\(channel) \(path): a document in the clear")
                case "add_item": #expect(op["args"]?["item"]?["redact"] == .bool(true), "\(channel) \(path): an item in the clear")
                case "update_item": #expect(op["args"]?["set"]?["redact"] == .bool(true), "\(channel) \(path): an update in the clear")
                default: break
                }
            }
            // Approved as it is, everything it filed stays redacted.
            _ = try? TekaStore(folder: s.folder).approve(card, now: now)
        }
        let catalog = Teka.read(s.folder).catalog
        // The documents this intake filed (the fixture has its own).
        let documents = (catalog?["documents"]?.arrayValue ?? []).filter { !fixture.contains($0["id"]?.stringValue ?? "") }
        #expect(path == .codeBuilt && channel == .unreadable || !documents.isEmpty)
        #expect(documents.allSatisfy { $0["redact"] == .bool(true) }, "\(documents.map { JSONWriter.compact($0) })")
        let items = Teka.read(s.folder).items.compactMap(\.object).filter { $0["title"] == .str("Pay the special levy") }
        #expect(items.allSatisfy { $0["redact"] == .bool(true) && $0["kind"] != nil })
    }

    // MARK: - 2. A binder that was away gets the raise before anything in it is approved

    let adapter = "11111111-2222-4333-8444-5555555555f3"

    @Test func aBinderThatWasAwayIsRaisedBeforeItsCardIsApproved() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "A1", revision: "rev1", text: "Call the invented roofer")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
        let card = try #require(pOpen(s).first)

        // The binder's volume goes away; a private revision with the same words arrives meanwhile.
        let away = s.folder.deletingLastPathComponent().appendingPathComponent(s.folder.lastPathComponent + ".away")
        try FileManager.default.moveItem(at: s.folder, to: away)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "A1", revision: "rev2", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.hasDeferredWork(in: s.folder))
        #expect(!s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))   // still away: the approval waits

        // Back: the approval path settles first, and the card it then approves is private.
        try FileManager.default.moveItem(at: away, to: s.folder)
        #expect(s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))
        #expect(!s.inbox.hasDeferredWork(in: s.folder))
        let fresh = try #require(pOpen(s).first { $0.id == card.id })
        #expect(fresh.raw["provenance"]?["private"] == .bool(true))
        _ = try TekaStore(folder: s.folder).approve(fresh, now: pNow)
        let item = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Call the invented roofer") })
        #expect(item["redact"] == .bool(true))
    }

    @Test func aSweepFinishesWhatABinderMissedOnceItIsBack() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "A2", revision: "rev1", text: "Call the invented roofer")
        try bFileAndApprove(s)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "A2", revision: "rev2", text: "Call the invented roofer Monday")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let correction = try #require(pOpen(s).first)

        let away = s.folder.deletingLastPathComponent().appendingPathComponent(s.folder.lastPathComponent + ".away")
        try FileManager.default.moveItem(at: s.folder, to: away)
        // Deleted where it was taken, privately, while the binder is away.
        let retraction = try pEvent(s, device: adapter, app: "adapter", ref: "A2", revision: "retracted", text: "") {
            $0.set("retracted", .bool(true)); $0.set("sensitivity", .str("private"))
        }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try FileManager.default.moveItem(at: away, to: s.folder)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)

        // The old correction is withdrawn, and the removal card redacts the item before it drops it.
        #expect(!pOpen(s).contains { $0.id == correction.id })
        let removal = try #require(pOpen(s).first { $0.raw["provenance"]?["retraction"] == .string(retraction) })
        #expect(removal.ops.map { $0["op"]?.stringValue ?? "" } == ["update_item", "drop"])
        #expect(!s.inbox.hasDeferredWork(in: s.folder))
    }

    @Test func whatABinderMissedWaitsForAnEventACrashLeftUnfinished() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "A3", revision: "rev1", text: "Call the invented roofer")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        try s.inbox.file(try #require(s.inbox.unfiled().first).id, into: s.folder, commands: s.commands)
        let old = try #require(pOpen(s).first)

        let away = s.folder.deletingLastPathComponent().appendingPathComponent(s.folder.lastPathComponent + ".away")
        try FileManager.default.moveItem(at: s.folder, to: away)
        let revised = try pEvent(s, device: adapter, app: "adapter", ref: "A3", revision: "rev2", text: "Call the invented roofer Monday")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        // A crash kept the revision's stage from the cursor, though its card was made.
        var state = try s.inbox.readState()
        state.ingested[revised] = "ingested"
        try s.inbox.save(state)
        try FileManager.default.moveItem(at: away, to: s.folder)

        // Until a sweep finishes the revision, what is current is not known: nothing is withdrawn, the approval waits.
        #expect(!s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))
        #expect(pOpen(s).contains { $0.id == old.id })
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(!pOpen(s).contains { $0.id == old.id })
        #expect(s.inbox.unfiled().contains { $0.raw["provenance"]?["events"] == .array([.string(revised)]) })
        #expect(s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))
    }

    @Test func aHandOffWaitsForABinderThatIsAway() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "A4", revision: "rev1", text: "Call the invented notary")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let tier0 = try #require(s.inbox.unfiled().first)
        // The clerk saved and trusted its card, the commit failed, and Sprava took the card back; the run stopped before
        // the hand-off record was cleared.
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("invented"))])
        let item = JSONValue.obj([("id", .str("$new:1")), ("title", .str("Call the invented notary")), ("status", .str("open")),
                                  ("priority", .str("normal")), ("no_deadline", .bool(true))])
        let card = Proposal.make(title: "Call the invented notary", actor: actor,
                                 ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", item)]))])],
                                 provenance: JSONObject([(key: "events", value: .array([.string(id)]))]), now: pNow)
        try ProposalStore.save(card, in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)
        try TekaStore(folder: s.folder).reject(card, reason: CaptureInbox.takenBack, now: pNow)
        var state = try s.inbox.readState()
        state.handoffs = [id: [.init(binder: s.folder.path, card: card.id)]]
        try s.inbox.save(state)

        // While the binder is away, what happened to that card is not known: the record waits and the code-built card stays.
        let away = s.folder.deletingLastPathComponent().appendingPathComponent(s.folder.lastPathComponent + ".away")
        try FileManager.default.moveItem(at: s.folder, to: away)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().map(\.id) == [tier0.id])
        #expect(try s.inbox.readState().handoffs?[id] != nil)

        try FileManager.default.moveItem(at: away, to: s.folder)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().map(\.id) == [tier0.id])
        #expect(try s.inbox.readState().handoffs?[id] == nil)
    }

    @Test func aSecondRetractionIsNoCopyOfAFirstLeftUnfinished() throws {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "A5", revision: "rev1", text: "Call the invented roofer")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "A5", revision: "retracted", text: "") { $0.set("retracted", .bool(true)) }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        // A crash kept the first retraction's stage from the cursor.
        var state = try s.inbox.readState()
        state.ingested[first] = "ingested"
        try s.inbox.save(state)
        // Restored, then deleted again: the second retraction repeats the first one's app, ref and revision.
        let restore = try pEvent(s, device: adapter, app: "adapter", ref: "A5", revision: "rev3", text: "Call the invented roofer again")
        let second = try pEvent(s, device: adapter, app: "adapter", ref: "A5", revision: "retracted", text: "") { $0.set("retracted", .bool(true)) }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(!s.inbox.unfiled().contains { $0.raw["provenance"]?["events"] == .array([.string(restore)]) })
        state = try s.inbox.readState()
        #expect(["retracted", "duplicate"].contains(state.ingested[second] ?? "") && state.ingested[first] != "ingested")
    }

    // MARK: - 3. A producer clock outside the reader's range is never used

    func noteFile(_ s: PSetup, wall: Int, counter: Int) throws {
        try AtomicFile.makePrivateFolder(s.producer.folder)
        let id = "01a10000-0000-7000-8000-0000000000f1"
        let o = JSONValue.obj([("format", .str("sprava-capture-event")), ("format_version", .str("0")), ("id", .str(id)),
                               ("hlc", .obj([("wall_ms", .int(wall)), ("counter", .int(counter)),
                                             ("node", .string(pDevice.replacingOccurrences(of: "-", with: "")))]))])
        try Data(JSONWriter.pretty(o).utf8).write(to: s.producer.folder.appendingPathComponent("\(id).json"))
    }

    @Test func aMalformedPublishedStampNeverSetsTheClock() throws {
        let s = try pSetup()
        try noteFile(s, wall: 10_000_000_000_000, counter: 0)
        let note = try s.producer.prepareNote("Call the invented roofer", startedAt: pNow, savedAt: pNow, locale: "en-CA")
        let wall = try #require(note.event["hlc"]?["wall_ms"]?.numberValue?.safeInteger)
        #expect(wall == Int64(pNow.timeIntervalSince1970 * 1000))
        try s.inbox.recordNotice(event: note.id, digest: note.digest)
        try s.producer.publish(note)
        let r = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow.addingTimeInterval(60))
        #expect(r.quarantined == 1 && r.unfiled == 1)   // the malformed file, then the note
    }

    @Test func aStoredStampOutsideTheRangeIsUnreadableAndAnExhaustedClockStops() throws {
        let s = try pSetup()
        let node = pDevice.replacingOccurrences(of: "-", with: "")
        let stateURL = s.support.appendingPathComponent("capture/producer-hlc.json")
        try AtomicFile.makePrivateFolder(stateURL.deletingLastPathComponent())
        try JSONEncoder().encode(HLC(wall_ms: 10_000_000_000_000, counter: 0, node: node)).write(to: stateURL)
        #expect(throws: StateFile.Unreadable.self) { _ = try s.producer.prepareNote("Invented", startedAt: pNow, savedAt: pNow) }

        // The last wall time a reader accepts, with its counter used up: the next stamp would roll past it.
        try JSONEncoder().encode(HLC(wall_ms: 9_999_999_999_999, counter: 65_535, node: node)).write(to: stateURL)
        #expect(throws: HLC.OutOfRange.self) { _ = try s.producer.prepareNote("Invented", startedAt: pNow, savedAt: pNow) }
    }
}

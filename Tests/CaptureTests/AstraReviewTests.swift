import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Darwin
import Extract
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the adversarial review of increment 1 (proposal ids, privacy raises, offload, readings,
/// state files that cannot be read, the clerk's and the Inbox's hand-overs, the document reader, MCP logs).
/// Invented data only.
@Suite(.serialized) struct AstraReviewTests {
    let clerk = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("none"))])

    let garbage = Data("{\"broken".utf8)

    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws -> String {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
        return n.id
    }

    // MARK: - 1. A proposal id names a file only when it is a UUID

    @Test func proposalIDsNeverReachOutsideTheirFolder() throws {
        let s = try pSetup()
        let catalogURL = s.folder.appendingPathComponent("catalog.json")
        let before = try Data(contentsOf: catalogURL)
        var forged = Proposal.make(title: "Invented card", actor: clerk, ops: [], now: pNow)
        forged.raw.set("id", .str("../../catalog"))
        #expect(throws: (any Error).self) { try ProposalStore.save(forged, in: s.folder) }
        #expect(throws: (any Error).self) { try ProposalStore.load("../../catalog", in: s.folder, expectedDigest: nil) }
        #expect(try Data(contentsOf: catalogURL) == before)

        // A file whose name and inner id disagree is neither listed nor loaded, so nothing rewrites it by that id.
        let dir = try ProposalStore.checkedDir(s.folder, create: true)
        let name = UUIDv7.make(now: pNow)
        let bytes = Data(JSONWriter.pretty(.object(forged.raw)).utf8)
        try bytes.write(to: dir.appendingPathComponent("\(name).json"))
        try bytes.write(to: dir.appendingPathComponent("notes.json"))
        #expect(!ProposalStore.list(in: s.folder).contains { $0.0.id == "../../catalog" || $0.0.id == name })
        #expect(throws: (any Error).self) { try ProposalStore.load(name, in: s.folder, expectedDigest: nil) }
    }

    @Test func unfiledCardIDsNeverReachOutsideTheirFolder() throws {
        let s = try pSetup()
        var forged = Proposal.make(title: "Invented card", actor: clerk, ops: [], now: pNow)
        forged.raw.set("id", .str("../capture/state"))
        let name = UUIDv7.make(now: pNow)
        #expect(throws: (any Error).self) { try s.inbox.writeUnfiled(forged.raw) }
        #expect(!FileManager.default.fileExists(atPath: s.inbox.dir.appendingPathComponent("state.json").path))
        #expect(throws: (any Error).self) { try s.inbox.discard("../capture/state") }
        let good = Proposal.make(title: "Invented card", actor: clerk, ops: [], now: pNow)
        try s.inbox.writeUnfiled(good.raw)
        #expect(s.inbox.unfiled().map(\.id) == [good.id])
        // A card under another card's name is not shown, even with a digest recorded for that name.
        var renamed = good.raw
        renamed.set("id", .string(UUIDv7.make(now: pNow)))
        let renamedBytes = Data(JSONWriter.pretty(.object(renamed)).utf8)
        var digests = try s.inbox.unfiledDigests()
        digests[name] = CaptureInbox.digest(renamedBytes)
        try s.inbox.saveUnfiledDigests(digests)
        try renamedBytes.write(to: s.inbox.unfiledDir.appendingPathComponent("\(name).json"))
        #expect(s.inbox.unfiled().map(\.id) == [good.id])
    }

    // MARK: - 6. An intake cursor that cannot be read is reported and kept

    @Test func anUnreadableIntakeCursorIsReportedAndKept() throws {
        let s = try pSetup()
        let watcher = IntakeWatcher(support: s.support)
        let intake = s.folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("An invented letter.".utf8).write(to: intake.appendingPathComponent("letter.txt"))
        try AtomicFile.makePrivateFolder(watcher.stateURL.deletingLastPathComponent())
        try garbage.write(to: watcher.stateURL)

        let r = watcher.scan(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(r.cursorUnreadable && r.carded == 0 && r.waiting == 0)
        #expect(watcher.prepare(binders: pRows(s), deviceID: "dev", reader: .inProcess).readings.isEmpty)
        #expect(try Data(contentsOf: watcher.stateURL) == garbage)
        try FileManager.default.removeItem(at: watcher.stateURL)
        #expect(!watcher.scan(binders: pRows(s), commands: s.commands, now: pNow).cursorUnreadable)
    }

    // MARK: - 7. A clerk card that cannot be trusted leaves the code-built card

    @Test func aClerkCardThatCannotBeTrustedLeavesTheCodeBuiltCard() async throws {
        let s = try pSetup()
        _ = try note(s, "Call the invented notary about the deed", hint: "estate-example")
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let work = try #require(s.inbox.nextForClerk())
        let model = RecordingModel([.obj([("items", .array([item("Call the invented notary", "Call the notary", "call")]))])])
        // A hint files only into a binder on the filing list.
        let filing = [FilingBinder(name: "estate-example", description: "Estate: notary, inventory", folder: s.folder,
                                   words: FilingBinder.significantWords("estate inventory notary"))]
        let interp = await Clerk(model: model).read(work.event, filing: filing, hint: work.hint, now: pNow)
        try garbage.write(to: s.commands.digestsURL)

        let out = s.inbox.commitClerk(work, interp, filing: filing, rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(!out.replaced && out.filed == 0)
        #expect(pOpen(s).map(\.id) == [work.tier0])
        #expect(try s.inbox.readState().clerk?[work.event.id] == "retry")
        // Once the record can be written again, the reading is tried again and replaces the card.
        try FileManager.default.removeItem(at: s.commands.digestsURL)
        try s.commands.trustProposals([work.tier0], in: s.folder)
        let again = try #require(s.inbox.nextForClerk())
        let retried = s.inbox.commitClerk(again, interp, filing: filing, rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(retried.replaced)
        #expect(!pOpen(s).map(\.id).contains(work.tier0))
    }

    // MARK: - 9. A missing document reader holds the file

    @Test func aMissingReaderHoldsTheFileAndInProcessReadingIsExplicit() throws {
        let s = try pSetup()
        let watcher = IntakeWatcher(support: s.support)
        let intake = s.folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("An invented letter about the levy.".utf8).write(to: intake.appendingPathComponent("letter.txt"))
        #expect(throws: ExtractHelper.Failure.self) { try ExtractHelper.run(Data("x".utf8), name: "x.txt", reader: .missing) }
        let reading = IntakeReading.read(intake.appendingPathComponent("letter.txt"), in: s.folder, channel: "other", reader: .missing)
        #expect(reading.held?.contains("missing") == true && reading.text.isEmpty)

        _ = watcher.scan(binders: pRows(s), commands: s.commands, now: pNow, requireReading: true)
        let prepared = watcher.prepare(binders: pRows(s), deviceID: "dev", reader: .missing)
        let r = watcher.scan(binders: pRows(s), commands: s.commands, now: pNow, prepared: prepared, requireReading: true)
        #expect(r.carded == 1 && r.held == 1)
        let card = try #require(pOpen(s).first)
        #expect(card.title.hasPrefix("Held:"))
        #expect(card.cardNotes.contains { $0.contains("reader") && $0.contains("missing") })
        // Reading in this process happens only when asked for by name.
        #expect(try ExtractHelper.run(Data("An invented note.".utf8), name: "note.txt", reader: .inProcess).text.contains("invented"))
    }
}

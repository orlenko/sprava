import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from Codex Bugbot's fourth pass over the final capture layer (PR #13): an unreadable or failed step
/// keeps the work owed. Invented data only.
@Suite(.serialized) struct BugbotFinal4Tests {
    let adapter = "11111111-2222-4333-8444-555555555501"
    let other = "22222222-2222-4333-8444-555555555501"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        try s.inbox.registerProducer(folder: other, app: "adapter")
        return s
    }

    @discardableResult
    func sweep(_ s: PSetup, _ rows: [ShelfRow]? = nil) -> CaptureInbox.SweepResult {
        s.inbox.sweep(binders: rows ?? pRows(s), commands: s.commands, now: pNow)
    }

    func from(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"] == .array([.string(id)]) }

    /// A note carded and filed into the binder, waiting there.
    func filed(_ s: PSetup, ref: String, text: String) throws -> (String, Proposal) {
        let id = try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: "rev1", text: text)
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { from($0, id) }).id, into: s.folder, commands: s.commands)
        return (id, try #require(pOpen(s).first { from($0, id) }))
    }

    // MARK: - MUST-FIX

    @Test func noBinderIsTouchedBeforeAPrivacyRaiseIsOnDisk() throws {
        let s = try setup()
        let (_, card) = try filed(s, ref: "R1", text: "Call the invented roofer")
        // A private copy of the same capture from the other device: a duplicate that raises the chain. The cursor
        // cannot be saved.
        _ = try pEvent(s, device: other, app: "adapter", ref: "R1", revision: "rev1", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
        }
        CursorCrash.after(0, cursor: s.inbox.stateURL)
        sweep(s)
        CursorCrash.after(nil, cursor: s.inbox.stateURL)
        #expect(pOpen(s).first { $0.id == card.id }?.raw["provenance"]?["private"] != .bool(true), "nothing was done with nothing on disk")
        // Once the cursor can be saved, the copy is taken in again and the raise is done.
        sweep(s)
        #expect(pOpen(s).first { $0.id == card.id }?.raw["provenance"]?["private"] == .bool(true))
    }

    @Test func aNoteIsNotStampedWhileAPublishedEventCannotBeRead() throws {
        let s = try setup()
        let (event, _) = try s.producer.writeNote("Call the invented roofer", startedAt: pNow, savedAt: pNow, locale: "en-CA")
        let file = s.producer.root.appendingPathComponent(pDevice).appendingPathComponent("\(event["id"]!.stringValue!).json")
        try FileManager.default.removeItem(at: s.support.appendingPathComponent("capture/producer-hlc.json"))
        chmod(file.path, 0o000)
        defer { chmod(file.path, 0o600) }
        #expect(throws: (any Error).self) { _ = try s.producer.prepareNote("Pay the invented levy", startedAt: pNow, savedAt: pNow, locale: "en-CA") }
    }

    @Test func aHintedCardThatCannotBeTrustedLeavesNoCopyInTheBinder() throws {
        let s = try pSetup()
        let (event, digest) = try s.producer.writeNote("Call the invented notary about the deed", binderHint: "estate-example",
                                                       startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: event["id"]!.stringValue!, digest: digest)
        // The record of written cards can be read but not written: the binder's copy can be saved, never trusted.
        let runtime = s.commands.digestsURL.deletingLastPathComponent()
        try AtomicFile.makePrivateFolder(runtime)
        chmod(runtime.path, 0o500)
        defer { chmod(runtime.path, 0o700) }
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: Date())
        chmod(runtime.path, 0o700)
        #expect(pOpen(s).isEmpty, "no untrusted copy waits in the binder")
        #expect(s.inbox.unfiled().count == 1, "the card waits in the Inbox instead")
    }

    @Test func workForABinderOffTheShelfIsKeptWhileTheRecordOfWrittenCardsCannotBeRead() throws {
        let s = try setup()
        let (_, card) = try filed(s, ref: "D1", text: "Call the invented roofer")
        _ = try TekaStore(folder: s.folder).approve(card, now: pNow)
        // The binder leaves the shelf (it is known only from the record), and the record cannot be read.
        let digests = s.commands.digestsURL
        chmod(digests.path, 0o000)
        defer { chmod(digests.path, 0o600) }
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "D1", revision: "rev2", text: "Call the invented roofer Monday")
        sweep(s, [])
        chmod(digests.path, 0o600)
        sweep(s, [])
        #expect(s.inbox.hasDeferredWork(in: s.folder), "the binder still owes the correction")
        // Back on the shelf, its item is corrected.
        sweep(s)
        let item = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Call the invented roofer") })
        #expect(pOpen(s).contains { p in p.ops.contains { $0["args"]?["id"] == item["id"] && $0["args"]?["set"]?["title"] == .str("Call the invented roofer Monday") } })
    }

    // MARK: - Issues fixed here

    @Test func aMistypedEstimatedMarkIsQuarantined() throws {
        let s = try setup()
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "E1", revision: "rev1", text: "Call the invented roofer tomorrow") {
            $0.set("captured_at_estimated", .str("true"))
        }
        #expect(sweep(s).quarantined == 1)
    }

    @Test func anIntakeEntryKeepsItsOldCardUntilThatCardIsWithdrawn() throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "levy.txt", IntakeReadingTests.notice)
        _ = t.card(s)
        let old = try #require(t.open(s).first)
        // The file changes while no card in the binder can be written.
        try t.write(s, "levy.txt", IntakeReadingTests.notice + " Changed.")
        let proposals = ProposalStore.dir(s.folder)
        chmod(proposals.path, 0o500)
        _ = s.watcher.scan(binders: t.rows(s), commands: s.commands, now: t.now)
        chmod(proposals.path, 0o700)
        #expect(try s.watcher.load()[s.folder.standardizedFileURL.path]?["levy.txt"]?.card == old.id, "the cursor still follows the old card")
        _ = t.card(s)
        _ = t.card(s)
        #expect(!t.open(s).contains { $0.id == old.id })
        #expect(t.open(s).count == 1, "one card for the file, never two")
    }

    @Test func eachReadingIsKeptUnderItsOwnId() async throws {
        let s = try pSetup()
        let (event, digest) = try s.producer.writeNote("Call the invented notary about the deed", binderHint: "estate-example",
                                                       startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: event["id"]!.stringValue!, digest: digest)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: Date())
        let work = try #require(s.inbox.nextForClerk())
        let interp = await Clerk(model: RecordingModel([.obj([("items", .array([item("Call the invented notary about the deed", "Call the notary")]))])]))
            .read(work.event, filing: [bFiling(s)], hint: work.hint, now: pNow)
        _ = s.inbox.commitClerk(work, interp, filing: [bFiling(s)], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        let stored = s.inbox.dir.appendingPathComponent("interpretations/\(work.event.id)/\(interp.id).json")
        #expect(FileManager.default.fileExists(atPath: stored.path))
        #expect(pOpen(s).contains { $0.raw["provenance"]?["interpretation"] == .string(interp.id) })
    }

    @Test func aWithdrawnReadCardRetiresItsCarefulReading() async throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        _ = try await t.clerkReads(s)
        let entry = try #require(IntakeReadings(support: s.support).all().first)
        #expect(entry.state == "read" && entry.escalation == "waiting")
        try FileManager.default.removeItem(at: s.folder.appendingPathComponent("intake/levy.txt"))
        _ = s.watcher.scan(binders: t.rows(s), commands: s.commands, now: t.now)
        let after = try #require(IntakeReadings(support: s.support).load(entry.id))
        #expect(after.state == "gone" && after.escalation == nil)
    }

    @Test func anApprovedCardKeepsItsCarefulReadingWaiting() async throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        _ = try await t.clerkReads(s)
        let entry = try #require(IntakeReadings(support: s.support).all().first)
        #expect(entry.state == "read" && entry.escalation == "waiting")
        // Approving the filing card moves the document out of intake/; the next scan finds it gone.
        let card = try #require(t.open(s).first { $0.id == entry.card })
        _ = try TekaStore(folder: s.folder).approve(card, now: t.now)
        #expect(!FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/levy.txt").path))
        _ = s.watcher.scan(binders: t.rows(s), commands: s.commands, now: t.now)
        let after = try #require(IntakeReadings(support: s.support).load(entry.id))
        #expect(after.state == "read" && after.escalation == "waiting", "the careful reading still waits for the brain")
    }
}

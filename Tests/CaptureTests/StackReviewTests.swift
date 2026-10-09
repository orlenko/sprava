import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the review of the capture layer (privacy raised while the clerk reads, unfiled cards rewritten
/// in place, restores and deletions of a chain, retractions cut short, intake folders out of reach, large
/// corrections, the intake cursor's handoff, the producer's clock, and flushes). Invented data only.
@Suite(.serialized) struct StackReviewTests {
    let adapter = "11111111-2222-4333-8444-5555555555e7"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    func event(_ s: PSetup, ref: String, revision: String, text: String, extra: (inout JSONObject) -> Void = { _ in }) throws -> String {
        try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: revision, text: text, extra: extra)
    }

    func retraction(_ s: PSetup, ref: String, of earlier: String) throws -> String {
        try event(s, ref: ref, revision: "retracted", text: "") { $0.set("retracted", .bool(true)); $0.set("supersedes", .string(earlier)) }
    }

    func sweep(_ s: PSetup) { _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func stage(_ s: PSetup, _ id: String) throws -> String? { try s.inbox.readState().ingested[id] }

    func cards(from id: String, in unfiled: [Proposal]) -> [Proposal] {
        unfiled.filter { $0.raw["provenance"]?["events"]?.arrayValue?.contains(.string(id)) == true }
    }

    // MARK: - 1. A raise to private that comes while the clerk reads holds for the clerk's cards

    @Test func aRaiseWhileTheClerkReadsMakesItsCardsPrivate() async throws {
        let s = try setup()
        let text = "Order new blinds for the kitchen."
        _ = try event(s, ref: "P1", revision: "rev1", text: text)
        sweep(s)
        let work = try #require(s.inbox.nextForClerk())
        #expect(!work.event.isPrivate)
        // The same capture again, now private, before the clerk's cards are kept.
        _ = try event(s, ref: "P1", revision: "rev1", text: text) { $0.set("sensitivity", .str("private")) }
        sweep(s)

        let model = ScriptedModel(extractions: [.obj([("items", .array([item("Order new blinds", "Order blinds")]))])])
        let interp = await Clerk(model: model).read(work.event, filing: [], hint: nil, now: pNow)
        let out = s.inbox.commitClerk(work, interp, filing: [], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(out.replaced && out.unsure == 1)
        let unfiled = s.inbox.unfiled()
        #expect(unfiled.count == 1)
        for card in unfiled {
            #expect(card.raw["provenance"]?["private"] == .bool(true))
            for op in card.ops { #expect(op["args"]?["item"]?["redact"] == .bool(true)) }
        }
    }

    @Test func aLaterRevisionOfAPrivateChainStaysPrivate() throws {
        let s = try setup()
        _ = try event(s, ref: "P2", revision: "rev1", text: "Call the roofer") { $0.set("sensitivity", .str("private")) }
        sweep(s)
        let later = try event(s, ref: "P2", revision: "rev2", text: "Call the roofer on Monday")
        sweep(s)
        let card = try #require(cards(from: later, in: s.inbox.unfiled()).first)
        #expect(card.raw["provenance"]?["private"] == .bool(true))
        #expect(card.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) })
    }

    // MARK: - 2. An unfiled card whose rewrite fails stays shown, and the rewrite is tried again

    @Test func aFailedRewriteNeverHidesAnUnfiledCard() throws {
        let s = try setup()
        _ = try event(s, ref: "U1", revision: "rev1", text: "Renew the invented passport")
        sweep(s)
        let card = try #require(s.inbox.unfiled().first)
        chmod(s.inbox.unfiledDir.path, 0o500)
        defer { chmod(s.inbox.unfiledDir.path, 0o700) }
        let raise = try event(s, ref: "U1", revision: "rev1", text: "Renew the invented passport") { $0.set("sensitivity", .str("private")) }
        sweep(s)
        #expect(s.inbox.unfiled().map(\.id) == [card.id])
        #expect(try s.inbox.readState().raises?[raise] != nil)

        chmod(s.inbox.unfiledDir.path, 0o700)
        sweep(s)
        let now = try #require(s.inbox.unfiled().first)
        #expect(now.id == card.id && now.raw["provenance"]?["private"] == .bool(true))
        #expect(try s.inbox.readState().raises?[raise] == nil)
        #expect(try s.inbox.unfiledDigests()[card.id]?.contains(" ") == false)
    }

    // MARK: - 3. A restore and a second deletion are never taken for duplicates

    @Test func aRestoreWithTheSameRevisionIsNewContent() throws {
        let s = try setup()
        let first = try event(s, ref: "D1", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        let gone = try retraction(s, ref: "D1", of: first)
        sweep(s)
        #expect(s.inbox.unfiled().isEmpty)
        #expect(try stage(s, gone) == "retracted")
        let restored = try event(s, ref: "D1", revision: "rev1", text: "Call the invented roofer") { $0.set("supersedes", .string(gone)) }
        sweep(s)
        #expect(try stage(s, restored) == "unfiled")
        #expect(cards(from: restored, in: s.inbox.unfiled()).count == 1)
    }

    @Test func aDeletionAfterARestoreIsApplied() throws {
        let s = try setup()
        let first = try event(s, ref: "D2", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        let gone = try retraction(s, ref: "D2", of: first)
        sweep(s)
        let restored = try event(s, ref: "D2", revision: "rev2", text: "Call the invented roofer today") { $0.set("supersedes", .string(gone)) }
        sweep(s)
        #expect(cards(from: restored, in: s.inbox.unfiled()).count == 1)
        let goneAgain = try retraction(s, ref: "D2", of: restored)
        sweep(s)
        #expect(try stage(s, goneAgain) == "retracted")
        #expect(s.inbox.unfiled().isEmpty)
    }

    // MARK: - 4. A retraction that could not be done in full is tried again

    @Test func aRetractionThatCannotWithdrawIsRetried() throws {
        let s = try setup()
        let first = try event(s, ref: "W1", revision: "rev1", text: "Book the invented dentist")
        sweep(s)
        #expect(s.inbox.unfiled().count == 1)
        chmod(s.inbox.unfiledDir.path, 0o500)
        defer { chmod(s.inbox.unfiledDir.path, 0o700) }
        let gone = try retraction(s, ref: "W1", of: first)
        sweep(s)
        #expect(try stage(s, gone) == "retracting")

        chmod(s.inbox.unfiledDir.path, 0o700)
        sweep(s)
        #expect(try stage(s, gone) == "retracted")
        #expect(s.inbox.unfiled().isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: s.inbox.unfiledDir.path).filter { $0.hasSuffix(".json") }.isEmpty)
    }

    @Test func aRemovalCardThatCannotBeSavedIsMadeLaterOnce() throws {
        let s = try setup()
        let first = try event(s, ref: "W2", revision: "rev1", text: "Book the invented dentist")
        try bFileAndApprove(s)
        let proposals = ProposalStore.dir(s.folder)
        chmod(proposals.path, 0o500)
        defer { chmod(proposals.path, 0o700) }
        let gone = try retraction(s, ref: "W2", of: first)
        sweep(s)
        #expect(try stage(s, gone) == "retracting")
        func removals() -> [Proposal] { pOpen(s).filter { $0.raw["provenance"]?["retraction"] == .string(gone) } }
        #expect(removals().isEmpty)

        chmod(proposals.path, 0o700)
        sweep(s)
        sweep(s)
        #expect(try stage(s, gone) == "retracted")
        #expect(removals().count == 1)
        #expect(removals().allSatisfy { s.commands.isTrusted($0.id, in: s.folder) })
    }

    // MARK: - 5. An intake folder out of reach keeps its cards and its cursor

    @Test(arguments: ["intake", "intake/mail"])
    func anUnlistableIntakeFolderChangesNothing(_ locked: String) throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "levy.txt", IntakeReadingTests.notice)
        try t.write(s, "mail/levy.md", IntakeReadingTests.message)
        #expect(t.card(s).carded == 2)
        let before = t.open(s).map(\.id).sorted()
        let cursor = try s.watcher.load()

        let folder = s.folder.appendingPathComponent(locked)
        chmod(folder.path, 0o000)
        defer { chmod(folder.path, 0o700) }
        let r = s.watcher.scan(binders: t.rows(s), commands: s.commands, now: t.now, requireReading: true)
        #expect(r.unreadableFolders == 1)
        #expect(t.open(s).map(\.id).sorted() == before)
        #expect(try s.watcher.load() == cursor)

        chmod(folder.path, 0o700)
        #expect(t.card(s).carded == 0)
        #expect(t.open(s).map(\.id).sorted() == before)
    }

    // MARK: - 6. A correction's diff is bounded

    @Test func aLargeCorrectionIsDiffedWithinBounds() {
        let old = (0..<50_000).map { "line \($0)" }
        var new = old
        new[25_000] = "line 25000, corrected"
        let d = CaptureInbox.diffLines(old, new)
        #expect(d.fates[25_000] == .changed(25_000))
        #expect(d.fates[0] == .same(0) && d.fates[49_999] == .same(49_999))
        #expect(d.added.isEmpty)
    }

    @Test func aMiddleTooLargeForTheTablePairsInOrder() {
        var old = (0..<2_500).map { "old \($0)" }
        var new = (0..<2_500).map { "new \($0)" }
        old[100] = "shared"
        new[2_000] = "shared"
        #expect(2_500 * 2_500 > CaptureInbox.diffCells)
        let d = CaptureInbox.diffLines(old, new)
        #expect(d.fates[100] == .changed(100))
        #expect(d.added.isEmpty)
        // Below the bound, the shared line anchors.
        #expect(CaptureInbox.diffLines(Array(old[..<200]), Array(new[1_900..<2_100])).fates[100] == .same(100))
    }

    // MARK: - 7. The clerk's intake card counts as made only once the watcher follows it

    @Test func aReadingWhoseCursorCannotFollowKeepsTheCodeBuiltCard() async throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "levy.txt", IntakeReadingTests.notice)
        _ = t.card(s)
        func read() async throws -> (IntakeReadings.Entry, IntakeWatcher.ReadingOutcome) {
            let model = ScriptedModel(extractions: [.obj([("items", .array([
                item("The special levy of $450.00 is due November 1, 2026", "Pay the special levy", "pay", when: "November 1, 2026"),
            ]))])])
            model.document = .obj([("class", .str("action")), ("title", .str("Notice of special levy")), ("date_text", .str("September 30, 2026")),
                                   ("summary", .str("An invented notice.")), ("reply_needed", .bool(true))])
            let entry = try #require(s.watcher.nextForReading())
            let binder = FilingBinder(name: Teka.read(s.folder).name, description: "", folder: s.folder,
                                      openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))
            let doc = await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: binder, now: t.now)
            return (entry, s.watcher.commitReading(entry, doc, commands: s.commands, now: t.now))
        }
        let capture = s.support.appendingPathComponent("capture")
        chmod(capture.path, 0o500)
        defer { chmod(capture.path, 0o700) }
        let (entry, out) = try await read()
        chmod(capture.path, 0o700)
        #expect(!out.replaced)
        #expect(t.open(s).map(\.id) == [entry.card])
        #expect(IntakeReadings(support: s.support).load(entry.id)?.state == "pending")
        #expect(IntakeReadings(support: s.support).escalations().isEmpty)

        let (_, again) = try await read()
        #expect(again.replaced)
        let card = try #require(t.open(s).first)
        #expect(t.open(s).count == 1 && card.id != entry.card)
        #expect(try s.watcher.load()[s.folder.standardizedFileURL.path]?["levy.txt"]?.card == card.id)
        try FileManager.default.removeItem(at: s.folder.appendingPathComponent("intake/levy.txt"))
        _ = s.watcher.scan(binders: t.rows(s), commands: s.commands, now: t.now, requireReading: true)
        #expect(t.open(s).isEmpty)
        #expect(IntakeReadings(support: s.support).escalations().isEmpty)
    }

    // MARK: - 8, 9. The producer's clock

    @Test func anUnreadableClockIsNeverWrittenOver() throws {
        let s = try setup()
        try AtomicFile.makePrivateFolder(s.producer.stateURL.deletingLastPathComponent())
        try Data("{".utf8).write(to: s.producer.stateURL)
        #expect(throws: StateFile.Unreadable.self) { try s.producer.prepareNote("Invented note", startedAt: pNow, savedAt: pNow) }
        #expect(try Data(contentsOf: s.producer.stateURL) == Data("{".utf8))
    }

    @Test func aLostClockResumesAfterWhatWasPublished() throws {
        let s = try setup()
        func stamp(_ e: JSONObject) -> (Int64, Int64) {
            (e["hlc"]?["wall_ms"]?.numberValue?.safeInteger ?? 0, e["hlc"]?["counter"]?.numberValue?.safeInteger ?? 0)
        }
        let first = try s.producer.writeNote("Invented note one", startedAt: pNow, savedAt: pNow.addingTimeInterval(3_600))
        try FileManager.default.removeItem(at: s.producer.stateURL)
        let second = try s.producer.writeNote("Invented note two", startedAt: pNow, savedAt: pNow)
        #expect(stamp(first.event) < stamp(second.event))
    }

    @Test func anExhaustedCounterMovesTheClockOn() throws {
        let previous = HLC(wall_ms: 1_791_360_000_500, counter: 65_535, node: "n")
        #expect(HLC.next(after: previous, node: "n", now: pNow) == HLC(wall_ms: 1_791_360_000_501, counter: 0, node: "n"))

        let s = try setup()
        let node = pDevice.replacingOccurrences(of: "-", with: "")
        try AtomicFile.makePrivateFolder(s.producer.stateURL.deletingLastPathComponent())
        try JSONEncoder().encode(HLC(wall_ms: 1_791_360_000_500, counter: 65_535, node: node)).write(to: s.producer.stateURL)
        let note = try s.producer.writeNote("Invented note", startedAt: pNow, savedAt: pNow)
        let id = try #require(note.event["id"]?.stringValue)
        let device = s.producer.folder
        #expect(CaptureEvent.check(device.appendingPathComponent("\(id).json"), deviceFolder: device).0 == .complete(.capture))
    }

    // MARK: - SpravaKit's flushing rule

    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func next() -> Int { lock.withLock { n += 1; return n } }
    }

    @Test func aFlushFallsBackToFsyncOnlyWithoutFullSync() throws {
        let failing = DiskFlush(fullSync: { _ in errno = EIO; return -1 }, sync: { _ in 0 })
        #expect(throws: AtomicFile.Failure.self) { try failing(0, step: "flush") }
        for code in [ENOTSUP, EINVAL, ENOTTY] {
            try DiskFlush(fullSync: { _ in errno = code; return -1 }, sync: { _ in 0 })(0, step: "flush")
        }
        let syncFails = DiskFlush(fullSync: { _ in errno = ENOTSUP; return -1 }, sync: { _ in errno = EIO; return -1 })
        #expect(throws: AtomicFile.Failure.self) { try syncFails(0, step: "flush") }
        let calls = Calls()
        try DiskFlush(fullSync: { _ in if calls.next() == 1 { errno = EINTR; return -1 }; return 0 }, sync: { _ in errno = EIO; return -1 })(0, step: "flush")

        let s = try setup()
        try AtomicFile.makePrivateFolder(s.inbox.dir)
        #expect(throws: AtomicFile.Failure.self) { try CaptureInbox.appendDurably("{}", to: s.inbox.noticesURL, flush: failing) }
        let event = s.producer.folder.appendingPathComponent("01a10000-0000-7000-8000-0000000000e7.json")
        try AtomicFile.makePrivateFolder(s.producer.folder)
        #expect(throws: AtomicFile.Failure.self) { try CaptureProducer.publish(Data("{}".utf8), as: event, flush: failing) }
        #expect(!FileManager.default.fileExists(atPath: event.path))
    }
}

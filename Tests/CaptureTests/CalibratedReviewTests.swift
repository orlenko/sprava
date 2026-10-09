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

/// Regressions from the calibrated review of the capture layer: a capture whose card a crash cut short is never
/// lost to a later copy or revision, corrections keep every line past the cap, keys that cannot collide, and an
/// unverified source stays marked on every card. Invented data only.
@Suite(.serialized) struct CalibratedReviewTests {
    let early = "11111111-2222-4333-8444-5555555555c1"   // swept first
    let late = "22222222-2222-4333-8444-5555555555c2"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: early, app: "adapter")
        try s.inbox.registerProducer(folder: late, app: "adapter")
        return s
    }

    func event(_ s: PSetup, _ device: String, ref: String, revision: String, text: String) throws -> String {
        try pEvent(s, device: device, app: "adapter", ref: ref, revision: revision, text: text)
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func stage(_ s: PSetup, _ id: String) throws -> String? { try s.inbox.readState().ingested[id] }

    func fromEvent(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"]?.arrayValue?.contains(.string(id)) == true }

    /// A sweep whose card cannot be written, as when a crash comes right after the event is checkpointed.
    func sweepWithoutCards(_ s: PSetup) throws {
        try AtomicFile.makePrivateFolder(s.inbox.unfiledDir)
        chmod(s.inbox.unfiledDir.path, 0o500)
        defer { chmod(s.inbox.unfiledDir.path, 0o700) }
        sweep(s)
    }

    // MARK: - 1. A capture whose card a crash cut short is never lost

    @Test func aNewerSameTextRevisionCarriesACaptureThatGotNoCard() throws {
        let s = try setup()
        let a = try event(s, late, ref: "C1", revision: "rev1", text: "Book the invented plumber")
        try sweepWithoutCards(s)
        #expect(try stage(s, a) == "ingested" && s.inbox.unfiled().isEmpty)

        // The newer revision, the same words, is swept first from another device folder.
        let b = try event(s, early, ref: "C1", revision: "rev2", text: "Book the invented plumber")
        sweep(s)
        let cards = s.inbox.unfiled()
        #expect(cards.count == 1 && cards.first.map { fromEvent($0, b) } == true)
        #expect(try stage(s, b) == "unfiled" && stage(s, a) == "stale_revision")
    }

    @Test func aCardMadeBeforeTheCrashIsRecordedNotMadeAgain() throws {
        let s = try setup()
        let a = try event(s, late, ref: "C2", revision: "rev1", text: "Book the invented plumber")
        sweep(s)
        let card = try #require(s.inbox.unfiled().first)
        // The card was written, but the cursor that names it was lost.
        var state = try s.inbox.readState()
        state.ingested[a] = "ingested"
        state.cards[a] = nil
        state.clerk?[a] = nil
        try s.inbox.save(state)

        let b = try event(s, early, ref: "C2", revision: "rev2", text: "Book the invented plumber")
        sweep(s)
        #expect(s.inbox.unfiled().map(\.id) == [card.id])
        state = try s.inbox.readState()
        #expect(state.ingested[b] == "same_text" && state.ingested[a] == "unfiled" && state.cards[a] == card.id)
        #expect(state.clerk?[a] == "pending")
    }

    @Test func aSecondCopyCarriesACaptureWhoseFirstCopyGotNoCard() throws {
        let s = try setup()
        let a = try event(s, late, ref: "C3", revision: "rev1", text: "Book the invented plumber")
        try sweepWithoutCards(s)
        let copy = try event(s, early, ref: "C3", revision: "rev1", text: "Book the invented plumber")
        let r = sweep(s)
        #expect(r.duplicates == 0)
        let cards = s.inbox.unfiled()
        #expect(cards.count == 1 && cards.first.map { fromEvent($0, copy) } == true)
        #expect(try stage(s, a) == "duplicate" && stage(s, copy) == "unfiled")
        // A third copy is a duplicate of the one that carries the capture.
        _ = try event(s, early, ref: "C3", revision: "rev1", text: "Book the invented plumber")
        #expect(sweep(s).duplicates == 1 && s.inbox.unfiled().count == 1)
    }

    @Test func aFileDeferredByAnOlderReaderIsReadAgain() throws {
        let s = try setup()
        let newer = try pEvent(s, device: early, app: "adapter", ref: "D1", revision: "1", text: "Book the invented plumber") {
            $0.set("format_version", .str("1"))
        }
        sweep(s)
        let key = early + "/\(newer).json"
        #expect(try s.inbox.readState().examined[key]?.outcome == CaptureInbox.deferredOutcome)
        #expect(sweep(s).ingested == 0)

        // A file an older reader deferred (it knew fewer versions) is read again by this one.
        let id = try event(s, early, ref: "D2", revision: "1", text: "Water the invented garden")
        let file = s.producer.root.appendingPathComponent(early).appendingPathComponent("\(id).json")
        var st = stat()
        #expect(lstat(file.path, &st) == 0)
        var state = try s.inbox.readState()
        state.examined[early + "/\(id).json"] = .init(size: Int(st.st_size), mtime: Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9,
                                                      outcome: "deferred")
        try s.inbox.save(state)
        #expect(sweep(s).unfiled == 1)
        #expect(try stage(s, id) == "unfiled")
    }

    // MARK: - 2. Corrections keep every line past the tenth

    @Test func aCorrectionListsLinesPastTheTenthAndALaterOneKeepsThem() throws {
        let s = try setup()
        _ = try event(s, early, ref: "L1", revision: "rev1", text: "Call the invented roofer")
        try bFileAndApprove(s)
        let tasks = (1...11).map { "Invented task number \($0)" }
        let first = try event(s, early, ref: "L1", revision: "rev2", text: (["Call the invented roofer"] + tasks).joined(separator: "\n"))
        sweep(s)
        let card = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: first) })
        #expect(card.ops.filter { $0["op"] == .str("add_item") }.count == 10)
        #expect(s.inbox.notFiled(card) == ["Invented task number 11"])

        // A later correction withdraws that card; the line it listed as not filed yet is listed again.
        let second = try event(s, early, ref: "L1", revision: "rev3",
                               text: (["Call the invented roofer Monday"] + tasks).joined(separator: "\n"))
        sweep(s)
        #expect(!pOpen(s).contains { $0.id == card.id })
        let again = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: second) })
        #expect(again.ops.filter { $0["op"] == .str("add_item") }.count == 10)
        #expect(s.inbox.notFiled(again) == ["Invented task number 11"])
    }

    // MARK: - 3. Capture keys never collide

    @Test func capturesWhosePartsHoldTheSeparatorAreDifferent() throws {
        let s = try setup()
        let one = try event(s, early, ref: "note|part", revision: "1", text: "Book the invented plumber")
        let two = try event(s, early, ref: "note", revision: "part|1", text: "Water the invented garden")
        let r = sweep(s)
        #expect(r.duplicates == 0 && r.unfiled == 2)
        #expect(try stage(s, one) == "unfiled" && stage(s, two) == "unfiled")
    }

    @Test func keysAnOlderCursorKeptStillMatchExactly() throws {
        let s = try setup()
        let plain = try event(s, early, ref: "K1", revision: "1", text: "Book the invented plumber")
        let piped = try event(s, early, ref: "note|part", revision: "1", text: "Water the invented garden")
        sweep(s)
        // The cursor as an older version kept it: keys joined by "|".
        var state = try s.inbox.readState()
        state.dedupe = ["adapter|K1|1": plain, "adapter|note|part|1": piped]
        state.captures = nil
        state.chains = ["adapter|K1": [plain], "adapter|note|part": [piped]]
        state.chainsByKey = nil
        try s.inbox.save(state)

        // Copies of both are still duplicates.
        _ = try event(s, early, ref: "K1", revision: "1", text: "Book the invented plumber")
        _ = try event(s, early, ref: "note|part", revision: "1", text: "Water the invented garden")
        #expect(sweep(s).duplicates == 2)
        // A different capture whose parts join the same way is new.
        let other = try event(s, early, ref: "note", revision: "part|1", text: "Sweep the invented porch")
        let r = sweep(s)
        #expect(r.duplicates == 0 && r.unfiled == 1)
        #expect(try stage(s, other) == "unfiled")
        // A revision of the stored chain still belongs to it.
        let revised = try event(s, early, ref: "note|part", revision: "2", text: "Water the invented garden twice")
        sweep(s)
        state = try s.inbox.readState()
        let key = try #require(CaptureEvent.check(s.producer.root.appendingPathComponent(early).appendingPathComponent("\(revised).json"),
                                                  deviceFolder: s.producer.root.appendingPathComponent(early)).1).chainKey
        #expect(state.chainsByKey?[key] == [piped, revised])
        #expect(!s.inbox.unfiled().contains { fromEvent($0, piped) })
    }

    // MARK: - 6. An unverified source stays marked

    @Test func theClerksCardsKeepAnUnverifiedSource() async throws {
        let s = try pSetup()
        let id = try pEvent(s, device: "33333333-2222-4333-8444-5555555555c3", app: "adapter", ref: "U1", revision: "1",
                            text: "Call the invented notary about the deed")
        sweep(s)
        #expect(s.inbox.unfiled().first?.raw["provenance"]?["unverified_source"] == .bool(true))
        let work = try #require(s.inbox.nextForClerk())
        let model = RecordingModel([.obj([("items", .array([item("Call the invented notary", "Call the notary", "call")]))])])
        let interp = await Clerk(model: model).read(work.event, filing: [bFiling(s)], hint: nil, now: pNow)
        let out = s.inbox.commitClerk(work, interp, filing: [bFiling(s)], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(out.replaced)
        let cards = s.inbox.unfiled() + pOpen(s)
        #expect(!cards.isEmpty && cards.allSatisfy { fromEvent($0, id) && $0.raw["provenance"]?["unverified_source"] == .bool(true) })
    }

    @Test func aCorrectionKeepsAnUnverifiedSource() throws {
        let s = try pSetup()
        // A note in Sprava's own folder without the app's notice is unverified.
        _ = try pEvent(s, device: pDevice, app: "sprava", ref: "U2", revision: "1", text: "Call the invented roofer")
        try bFileAndApprove(s)
        let revised = try pEvent(s, device: pDevice, app: "sprava", ref: "U2", revision: "2", text: "Call the invented roofer Monday")
        sweep(s)
        let card = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: revised) })
        #expect(card.raw["provenance"]?["unverified_source"] == .bool(true))
    }
}

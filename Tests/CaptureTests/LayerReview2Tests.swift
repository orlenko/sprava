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

/// Regressions from the second review of the capture layer: privacy whatever the arrival order and while filing,
/// successive corrections, retractions resumed, the clerk's hand-off, and a cursor that cannot be written. Invented
/// data only.
@Suite(.serialized) struct LayerReview2Tests {
    let adapter = "11111111-2222-4333-8444-5555555555f8"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    func event(_ s: PSetup, ref: String, revision: String, text: String, extra: (inout JSONObject) -> Void = { _ in }) throws -> String {
        try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: revision, text: text, extra: extra)
    }

    /// A typed note the way the app sends it: the event, then its notice.
    func note(_ s: PSetup, _ text: String, hint: String? = nil) throws -> String {
        let n = try s.producer.prepareNote(text, binderHint: hint, startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: n.id, digest: n.digest)
        try s.producer.publish(n)
        return n.id
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func stage(_ s: PSetup, _ id: String) throws -> String? { try s.inbox.readState().ingested[id] }

    func fromEvent(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"]?.arrayValue?.contains(.string(id)) == true }

    func corrections(_ s: PSetup, of event: String) -> [Proposal] { pOpen(s).filter { CaptureInbox.isCorrection($0, of: event) } }

    // MARK: - 1. A private revision that arrives late still raises its chain

    @Test func aStalePrivateRevisionStillRaisesTheChain() throws {
        let s = try setup()
        let later = try event(s, ref: "O1", revision: "rev2", text: "Call the invented roofer on Monday")
        sweep(s)
        #expect(s.inbox.unfiled().first { fromEvent($0, later) }?.raw["provenance"]?["private"] == nil)
        // An older revision, marked private, arrives only now.
        let earlier = try event(s, ref: "O1", revision: "rev1", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
            $0.set("hlc", .obj([("wall_ms", .int(1_791_350_000_000)), ("counter", .int(0)),
                                ("node", .string(adapter.replacingOccurrences(of: "-", with: "")))]))
        }
        sweep(s)
        #expect(try stage(s, earlier) == "stale_revision")
        let card = try #require(s.inbox.unfiled().first { fromEvent($0, later) })
        #expect(card.raw["provenance"]?["private"] == .bool(true))
        #expect(card.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) })
    }

    // MARK: - 2. Filing a card applies a raise to private its rewrite could not

    @Test func filingCarriesARaiseThatCouldNotBeWritten() throws {
        let s = try setup()
        _ = try event(s, ref: "F1", revision: "rev1", text: "Renew the invented passport")
        sweep(s)
        let card = try #require(s.inbox.unfiled().first)
        chmod(s.inbox.unfiledDir.path, 0o500)
        defer { chmod(s.inbox.unfiledDir.path, 0o700) }
        let raise = try event(s, ref: "F1", revision: "rev1", text: "Renew the invented passport") { $0.set("sensitivity", .str("private")) }
        sweep(s)
        #expect(s.inbox.privacyOwed(for: raise))
        #expect(s.inbox.unfiled().first?.raw["provenance"]?["private"] == nil)

        try s.inbox.file(card.id, into: s.folder, commands: s.commands)
        let filed = try #require(pOpen(s).first { $0.id == card.id })
        #expect(filed.raw["provenance"]?["private"] == .bool(true))
        #expect(filed.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) })
        #expect(s.commands.isTrusted(card.id, in: s.folder))
    }

    // MARK: - 3. A correction carries what an earlier one still waiting would have changed

    @Test func aSecondCorrectionKeepsTheFirstOnesTitleChange() throws {
        let s = try setup()
        _ = try event(s, ref: "K1", revision: "rev1", text: "Call the invented roofer.")
        try bFileAndApprove(s)
        let first = try event(s, ref: "K1", revision: "rev2", text: "Call the invented roofer Monday")
        sweep(s)
        #expect(corrections(s, of: first).count == 1)
        let second = try event(s, ref: "K1", revision: "rev3", text: "Call the invented roofer Monday\nBuy the invented paint")
        sweep(s)
        #expect(corrections(s, of: first).isEmpty)
        let card = try #require(corrections(s, of: second).first)
        #expect(card.ops.compactMap { $0["args"]?["set"]?["title"]?.stringValue } == ["Call the invented roofer Monday"])
        #expect(card.ops.compactMap { $0["args"]?["item"]?["title"]?.stringValue } == ["Buy the invented paint"])
    }

    @Test func aSecondCorrectionKeepsTheFirstOnesRemoval() throws {
        let s = try setup()
        _ = try event(s, ref: "K2", revision: "rev1", text: "Call the invented roofer\nBuy the invented paint")
        try bFileAndApprove(s)
        let paint = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Buy the invented paint") })
        let first = try event(s, ref: "K2", revision: "rev2", text: "Call the invented roofer")
        sweep(s)
        #expect(corrections(s, of: first).count == 1)
        let second = try event(s, ref: "K2", revision: "rev3", text: "Call the invented roofer\nSweep the invented porch")
        sweep(s)
        let card = try #require(corrections(s, of: second).first)
        let drops = card.ops.filter { $0["op"] == .str("drop") }.compactMap { $0["args"]?["id"] }
        #expect(drops == [try #require(paint["id"])])
        #expect(card.ops.compactMap { $0["args"]?["item"]?["title"]?.stringValue } == ["Sweep the invented porch"])
        #expect(!card.ops.contains { $0["args"]?["set"]?["title"] != nil })
    }

    // MARK: - 4. A retraction resumed keeps the removal card it already made

    @Test func aResumedRetractionKeepsItsRemovalCard() throws {
        let s = try setup()
        let first = try event(s, ref: "T1", revision: "rev1", text: "Book the invented dentist")
        try bFileAndApprove(s)
        // Sprava's copy of the chain's reading cannot be removed yet, so the retraction is done only in part.
        let readings = s.inbox.dir.appendingPathComponent("interpretations", isDirectory: true)
        try AtomicFile.makePrivateFolder(readings)
        try Data("{}".utf8).write(to: readings.appendingPathComponent("\(first).json"))
        chmod(readings.path, 0o500)
        defer { chmod(readings.path, 0o700) }
        let gone = try event(s, ref: "T1", revision: "retracted", text: "") {
            $0.set("retracted", .bool(true))
            $0.set("supersedes", .string(first))
        }
        func removals() -> [Proposal] { pOpen(s).filter { $0.raw["provenance"]?["retraction"] == .string(gone) } }
        sweep(s)
        #expect(try stage(s, gone) == "retracting")
        #expect(removals().count == 1)

        chmod(readings.path, 0o700)
        sweep(s)
        #expect(try stage(s, gone) == "retracted")
        #expect(removals().count == 1)
        #expect(removals().allSatisfy { s.commands.isTrusted($0.id, in: s.folder) })
    }

    // MARK: - 5. The clerk's cards and the code-built card never both wait

    func clerkCard(_ s: PSetup, title: String) throws -> Proposal {
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("invented"))])
        let item = JSONValue.obj([("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")), ("priority", .str("normal")),
                                  ("no_deadline", .bool(true))])
        let card = Proposal.make(title: title, actor: actor, ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", item)]))])],
                                 provenance: JSONObject([(key: "events", value: .array([]))]), now: pNow)
        try ProposalStore.save(card, in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)
        return card
    }

    @Test func aCodeBuiltCardThatCannotGiveWayKeepsTheClerksCardsBack() async throws {
        let s = try pSetup()
        let id = try note(s, "Call the invented notary about the deed")
        sweep(s)
        let work = try #require(s.inbox.nextForClerk())
        #expect(work.tier0Binder == nil)
        let model = RecordingModel([.obj([("items", .array([item("Call the invented notary", "Call the notary", "call")]))])])
        let interp = await Clerk(model: model).read(work.event, filing: [bFiling(s)], hint: "estate-example", now: pNow)
        chmod(s.inbox.unfiledDir.path, 0o500)
        defer { chmod(s.inbox.unfiledDir.path, 0o700) }

        let out = s.inbox.commitClerk(work, interp, filing: [bFiling(s)], rows: pRows(s), commands: s.commands, seconds: 1, now: pNow)
        #expect(!out.replaced)
        #expect(pOpen(s).isEmpty)
        #expect(s.inbox.unfiled().map(\.id) == [work.tier0])
        let state = try s.inbox.readState()
        #expect(state.handoffs?[id] == nil && state.clerk?[id] == "retry")
    }

    @Test func aHandOffCutShortAfterEveryCardIsFinishedBySweep() throws {
        let s = try pSetup()
        let id = try note(s, "Call the invented notary about the deed")
        sweep(s)
        let work = try #require(s.inbox.nextForClerk())
        // The clerk's card was saved and trusted, then the run stopped before the code-built card gave way.
        let card = try clerkCard(s, title: "Call the notary")
        var state = try s.inbox.readState()
        state.handoffs = [id: [.init(binder: s.folder.path, card: card.id)]]
        try s.inbox.save(state)
        #expect(s.inbox.nextForClerk() == nil)

        sweep(s)
        #expect(!s.inbox.unfiled().contains { $0.id == work.tier0 })
        #expect(pOpen(s).map(\.id) == [card.id])
        state = try s.inbox.readState()
        #expect(state.handoffs?[id] == nil && state.clerk?[id] == "done")
        #expect(s.inbox.nextForClerk() == nil)
    }

    @Test func aHandOffCutShortPartWayIsTakenBackAndReadAgain() throws {
        let s = try pSetup()
        let id = try note(s, "Call the invented notary about the deed")
        sweep(s)
        let work = try #require(s.inbox.nextForClerk())
        let saved = try clerkCard(s, title: "Call the notary")
        var state = try s.inbox.readState()
        state.handoffs = [id: [.init(binder: s.folder.path, card: saved.id), .init(binder: nil, card: UUIDv7.make(now: pNow))]]
        try s.inbox.save(state)

        sweep(s)
        #expect(pOpen(s).isEmpty)
        #expect(s.inbox.unfiled().map(\.id) == [work.tier0])
        #expect(try s.inbox.readState().handoffs?[id] == nil)
        #expect(s.inbox.nextForClerk()?.event.id == id)
    }

    // MARK: - 6. A cursor that cannot be written makes no card

    @Test func aCursorThatCannotBeWrittenMakesNoCard() throws {
        let s = try pSetup()
        _ = try note(s, "Call the invented notary")
        sweep(s)
        #expect(s.inbox.unfiled().count == 1)
        chflags(s.inbox.stateURL.path, UInt32(UF_IMMUTABLE))
        defer { chflags(s.inbox.stateURL.path, 0) }
        _ = try note(s, "Book the invented dentist")
        let r = sweep(s)
        #expect(r.unsaved == "state.json" && r.ingested == 0 && r.unfiled == 0)
        #expect(s.inbox.unfiled().count == 1)

        chflags(s.inbox.stateURL.path, 0)
        let again = sweep(s)
        #expect(again.unsaved == nil && again.unfiled == 1)
        sweep(s)
        #expect(s.inbox.unfiled().count == 2)
    }

    @Test func aCardThePersonActedOnIsNeverMadeAgain() throws {
        let s = try pSetup()
        let id = try note(s, "Call the invented notary about the deed", hint: "estate-example")
        sweep(s)
        let card = try #require(pOpen(s).first)
        _ = try TekaStore(folder: s.folder).approve(card, now: pNow)
        // The cursor never got the card's id, as when its save failed after the card was made.
        var state = try s.inbox.readState()
        state.ingested[id] = "ingested"
        state.cards[id] = nil
        state.clerk?[id] = nil
        try s.inbox.save(state)

        sweep(s)
        #expect(pOpen(s).isEmpty)
        #expect(ProposalStore.list(in: s.folder).filter { fromEvent($0.0, id) }.count == 1)
        state = try s.inbox.readState()
        #expect(state.ingested[id] == "proposed" && state.cards[id] == card.id)
    }

    // MARK: - 7. An event that cannot be read now is retried, never quarantined

    @Test func anUnreadableEventIsRetriedNotQuarantined() throws {
        let s = try setup()
        let id = try event(s, ref: "N1", revision: "rev1", text: "Book the invented dentist")
        let device = s.producer.root.appendingPathComponent(adapter)
        let file = device.appendingPathComponent("\(id).json")
        // An I/O error now (a sync client still holds the file): pending, so a later sweep reads it again.
        let (busy, none) = CaptureEvent.check(file, deviceFolder: device) { _ in .unreadable("Input/output error") }
        #expect(busy == .pending && none == nil)
        // A file this user may not read is refused, as SpravaKit's SafeFile decides, and quarantined.
        let (refused, _) = CaptureEvent.check(file, deviceFolder: device) { _ in .refused("not readable by this user") }
        #expect(refused == .quarantined("not readable by this user"))

        // Once it can be read, the same file is a complete event and is taken in.
        #expect(CaptureEvent.check(file, deviceFolder: device).0 == .complete(.capture))
        #expect(sweep(s).unfiled == 1)
        #expect(try stage(s, id) == "unfiled")
    }

    // MARK: - 8. A binder whose writes are blocked gets no new card

    @Test func aBinderWithAnUnreadableOpLogGetsNoNewCard() throws {
        let s = try pSetup()
        let log = s.folder.appendingPathComponent(".sprava/ops.ndjson")
        #expect(chmod(log.path, 0) == 0)
        defer { chmod(log.path, 0o600) }
        // The op log is there but cannot be read: the binder counts as adopted, and its writes are blocked.
        let teka = Teka.read(s.folder)
        #expect(teka.isAdopted && teka.writesBlocked)

        let id = try note(s, "Call the invented notary about the deed", hint: "estate-example")
        let r = sweep(s)
        #expect(r.filed == 0 && r.unfiled == 1)
        #expect(pOpen(s).isEmpty)
        #expect(try stage(s, id) == "unfiled")
        // Nor can the person move the Inbox card there until the binder is repaired.
        let card = try #require(s.inbox.unfiled().first { fromEvent($0, id) })
        #expect(throws: Commands.Failure.self) { try s.inbox.file(card.id, into: s.folder, commands: s.commands) }
        #expect(pOpen(s).isEmpty && s.inbox.unfiled().count == 1)

        chmod(log.path, 0o600)
        try s.inbox.file(card.id, into: s.folder, commands: s.commands)
        #expect(pOpen(s).map(\.id) == [card.id])
    }
}

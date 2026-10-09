import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the second calibrated review of the capture layer: the privacy of a chain's first event when it
/// is empty or a retraction, a hand-off that goes forward once the code-built card is gone, and what counts as a
/// privacy-only card. Invented data only.
@Suite(.serialized) struct CalibratedReview2Tests {
    let adapter = "11111111-2222-4333-8444-5555555555d1"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    func event(_ s: PSetup, ref: String, revision: String, text: String, private: Bool = false, retracted: Bool = false) throws -> String {
        try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: revision, text: text) {
            if `private` { $0.set("sensitivity", .str("private")) }
            if retracted { $0.set("retracted", .bool(true)) }
        }
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func fromEvent(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"]?.arrayValue?.contains(.string(id)) == true }

    func addedItems(_ p: Proposal) -> [JSONValue] { p.ops.compactMap { $0["op"] == .str("add_item") ? $0["args"]?["item"] : nil } }

    // MARK: - 1. A chain's first event records its privacy, empty or retracted

    @Test func anEmptyPrivateFirstEventKeepsItsChainPrivate() throws {
        let s = try setup()
        _ = try event(s, ref: "P1", revision: "rev1", text: "", private: true)
        sweep(s)
        let later = try event(s, ref: "P1", revision: "rev2", text: "Call the invented roofer")
        sweep(s)
        let card = try #require(s.inbox.unfiled().first { fromEvent($0, later) })
        #expect(card.raw["provenance"]?["private"] == .bool(true))
        #expect(!addedItems(card).isEmpty && addedItems(card).allSatisfy { $0["redact"] == .bool(true) })
    }

    @Test func aPrivateRetractionFirstKeepsItsChainPrivate() throws {
        let s = try setup()
        _ = try event(s, ref: "P2", revision: "retracted", text: "", private: true, retracted: true)
        sweep(s)
        let restored = try event(s, ref: "P2", revision: "rev2", text: "Call the invented roofer")
        sweep(s)
        let card = try #require(s.inbox.unfiled().first { fromEvent($0, restored) })
        #expect(!addedItems(card).isEmpty && addedItems(card).allSatisfy { $0["redact"] == .bool(true) })
    }

    // MARK: - 2. A hand-off goes forward once the code-built card gave way

    func clerkCard(_ s: PSetup, event: String, title: String) throws -> Proposal {
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("invented"))])
        let item = JSONValue.obj([("id", .str("$new:1")), ("title", .string(title)), ("status", .str("open")), ("priority", .str("normal")),
                                  ("no_deadline", .bool(true))])
        let card = Proposal.make(title: title, actor: actor, ops: [JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", item)]))])],
                                 provenance: JSONObject([(key: "events", value: .array([.string(event)]))]), now: pNow)
        try ProposalStore.save(card, in: s.folder)
        try s.commands.trustProposals([card.id], in: s.folder)
        return card
    }

    @Test func anApprovedReplacementNeverTakesBackTheOthers() throws {
        let s = try setup()
        let id = try event(s, ref: "H1", revision: "rev1", text: "Call the invented notary\nPay the invented levy")
        sweep(s)
        let tier0 = try #require(s.inbox.unfiled().first)
        // The clerk saved both its cards and the code-built card gave way, then the run stopped before the hand-off
        // record was cleared.
        let call = try clerkCard(s, event: id, title: "Call the invented notary")
        let pay = try clerkCard(s, event: id, title: "Pay the invented levy")
        var state = try s.inbox.readState()
        state.handoffs = [id: [.init(binder: s.folder.path, card: call.id), .init(binder: s.folder.path, card: pay.id)]]
        state.committed = [id]
        try s.inbox.save(state)
        try FileManager.default.removeItem(at: try #require(s.inbox.unfiledFile(tier0.id)))
        // The person approves one of them before the next sweep.
        _ = try TekaStore(folder: s.folder).approve(call, now: pNow)

        sweep(s)
        #expect(pOpen(s).map(\.id) == [pay.id])
        state = try s.inbox.readState()
        #expect(state.handoffs?[id] == nil && state.committed?.contains(id) != true && state.clerk?[id] == "done")
    }

    @Test func aHandOffWithoutTheRecordStillGoesForwardOnceEveryCardWasWritten() throws {
        let s = try setup()
        let id = try event(s, ref: "H2", revision: "rev1", text: "Call the invented notary\nPay the invented levy")
        sweep(s)
        let tier0 = try #require(s.inbox.unfiled().first)
        let call = try clerkCard(s, event: id, title: "Call the invented notary")
        let pay = try clerkCard(s, event: id, title: "Pay the invented levy")
        var state = try s.inbox.readState()
        state.handoffs = [id: [.init(binder: s.folder.path, card: call.id), .init(binder: s.folder.path, card: pay.id)]]
        try s.inbox.save(state)
        _ = try TekaStore(folder: s.folder).approve(call, now: pNow)

        sweep(s)
        // Both were written, so the code-built card gives way and the other card stays.
        #expect(pOpen(s).map(\.id) == [pay.id])
        #expect(!s.inbox.unfiled().contains { $0.id == tier0.id })
        state = try s.inbox.readState()
        #expect(state.handoffs?[id] == nil && state.clerk?[id] == "done")
    }

    @Test func aHandOffCutShortBeforeACardWasWrittenIsTakenBack() throws {
        let s = try setup()
        let id = try event(s, ref: "H3", revision: "rev1", text: "Call the invented notary\nPay the invented levy")
        sweep(s)
        let tier0 = try #require(s.inbox.unfiled().first)
        let call = try clerkCard(s, event: id, title: "Call the invented notary")
        var state = try s.inbox.readState()
        state.handoffs = [id: [.init(binder: s.folder.path, card: call.id), .init(binder: s.folder.path, card: UUID().uuidString.lowercased())]]
        try s.inbox.save(state)

        sweep(s)
        #expect(pOpen(s).isEmpty)
        #expect(s.inbox.unfiled().map(\.id) == [tier0.id])
        #expect(try s.inbox.readState().handoffs?[id] == nil)
    }

    // MARK: - 3. A privacy-only card changes nothing but privacy

    func update(_ set: [(String, JSONValue)], unset: [String] = []) -> JSONObject {
        var args = JSONObject([(key: "id", value: .str("a-1")), (key: "set", value: .obj(set))])
        if !unset.isEmpty { args.set("unset", .array(unset.map(JSONValue.string))) }
        return JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .object(args))])
    }

    func card(_ ops: [JSONObject]) -> Proposal {
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("none"))])
        return Proposal.make(title: "Invented", actor: actor, ops: ops, provenance: JSONObject(), now: pNow)
    }

    @Test func onlyAPurePrivacyCardCountsAsOne() {
        #expect(CaptureInbox.onlyRedacts(card([update([("redact", .bool(true))]), update([("redact", .bool(true)), ("kind", .str("other"))])])))
        #expect(!CaptureInbox.onlyRedacts(card([update([("redact", .bool(true)), ("title", .str("A new invented title"))])])))
        #expect(!CaptureInbox.onlyRedacts(card([update([("redact", .bool(true)), ("due", .str("2026-11-02"))])])))
        #expect(!CaptureInbox.onlyRedacts(card([update([("redact", .bool(true)), ("kind", .str("payment"))])])))
        #expect(!CaptureInbox.onlyRedacts(card([update([("redact", .bool(true))], unset: ["due"])])))
        #expect(!CaptureInbox.onlyRedacts(card([update([("redact", .bool(true))]),
                                                JSONObject([(key: "op", value: .str("drop")), (key: "args", value: .obj([("id", .str("a-1"))]))])])))
        #expect(!CaptureInbox.onlyRedacts(card([])))
    }

    @Test func aPrivateCorrectionThatChangesATitleIsWithdrawnByTheNext() throws {
        let s = try setup()
        _ = try event(s, ref: "R1", revision: "rev1", text: "Call the invented roofer")
        try bFileAndApprove(s)
        let first = try event(s, ref: "R1", revision: "rev2", text: "Call the invented roofer Monday", private: true)
        sweep(s)
        let card = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: first) })
        #expect(card.ops.contains { $0["args"]?["set"]?["title"] != nil && $0["args"]?["set"]?["redact"] == .bool(true) })

        let second = try event(s, ref: "R1", revision: "rev3", text: "Call the invented roofer Tuesday")
        sweep(s)
        #expect(!pOpen(s).contains { $0.id == card.id })
        #expect(pOpen(s).contains { CaptureInbox.isCorrection($0, of: second) })
    }

    // MARK: - 4. Found by the random sequences

    @Test func aCardSpravaTookBackIsNotTakenForOneThePersonRejected() throws {
        let s = try setup()
        let id = try event(s, ref: "H4", revision: "rev1", text: "Call the invented notary")
        sweep(s)
        let tier0 = try #require(s.inbox.unfiled().first)
        // The hand-off failed after its card was saved and trusted; Sprava took that card back, then the run stopped
        // before the record was cleared.
        let call = try clerkCard(s, event: id, title: "Call the invented notary")
        try TekaStore(folder: s.folder).reject(call, reason: CaptureInbox.takenBack, now: pNow)
        var state = try s.inbox.readState()
        state.handoffs = [id: [.init(binder: s.folder.path, card: call.id)]]
        try s.inbox.save(state)

        sweep(s)
        #expect(s.inbox.unfiled().map(\.id) == [tier0.id])
        state = try s.inbox.readState()
        #expect(state.handoffs?[id] == nil && state.clerk?[id] != "done")
    }

    @Test func aSecondRetractionSeenBeforeTheRestoreStillWins() throws {
        let s = try setup()
        let other = "00000000-2222-4333-8444-5555555555d0"   // swept before the adapter's folder
        try s.inbox.registerProducer(folder: other, app: "adapter")
        _ = try event(s, ref: "T2", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        _ = try event(s, ref: "T2", revision: "retracted", text: "", retracted: true)
        sweep(s)
        #expect(s.inbox.unfiled().isEmpty)
        // A restore, then a second retraction, which is swept first from the other folder.
        let restore = try event(s, ref: "T2", revision: "rev2", text: "Call the invented roofer again")
        let again = try pEvent(s, device: other, app: "adapter", ref: "T2", revision: "retracted", text: "") { $0.set("retracted", .bool(true)) }
        sweep(s)
        #expect(!s.inbox.unfiled().contains { fromEvent($0, restore) })
        let state = try s.inbox.readState()
        #expect(state.ingested[again] == "duplicate" && state.ingested[restore] == "stale_revision")
    }

    @Test func aPrivateRetractionRedactsWhatItOffersToDrop() throws {
        let s = try setup()
        _ = try event(s, ref: "T3", revision: "rev1", text: "Call the invented roofer")
        try bFileAndApprove(s)
        let item = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Call the invented roofer") })
        let retraction = try event(s, ref: "T3", revision: "retracted", text: "", private: true, retracted: true)
        sweep(s)
        let card = try #require(pOpen(s).first { $0.raw["provenance"]?["retraction"] == .string(retraction) })
        let ops = card.ops.filter { $0["args"]?["id"] == item["id"] }.compactMap { $0["op"]?.stringValue }
        #expect(ops == ["update_item", "drop"])
        #expect(card.ops.first?["args"]?["set"]?["redact"] == .bool(true))
    }

    @Test func aRaiseIsCoveredOnlyByACardThatNothingWithdraws() throws {
        let s = try setup()
        _ = try event(s, ref: "T4", revision: "rev1", text: "Call the invented roofer")
        try bFileAndApprove(s)
        let item = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Call the invented roofer") })
        // A correction waits; a private copy of it raises the chain, which rewrites that card private too.
        _ = try event(s, ref: "T4", revision: "rev2", text: "Call the invented roofer Monday")
        sweep(s)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "T4", revision: "rev2", text: "Call the invented roofer Monday") {
            $0.set("sensitivity", .str("private"))
        }
        sweep(s)
        func redacting() -> [Proposal] {
            pOpen(s).filter { CaptureInbox.onlyRedacts($0) && $0.ops.contains { $0["args"]?["id"] == item["id"] } }
        }
        #expect(redacting().count == 1)
        // The next correction withdraws the rewritten card; the redaction stays.
        _ = try event(s, ref: "T4", revision: "rev3", text: "Call the invented roofer Tuesday")
        sweep(s)
        #expect(redacting().count == 1)
    }
    @Test func aChangedLineThatNoItemHoldsIsProposedAgain() throws {
        let s = try setup()
        _ = try event(s, ref: "T5", revision: "rev1", text: "Call the invented roofer")
        try bFileAndApprove(s)
        let first = try event(s, ref: "T5", revision: "rev2", text: "Call the invented roofer\nBuy the invented paint")
        sweep(s)
        // The person declines the new line.
        try TekaStore(folder: s.folder).reject(try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: first) }), now: pNow)
        let second = try event(s, ref: "T5", revision: "rev3", text: "Call the invented roofer\nBuy the invented blue paint")
        sweep(s)
        let card = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: second) })
        #expect(card.ops.compactMap { $0["args"]?["item"]?["title"]?.stringValue } == ["Buy the invented blue paint"])
    }

    @Test func aLineOnlyAWithdrawnTitleChangeHeldIsProposedAgain() throws {
        let s = try setup()
        _ = try event(s, ref: "T6", revision: "rev1", text: "Pay the invented levy\nCall the invented roofer")
        try bFileAndApprove(s)
        // The new first line becomes a new title for one of the two items, and that item's own words come back as a
        // new line: the card renames one item and adds the other line.
        let first = try event(s, ref: "T6", revision: "rev2", text: "Book the invented plumber\nCall the invented roofer\nPay the invented levy")
        sweep(s)
        let card = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: first) })
        #expect(card.ops.contains { $0["args"]?["set"]?["title"] == .str("Book the invented plumber") })
        // The next revision withdraws that card; the line it alone held is proposed again.
        let second = try event(s, ref: "T6", revision: "rev3",
                               text: "Book the invented plumber\nCall the invented roofer\nPay the invented levy\nSweep the invented porch")
        sweep(s)
        let again = try #require(pOpen(s).first { CaptureInbox.isCorrection($0, of: second) })
        let titles = again.ops.compactMap { ($0["args"]?["item"]?["title"] ?? $0["args"]?["set"]?["title"])?.stringValue }
        #expect(titles.contains("Book the invented plumber") && titles.contains("Sweep the invented porch"))
    }
}

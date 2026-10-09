import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the sixth calibrated review of the capture layer: a card that cannot be read keeps a raise owed,
/// a revision with no words takes back what the chain said, and crash recovery takes only a trusted card. Invented
/// data only.
@Suite(.serialized) struct CalibratedReview6Tests {
    let adapter = "11111111-2222-4333-8444-5555555555f6"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    func event(_ s: PSetup, ref: String, revision: String, text: String, private: Bool = false) throws -> String {
        try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: revision, text: text) {
            if `private` { $0.set("sensitivity", .str("private")) }
        }
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func from(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"] == .array([.string(id)]) }

    // MARK: - 1. A card that cannot be read keeps the raise owed

    @Test func aRaiseThatCannotReadACardStaysOwedAndHoldsTheApproval() throws {
        let s = try setup()
        let first = try event(s, ref: "E1", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { from($0, first) }).id, into: s.folder, commands: s.commands)
        let card = try #require(pOpen(s).first)
        let file = ProposalStore.dir(s.folder).appendingPathComponent("\(card.id).json")
        chmod(file.path, 0o000)
        defer { chmod(file.path, 0o600) }

        _ = try event(s, ref: "E1", revision: "rev2", text: "Call the invented roofer", private: true)
        sweep(s)
        #expect(try s.inbox.readState().debts?.isEmpty == false, "the privacy debt is still owed")
        #expect(!s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow), "the approval waits")

        chmod(file.path, 0o600)
        #expect(s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))
        let fresh = try #require(pOpen(s).first { $0.id == card.id })
        #expect(fresh.raw["provenance"]?["private"] == .bool(true))
        sweep(s)
        #expect(try s.inbox.readState().debts?.isEmpty != false)
    }

    // MARK: - 2. A revision with no words takes back what the chain said

    @Test func aRevisionWithNoWordsWithdrawsWhatWaitsAndOffersToDropWhatWasFiled() throws {
        for words in ["", "  \n\t "] {
            let s = try setup()
            _ = try event(s, ref: "E2", revision: "rev1", text: "Call the invented roofer")
            try bFileAndApprove(s)
            let item = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Call the invented roofer") })
            _ = try event(s, ref: "E2", revision: "rev2", text: "Call the invented roofer\nBuy the invented paint")
            sweep(s)
            let correction = try #require(pOpen(s).first)
            let emptied = try event(s, ref: "E2", revision: "rev3", text: words)
            sweep(s)
            #expect(!pOpen(s).contains { $0.id == correction.id }, "the waiting correction is withdrawn")
            let removal = try #require(pOpen(s).first { $0.raw["provenance"]?["retraction"] == .string(emptied) })
            #expect(removal.ops.contains { $0["op"] == .str("drop") && $0["args"]?["id"] == item["id"] })
            // Words again later are carded anew.
            let back = try event(s, ref: "E2", revision: "rev4", text: "Sweep the invented porch")
            sweep(s)
            #expect(s.inbox.unfiled().contains { from($0, back) })
        }
    }

    @Test func aFirstCaptureWithNoWordsStillFilesNothing() throws {
        let s = try setup()
        let empty = try event(s, ref: "E3", revision: "rev1", text: " ")
        sweep(s)
        #expect(try s.inbox.readState().ingested[empty] == "nothing_to_file")
        #expect(pOpen(s).isEmpty && s.inbox.unfiled().isEmpty)
    }

    // MARK: - 3. Crash recovery takes only a trusted card

    @Test func anUntrustedOrphanCardIsTakenBackAndMadeAgain() throws {
        let s = try setup()
        let id = try event(s, ref: "E4", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        let inbox = try #require(s.inbox.unfiled().first { from($0, id) })
        try s.inbox.file(inbox.id, into: s.folder, commands: s.commands)
        // The card in the binder is no longer as Sprava last trusted it, and the cursor lost the event's card.
        var raw = try #require(pOpen(s).first { $0.id == inbox.id }).raw
        raw.set("title", .str("Add from a dictation, as changed"))
        try ProposalStore.save(Proposal(raw: raw), in: s.folder)
        #expect(!s.commands.isTrusted(inbox.id, in: s.folder))
        var state = try s.inbox.readState()
        state.ingested[id] = "ingested"
        state.cards[id] = nil
        state.cardBinder?[id] = nil
        try s.inbox.save(state)

        sweep(s)
        state = try s.inbox.readState()
        #expect(state.cards[id] != inbox.id, "the untrusted card is not taken for the event's card")
        #expect(!pOpen(s).contains { $0.id == inbox.id })
        #expect(s.inbox.unfiled().contains { from($0, id) }, "the event's card is made again")
        #expect(state.ingested[id] == "unfiled")
    }
}

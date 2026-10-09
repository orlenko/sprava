import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the fifth calibrated review of the capture layer and the random sequences it asked for: copies
/// from an unregistered folder belong to the registered chain, a raise from anywhere reaches it, and work a binder
/// could not take (a withdrawal, a retraction) is finished, never dropped. Invented data only.
@Suite(.serialized) struct CalibratedReview5Tests {
    let adapter = "11111111-2222-4333-8444-5555555555f5"
    let unregistered = "00000000-2222-4333-8444-5555555555e5"   // not registered, swept first

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    func event(_ s: PSetup, _ device: String? = nil, ref: String, revision: String, text: String, private: Bool = false,
               retracted: Bool = false) throws -> String {
        try pEvent(s, device: device ?? adapter, app: "adapter", ref: ref, revision: revision, text: text) {
            if `private` { $0.set("sensitivity", .str("private")) }
            if retracted { $0.set("retracted", .bool(true)) }
        }
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func from(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"] == .array([.string(id)]) }

    /// The first event's card, filed into the binder and waiting there.
    func filedCard(_ s: PSetup, ref: String) throws -> (String, Proposal) {
        let id = try event(s, ref: ref, revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { from($0, id) }).id, into: s.folder, commands: s.commands)
        return (id, try #require(pOpen(s).first { from($0, id) }))
    }

    func readOnly(_ s: PSetup, _ on: Bool) { chmod(ProposalStore.dir(s.folder).path, on ? 0o500 : 0o700) }

    // MARK: - Copies from an unregistered folder

    @Test func aCopyCardedFirstWithNewerWordsReplacesTheChainsOlderCard() throws {
        let s = try setup()
        let (_, old) = try filedCard(s, ref: "U1")
        // The next revision arrives in both folders; the unregistered copy is swept first and gets the card.
        let copy = try event(s, unregistered, ref: "U1", revision: "rev2", text: "Call the invented roofer Monday")
        let revision = try event(s, ref: "U1", revision: "rev2", text: "Call the invented roofer Monday")
        sweep(s)
        #expect(try s.inbox.readState().ingested[revision] == "duplicate")
        #expect(s.inbox.unfiled().contains { from($0, copy) })
        #expect(!pOpen(s).contains { $0.id == old.id }, "the chain's older card is withdrawn")
    }

    @Test func aPrivateEventFromAnUnregisteredFolderRaisesTheRegisteredChain() throws {
        let s = try setup()
        let (_, card) = try filedCard(s, ref: "U2")
        _ = try event(s, unregistered, ref: "U2", revision: "rev9", text: "Something else", private: true)
        sweep(s)
        let fresh = try #require(pOpen(s).first { $0.id == card.id })
        #expect(fresh.raw["provenance"]?["private"] == .bool(true))
    }

    // MARK: - Work a binder could not take is finished

    @Test func aCorrectionWhoseWithdrawalFailsIsTriedAgain() throws {
        let s = try setup()
        let (_, old) = try filedCard(s, ref: "W1")
        readOnly(s, true)
        defer { readOnly(s, false) }
        let revision = try event(s, ref: "W1", revision: "rev2", text: "Call the invented roofer Monday")
        sweep(s)
        // The revision's own card is made first; the old card's withdrawal stays owed to its binder.
        #expect(try s.inbox.readState().ingested[revision] == "unfiled")
        #expect(s.inbox.hasDeferredWork(in: s.folder))
        #expect(pOpen(s).contains { $0.id == old.id })
        readOnly(s, false)
        sweep(s)
        #expect(!pOpen(s).contains { $0.id == old.id })
        #expect(s.inbox.unfiled().contains { from($0, revision) })
    }

    @Test func aRetractionLeftPartDoneIsFinishedWhenARestoreOvertakesIt() throws {
        let s = try setup()
        let (_, old) = try filedCard(s, ref: "W2")
        readOnly(s, true)
        defer { readOnly(s, false) }
        let retraction = try event(s, ref: "W2", revision: "retracted", text: "", retracted: true)
        sweep(s)
        #expect(try s.inbox.readState().ingested[retraction] == "retracting")
        let restore = try event(s, ref: "W2", revision: "rev3", text: "Call the invented roofer again")
        sweep(s)
        readOnly(s, false)
        sweep(s)
        #expect(!pOpen(s).contains { $0.id == old.id }, "the retraction's part, the older card, is withdrawn")
        #expect(s.inbox.unfiled().contains { from($0, restore) }, "the restore's card stays")
        #expect(try s.inbox.readState().ingested[retraction] == "retracted")
    }
}

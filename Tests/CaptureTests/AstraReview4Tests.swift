import BinderStore
@testable import Capture
import CaptureTestSupport
import CryptoKit
import Darwin
import Foundation
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the fourth adversarial review of increment 1 (key and credential files in intake, hub
/// withdrawal while the outbox fails, private corrections that close items, correction cards that could not be
/// kept, unreadable op logs, exhausted id sequences) and the MCP socket's modes. Invented data only.
@Suite(.serialized) struct AstraReview4Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func journal(_ s: PSetup) -> String { (try? String(contentsOf: s.inbox.journalURL, encoding: .utf8)) ?? "" }

    @Test func aCredentialFileInIntakeIsHeldUnread() throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "credentials.json", #"{"password": "INVENTED-SECRET-4410"}"#)
        let result = t.card(s)
        // A key or credential file is never filed (binder-v0 §3.3; the transaction guard refuses it). With nothing
        // else to file, a card would have no change to approve, so none is made: Health counts the file as held.
        #expect(result.carded == 0 && result.heldWithoutCard == 1)
        #expect(t.open(s).isEmpty)
        // Nothing waits for the clerk or a brain, and the file's words are nowhere.
        #expect(IntakeReadings(support: s.support).all().isEmpty)
        let cursor = try String(contentsOf: s.support.appendingPathComponent("capture/intake.json"), encoding: .utf8)
        #expect(!cursor.contains("INVENTED-SECRET"))
        // It stays so on every scan.
        #expect(t.card(s).heldWithoutCard == 1 && t.open(s).isEmpty)
    }

    @Test func aKeyFileInAMessagesAttachmentsFolderHoldsTheMessage() throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "mail/levy.md", IntakeReadingTests.message)
        try t.write(s, "mail/levy attachments/id_ed25519", "INVENTED-SECRET-5520")
        try t.write(s, "mail/levy attachments/notice.txt", IntakeReadingTests.notice)
        #expect(t.card(s).held == 1)
        let card = try #require(t.open(s).first)
        #expect(card.title.hasPrefix("Held:"))
        #expect(card.raw["provenance"]?["intake"]?["held"]?.stringValue?.contains("id_ed25519") == true)
        #expect(IntakeReadings(support: s.support).all().isEmpty)
        // The message and the other attachment can still be filed; the key file never is, so the card stays one the
        // person can approve, and the key stays where it was.
        #expect(card.ops.count == 2)
        #expect(!card.ops.contains { $0["args"]?["from"]?.stringValue?.contains("id_ed25519") == true })
        _ = try TekaStore(folder: s.folder).approve(card, now: now)
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/mail/levy attachments/id_ed25519").path))
    }

    // MARK: - 4. A correction card that could not be kept is tried again, once

    /// A note from an adapter whose two lines were filed and approved, then a public revision that changes both.
    func correctedNote(_ s: PSetup, ref: String) throws -> String {
        let adapter = "11111111-2222-4333-8444-5555555555d2"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        _ = try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: "rev1", text: "Call the roofer\nOrder the blinds")
        try bFileAndApprove(s)
        return try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: "rev2",
                          text: "Call the roofer on Monday\nOrder the blinds on Friday")
    }

    func corrections(_ folder: URL, of event: String) -> [Proposal] {
        ProposalStore.list(in: folder).map(\.0).filter { CaptureInbox.isCorrection($0, of: event) && $0.state == "proposed" }
    }

    @Test func aCorrectionCardThatCannotBeSavedIsRetried() throws {
        let s = try pSetup()
        let event = try correctedNote(s, ref: "R2")
        let proposals = ProposalStore.dir(s.folder)
        chmod(proposals.path, 0o500)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        chmod(proposals.path, 0o700)
        #expect(try s.inbox.readState().ingested[event] == "ingested")
        #expect(corrections(s.folder, of: event).isEmpty)
        #expect(journal(s).contains("card_failed"))

        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(try s.inbox.readState().ingested[event] == "proposed")
        let made = corrections(s.folder, of: event)
        #expect(made.count == 1)
        #expect(made.allSatisfy { s.commands.isTrusted($0.id, in: s.folder) })
    }

    @Test func aCorrectionCardThatCannotBeTrustedIsRemovedAndRetried() throws {
        let s = try pSetup()
        let event = try correctedNote(s, ref: "R3")
        let runtime = s.support.appendingPathComponent("runtime")
        chmod(runtime.path, 0o500)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        chmod(runtime.path, 0o700)
        #expect(try s.inbox.readState().ingested[event] == "ingested")
        // No card is left that could never be approved.
        #expect(corrections(s.folder, of: event).isEmpty)

        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        let made = corrections(s.folder, of: event)
        #expect(made.count == 1)
        #expect(made.allSatisfy { s.commands.isTrusted($0.id, in: s.folder) })
    }
}

import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the eighth calibrated review of the capture layer, and the two guarantees that replace pushing
/// privacy out card by card: a card is redacted or refused at approval from the cursor's privacy at that moment, and a
/// chain's privacy debt over its filed items is cleared only by one complete pass. Invented data only.
@Suite(.serialized) struct CalibratedReview8Tests {
    let adapter = "11111111-2222-4333-8444-5555555555f8"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func from(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"] == .array([.string(id)]) }

    func away(_ folder: URL) -> URL { folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".away") }

    /// The first event's card, filed into the binder and waiting there.
    func filedCard(_ s: PSetup, ref: String) throws -> Proposal {
        let id = try pEvent(s, device: adapter, app: "adapter", ref: ref, revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { from($0, id) }).id, into: s.folder, commands: s.commands)
        return try #require(pOpen(s).first { from($0, id) })
    }

    // MARK: - A. The approval gate

    @Test func aCardOfAPrivateChainIsRedactedAtApprovalWhateverWasMissed() throws {
        let s = try setup()
        let card = try filedCard(s, ref: "G1")
        // The chain is private in the cursor, but nothing reached the card (as if every propagation had been missed).
        let proposals = ProposalStore.dir(s.folder)
        chmod(proposals.path, 0o500)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "G1", revision: "rev2", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
        }
        sweep(s)
        chmod(proposals.path, 0o700)
        var state = try s.inbox.readState()
        state.debts = []
        try s.inbox.save(state)
        #expect(pOpen(s).first { $0.id == card.id }?.raw["provenance"]?["private"] != .bool(true))

        let approvable = try #require(s.inbox.cardForApproval(card.id, in: s.folder, commands: s.commands, now: pNow))
        #expect(CaptureInbox.fullyRedacted(approvable, catalog: Teka.read(s.folder).catalog))
        _ = try TekaStore(folder: s.folder).approve(approvable, now: pNow)
        let item = try #require(Teka.read(s.folder).items.compactMap(\.object).first { $0["title"] == .str("Call the invented roofer") })
        #expect(item["redact"] == .bool(true))
    }

    @Test func aCardWhoseChainCannotBeToldIsRefused() throws {
        let s = try setup()
        let card = try filedCard(s, ref: "G2")
        // The cursor no longer knows the event the card comes from.
        var state = try s.inbox.readState()
        state.ingested = [:]
        try s.inbox.save(state)
        #expect(s.inbox.cardForApproval(card.id, in: s.folder, commands: s.commands, now: pNow) == nil)
    }

    // MARK: - B. One privacy debt per chain

    @Test func aRaiseOwedWhenTheBinderGoesAwayIsPaidWhenItIsBack() throws {
        let s = try setup()
        let card = try filedCard(s, ref: "D1")
        let proposals = ProposalStore.dir(s.folder)
        chmod(proposals.path, 0o500)
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "D1", revision: "rev2", text: "Call the invented roofer") {
            $0.set("sensitivity", .str("private"))
        }
        sweep(s)
        #expect(try s.inbox.readState().debts?.isEmpty == false)
        chmod(proposals.path, 0o700)
        // The binder goes away before the next sweep: the debt stays.
        try FileManager.default.moveItem(at: s.folder, to: away(s.folder))
        sweep(s)
        #expect(try s.inbox.readState().debts?.isEmpty == false, "a binder out of reach keeps the debt")
        try FileManager.default.moveItem(at: away(s.folder), to: s.folder)
        sweep(s)
        #expect(try s.inbox.readState().debts?.isEmpty != false)
        #expect(pOpen(s).first { $0.id == card.id }?.raw["provenance"]?["private"] == .bool(true))
    }

    @Test func aPrivateRetractionWhileTheBinderIsAwayRedactsTheItemsTheChainChanged() throws {
        let s = try setup()
        try bAddItem(s, id: "estate-example-2026-911", title: "Invented levy payment")
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "D2", revision: "rev1", text: "The invented levy is now high priority")
        sweep(s)
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("invented"))])
        let update = JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([
            ("id", .str("estate-example-2026-911")), ("set", .obj([("priority", .str("high"))]))]))])
        let change = Proposal.make(title: "Raise the levy's priority", actor: actor, ops: [update],
                                   provenance: JSONObject([(key: "events", value: .array([.string(id)]))]), now: pNow)
        try ProposalStore.save(change, in: s.folder)
        try s.commands.trustProposals([change.id], in: s.folder)
        _ = try TekaStore(folder: s.folder).approve(change, now: pNow)

        try FileManager.default.moveItem(at: s.folder, to: away(s.folder))
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "D2", revision: "retracted", text: "") {
            $0.set("sensitivity", .str("private")); $0.set("retracted", .bool(true))
        }
        sweep(s)
        try FileManager.default.moveItem(at: away(s.folder), to: s.folder)
        sweep(s)
        let redaction = pOpen(s).filter { CaptureInbox.onlyRedacts($0) }
        #expect(redaction.contains { $0.ops.contains { $0["args"]?["id"] == .str("estate-example-2026-911") } },
                "the item the capture changed is offered for redaction")
        #expect(try s.inbox.readState().debts?.isEmpty != false)
    }

    // MARK: - Intake recovery matches every source file

    @Test func aRecoveredEmailCardWithAChangedAttachmentIsMadeAgain() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-review8-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        try adoptAsCommand(folder, commands: commands, now: pNow, today: today)
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: pNow) }
        let mail = folder.appendingPathComponent("intake/mail", isDirectory: true)
        try FileManager.default.createDirectory(at: mail.appendingPathComponent("2026-10-01_12_levy attachments"), withIntermediateDirectories: true)
        try Data("---\nsubject: \"Invented levy\"\nfrom: \"Example Manager <manager@example.com>\"\n---\nThe notice is attached.\n".utf8)
            .write(to: mail.appendingPathComponent("2026-10-01_12_levy.md"))
        let attachment = mail.appendingPathComponent("2026-10-01_12_levy attachments/levy.txt")
        try Data("INVENTED NOTICE. The levy is due November 1.".utf8).write(to: attachment)
        let watcher = IntakeWatcher(support: support)
        func rows() -> [ShelfRow] { [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))] }
        func open() -> [Proposal] { ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" } }
        _ = watcher.scan(binders: rows(), commands: commands, now: pNow)
        _ = watcher.scan(binders: rows(), commands: commands, now: pNow)
        let old = try #require(open().first)

        // A crash kept the card from the cursor; then the attachment changed.
        var state = try watcher.load()
        let key = folder.standardizedFileURL.path
        for name in state[key]?.keys.map({ $0 }) ?? [] { state[key]?[name]?.card = nil }
        try watcher.save(state)
        try Data("INVENTED NOTICE, CORRECTED. The levy is due November 15.".utf8).write(to: attachment)
        _ = watcher.scan(binders: rows(), commands: commands, now: pNow)
        _ = watcher.scan(binders: rows(), commands: commands, now: pNow)

        #expect(!open().contains { $0.id == old.id }, "the stale card is withdrawn")
        let fresh = try #require(open().first)
        let filed = fresh.ops.filter { $0["op"] == .str("file_document") }.compactMap { $0["args"]?["document"]?["sha256"]?.stringValue }
        #expect(filed.contains(try #require(DocumentPaths.sha256(of: attachment))))
    }
}

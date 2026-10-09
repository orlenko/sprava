import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the seventh calibrated review of the capture layer: work a binder missed is kept by the chain it
/// belongs to, and nothing is counted done on what a binder out of reach could not show. Invented data only.
@Suite(.serialized) struct CalibratedReview7Tests {
    let adapter = "11111111-2222-4333-8444-5555555555f7"
    let unregistered = "00000000-2222-4333-8444-5555555555e7"

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func from(_ p: Proposal, _ id: String) -> Bool { p.raw["provenance"]?["events"] == .array([.string(id)]) }

    func away(_ folder: URL) -> URL { folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".away") }

    // MARK: - 1. A raise from an unregistered folder while the binder is away

    @Test func aRaiseFromAnUnregisteredFolderReachesABinderThatWasAway() throws {
        let s = try setup()
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "V1", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        try s.inbox.file(try #require(s.inbox.unfiled().first { from($0, first) }).id, into: s.folder, commands: s.commands)
        let card = try #require(pOpen(s).first)

        try FileManager.default.moveItem(at: s.folder, to: away(s.folder))
        _ = try pEvent(s, device: unregistered, app: "adapter", ref: "V1", revision: "other", text: "Something else") {
            $0.set("sensitivity", .str("private"))
        }
        sweep(s)
        try FileManager.default.moveItem(at: away(s.folder), to: s.folder)

        #expect(s.inbox.settle(binder: s.folder, commands: s.commands, now: pNow))
        let fresh = try #require(pOpen(s).first { $0.id == card.id })
        #expect(fresh.raw["provenance"]?["private"] == .bool(true), "the card the binder held is made private")
    }

    @Test func aPrivateEventFromAnUnregisteredFolderMakesALaterChainPrivate() throws {
        let s = try setup()
        _ = try pEvent(s, device: unregistered, app: "adapter", ref: "V2", revision: "other", text: "Something else") {
            $0.set("sensitivity", .str("private"))
        }
        sweep(s)
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "V2", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        let card = try #require(s.inbox.unfiled().first { from($0, first) })
        #expect(card.raw["provenance"]?["private"] == .bool(true))
    }

    // MARK: - 2. Clerk work is never counted done on a binder out of reach

    @Test func theClerksWorkWaitsForABinderThatIsAway() throws {
        let s = try pSetup()
        let note = try s.producer.prepareNote("Call the invented notary about the deed", binderHint: "estate-example",
                                             startedAt: pNow, savedAt: pNow, locale: "en-CA")
        try s.inbox.recordNotice(event: note.id, digest: note.digest)
        try s.producer.publish(note)
        sweep(s)
        #expect(try s.inbox.readState().cardBinder?[note.id] != nil, "the code-built card is filed in the binder")

        try FileManager.default.moveItem(at: s.folder, to: away(s.folder))
        #expect(s.inbox.nextForClerk() == nil)
        #expect(try s.inbox.readState().clerk?[note.id] == "pending", "not counted acted")
        try FileManager.default.moveItem(at: away(s.folder), to: s.folder)
        #expect(s.inbox.nextForClerk()?.event.id == note.id)
    }

    @Test func theIntakeClerksWorkWaitsForABinderThatIsAway() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-review7-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        try adoptAsCommand(folder, commands: commands, now: pNow, today: today)
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: pNow) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        try Data("INVENTED NOTICE. The special levy of $450.00 is due November 1, 2026.".utf8)
            .write(to: folder.appendingPathComponent("intake/levy.txt"))
        let watcher = IntakeWatcher(support: support)
        func rows() -> [ShelfRow] { [ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder))] }
        _ = watcher.scan(binders: rows(), commands: commands, now: pNow, requireReading: true)
        let prepared = watcher.prepare(binders: rows(), deviceID: "dev", reader: .inProcess)
        _ = watcher.scan(binders: rows(), commands: commands, now: pNow, prepared: prepared, requireReading: true)

        try FileManager.default.moveItem(at: folder, to: away(folder))
        #expect(watcher.nextForReading() == nil)
        #expect(IntakeReadings(support: support).all().allSatisfy { $0.state == "pending" }, "not counted kept")
        try FileManager.default.moveItem(at: away(folder), to: folder)
        #expect(watcher.nextForReading() != nil)
    }
}

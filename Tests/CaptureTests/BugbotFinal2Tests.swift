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

/// Regressions from Codex Bugbot's second pass over the final capture layer (PR #13). Invented data only.
@Suite(.serialized) struct BugbotFinal2Tests {
    let adapter = "11111111-2222-4333-8444-5555555555fd"
    let final1 = BugbotFinalTests()

    func setup() throws -> PSetup {
        let s = try pSetup()
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        return s
    }

    @discardableResult
    func sweep(_ s: PSetup) -> CaptureInbox.SweepResult { s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow) }

    func eventFile(_ s: PSetup, _ id: String) -> URL { s.producer.root.appendingPathComponent(adapter).appendingPathComponent("\(id).json") }

    // MARK: - MUST-FIX

    @Test func anEventWhoseMediaNeverArriveIsTakenInAfterTheGracePeriod() throws {
        let s = try setup()
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "M1", revision: "rev1", text: "Call the invented roofer") { o in
            let path = (o["id"]?.stringValue ?? "") + ".audio.m4a"
            o.set("media", .array([.obj([("kind", .str("audio")), ("sha256", .string(String(repeating: "0", count: 64))),
                                         ("path", .string(path)), ("bytes", .int(10))])]))
        }
        #expect(sweep(s).pending == 1, "media still arriving")
        final1.age(eventFile(s, id), hours: 2)
        sweep(s)
        #expect(s.inbox.unfiled().contains { final1.from($0, id) }, "its words reach a card")
        #expect(s.inbox.eventsMissingMedia() == [id])
        // The media are looked for again, and once there they are no longer missing.
        try Data(repeating: 1, count: 10).write(to: s.producer.root.appendingPathComponent(adapter).appendingPathComponent("\(id).audio.m4a"))
        sweep(s)
        #expect(s.inbox.eventsMissingMedia().isEmpty)
    }

    @Test func anIntakeReplacementIsNotWrittenIntoABinderAnotherMacOwnsNow() async throws {
        let t = IntakeReadingTests()
        let s = try t.setup()
        try t.write(s, "levy.txt", IntakeReadingTests.notice)
        _ = t.card(s)
        let tier0 = try #require(t.open(s).first)
        let model = ScriptedModel(extractions: [.obj([("items", .array([
            item("The special levy of $450.00 is due November 1, 2026", "Pay the special levy", "pay", when: "November 1, 2026"),
        ]))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Notice of special levy")), ("date_text", .str("September 30, 2026")),
                               ("summary", .str("An invented notice.")), ("reply_needed", .bool(false))])
        let entry = try #require(s.watcher.nextForReading())
        let binder = FilingBinder(name: Teka.read(s.folder).name, description: "", folder: s.folder,
                                  openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))
        let doc = await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: binder, now: t.now)
        // Before the reading is committed, the binder is handed to another Mac.
        try Data(#"{"device": "another-invented-mac"}"#.utf8).write(to: s.folder.appendingPathComponent(".sprava/owner.json"))
        let before = ProposalStore.list(in: s.folder).count
        let outcome = s.watcher.commitReading(entry, doc, commands: s.commands, now: t.now)
        #expect(!outcome.replaced)
        #expect(ProposalStore.list(in: s.folder).count == before, "nothing new is written there")
        #expect(t.open(s).map(\.id) == [tier0.id])
        #expect(IntakeReadings(support: s.support).load(entry.id)?.state == "pending")
    }

    @Test func twoProcessesNeverTakeTheSameStamp() throws {
        let s = try setup()
        final class Stamps: @unchecked Sendable {
            let lock = NSLock()
            var all: [String] = []
            var newest: (Int, Int) = (0, -1)
        }
        let stamps = Stamps()
        let root = s.producer.root, support = s.support
        DispatchQueue.concurrentPerform(iterations: 40) { _ in
            // Each its own producer, as two processes would be: they share only the files.
            let producer = CaptureProducer(root: root, deviceID: pDevice, support: support)
            guard let note = try? producer.prepareNote("Call the invented roofer", startedAt: pNow, savedAt: pNow, locale: "en-CA"),
                  let hlc = note.event["hlc"] else { return }
            let stamp = (Int(hlc["wall_ms"]?.numberValue?.safeInteger ?? 0), Int(hlc["counter"]?.numberValue?.safeInteger ?? 0))
            stamps.lock.withLock {
                stamps.all.append(JSONWriter.compact(hlc))
                if stamp > stamps.newest { stamps.newest = stamp }
            }
        }
        #expect(stamps.all.count == 40)
        #expect(Set(stamps.all).count == 40, "no stamp is taken twice")
        let saved = try #require(try StateFile.read(HLC.self, from: support.appendingPathComponent("capture/producer-hlc.json")))
        #expect((Int(saved.wall_ms), saved.counter) == stamps.newest, "the saved clock is the newest, never an older one")
    }

    @Test func anEventChangedAfterItWasTakenInIsNotReadByTheClerk() throws {
        let s = try setup()
        let id = try pEvent(s, device: adapter, app: "adapter", ref: "C1", revision: "rev1", text: "Call the invented roofer")
        sweep(s)
        let card = try #require(s.inbox.unfiled().first { final1.from($0, id) })
        // Rewritten in place: same id and source, other words.
        let file = eventFile(s, id)
        let changed = try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "Call the invented roofer", with: "Sell the invented house")
        try Data(changed.utf8).write(to: file)
        #expect(s.inbox.nextForClerk() == nil)
        #expect(try s.inbox.readState().clerk?[id] == "kept")
        #expect(s.inbox.unfiled().contains { $0.id == card.id }, "the card made from the words taken in stays")
        #expect(s.inbox.health().quarantined == 1)
    }

    // MARK: - Issues fixed here

    @Test func malformedMediaAreQuarantined() throws {
        let s = try setup()
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "Q1", revision: "rev1", text: "Call the invented roofer") {
            $0.set("media", .str("not a list"))
        }
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "Q2", revision: "rev1", text: "Call the invented roofer") {
            $0.set("media", .array([.obj([("kind", .str("audio")), ("sha256", .string(String(repeating: "0", count: 64)))])]))
        }
        #expect(sweep(s).quarantined == 2)
    }
}

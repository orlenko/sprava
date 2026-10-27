import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
import Clerk
import ClerkTestSupport
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

@Suite struct BinderCaptureDestinationTests {
    func proposed(_ folder: URL) -> [Proposal] { ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" } }

    @Test func selectingAPrivateBinderBeatsAContradictoryNameHint() throws {
        let s = try pSetup(), picked = try namedBinder(s, name: "private-example", disclosure: "none")
        let note = try s.producer.prepareNote("Call the invented notary", binderHint: Teka.read(s.folder).name, isPrivate: true,
                                              startedAt: pNow, savedAt: pNow)
        try s.inbox.recordNotice(event: note.id, digest: note.digest, binder: picked)
        try s.producer.publish(note)
        _ = s.inbox.sweep(binders: pRows(s) + [shelfRow(picked)], commands: s.commands, now: pNow)
        #expect(s.inbox.unfiled().isEmpty && proposed(s.folder).isEmpty)
        let card = try #require(proposed(picked).first)
        #expect(card.raw["provenance"]?["private"] == .bool(true))
        #expect(card.ops.allSatisfy { $0["args"]?["item"]?["redact"] == .bool(true) })
    }

    @Test func repeatedBinderNamesDoNotChangeTheSelectedPhysicalFolder() throws {
        let s = try pSetup(), first = try namedBinder(s, name: "shared-example"), picked = try namedBinder(s, name: "shared-example")
        let note = try s.producer.prepareNote("Read the invented notice", binderHint: "shared-example", startedAt: pNow, savedAt: pNow)
        try s.inbox.recordNotice(event: note.id, digest: note.digest, binder: picked)
        try s.producer.publish(note)
        _ = s.inbox.sweep(binders: [shelfRow(first), shelfRow(picked)], commands: s.commands, now: pNow)
        #expect(proposed(first).isEmpty && proposed(picked).count == 1 && s.inbox.unfiled().isEmpty)
    }

    @Test func aMissingChosenBinderNeverFallsBackToAnotherBindersMatchingHint() throws {
        let s = try pSetup(), picked = try namedBinder(s, name: "private-example", disclosure: "none")
        let note = try s.producer.prepareNote("Keep the invented papers", binderHint: Teka.read(s.folder).name, isPrivate: true,
                                              startedAt: pNow, savedAt: pNow)
        try s.inbox.recordNotice(event: note.id, digest: note.digest, binder: picked)
        try s.producer.publish(note)
        _ = s.inbox.sweep(binders: pRows(s), commands: s.commands, now: pNow)
        #expect(proposed(s.folder).isEmpty && s.inbox.unfiled().count == 1)
    }

    @Test func anUnverifiedNoticeCannotChooseAPrivateBinder() throws {
        let s = try pSetup(), picked = try namedBinder(s, name: "private-example", disclosure: "none")
        let note = try s.producer.prepareNote("Read the invented letter", startedAt: pNow, savedAt: pNow)
        try s.inbox.recordNotice(event: note.id, digest: "sha256:wrong", binder: picked)
        try s.producer.publish(note)
        _ = s.inbox.sweep(binders: [shelfRow(picked)], commands: s.commands, now: pNow)
        #expect(proposed(picked).isEmpty && s.inbox.unfiled().count == 1)
    }

    @Test func anEventFileCannotChooseAPrivateBinderWithoutTheAppsExplicitNotice() throws {
        let s = try pSetup(), picked = try namedBinder(s, name: "private-example", disclosure: "none")
        let id = try pEvent(s, device: pDevice, app: "sprava", ref: "invented-ref", revision: "1", text: "Read the invented letter") {
            $0.set("binder", .str(picked.path)); $0.set("binder_hint", .str("private-example"))
        }
        let file = s.producer.folder.appendingPathComponent(id + ".json")
        try s.inbox.recordNotice(event: id, digest: CaptureInbox.digest(Data(contentsOf: file)))
        _ = s.inbox.sweep(binders: [shelfRow(picked)], commands: s.commands, now: pNow)
        #expect(proposed(picked).isEmpty && s.inbox.unfiled().count == 1)
    }

    @Test func theClerkKeepsTheExplicitPrivateDestinationAfterARestart() async throws {
        let s = try pSetup(), picked = try namedBinder(s, name: "private-example", disclosure: "none")
        let note = try s.producer.prepareNote("Call the invented notary", isPrivate: true, startedAt: pNow, savedAt: pNow)
        try s.inbox.recordNotice(event: note.id, digest: note.digest, binder: picked)
        try s.producer.publish(note)
        let rows = pRows(s) + [shelfRow(picked)]
        _ = s.inbox.sweep(binders: rows, commands: s.commands, now: pNow)
        let restarted = CaptureInbox(root: s.producer.root, support: s.support)
        let work = try #require(restarted.nextForClerk())
        let filing = work.filing(rows: rows, list: FilingList(support: s.support), deviceID: s.commands.deviceID)
        #expect(filing.count == 1 && filing.first?.folder == picked)
        let model = ScriptedModel(extractions: [.obj([("items", .array([item("Call the invented notary", "Call the invented notary", "call", when: "none")]))])])
        let reading = await Clerk(model: model).read(work.event, filing: filing, hint: work.hint, now: pNow)
        #expect(!reading.items.isEmpty)
        let outcome = restarted.commitClerk(work, reading, filing: filing, rows: rows, commands: s.commands, seconds: 0, now: pNow)
        #expect(outcome.filed == 1)
        #expect(proposed(s.folder).isEmpty && proposed(picked).count == 1 && restarted.unfiled().isEmpty)
    }

    @Test(arguments: ["done", "same"], [false, true])
    func aForeignReadingCannotTouchOrSuppressAnItemWithTheSameLocalID(_ relation: String, retaggedFiling: Bool) async throws {
        let s = try pSetup(), picked = try namedBinder(s, name: "private-example", disclosure: "none")
        let actor = JSONObject([(key: "kind", value: .str("user"))])
        for (folder, title) in [(picked, "Pay the invented inspection"), (s.folder, "Pay the invented invoice")] {
            let value: JSONValue = .obj([("id", .str("shared-1")), ("title", .str(title)), ("status", .str("open")),
                                         ("priority", .str("normal")), ("no_deadline", .bool(true))])
            _ = try TekaStore(folder: folder).apply([.init(op: "add_item", args: JSONObject([(key: "item", value: value)]), actor: actor)], now: pNow)
        }
        let note = try s.producer.prepareNote("Paid the invented invoice", isPrivate: true, startedAt: pNow, savedAt: pNow)
        try s.inbox.recordNotice(event: note.id, digest: note.digest, binder: picked); try s.producer.publish(note)
        let rows = pRows(s) + [shelfRow(picked)]
        _ = s.inbox.sweep(binders: rows, commands: s.commands, now: pNow)
        let original = try #require(proposed(picked).first)
        let work = try #require(s.inbox.nextForClerk())
        let scoped = work.filing(rows: rows, list: FilingList(support: s.support), deviceID: s.commands.deviceID)
        #expect(scoped.count == 1 && scoped.first?.openItems.contains { $0.id == .str("shared-1") && $0.title == "Pay the invented inspection" } == true)
        let name = Teka.read(s.folder).name
        let foreign = [FilingBinder(name: name, description: "Invented invoice", folder: s.folder,
                                    openItems: FilingBinder.candidates(catalog: Teka.read(s.folder).catalog))]
        let model = ScriptedModel(extractions: [.obj([("items", .array([item("Paid the invented invoice", "Paid the invented invoice", "pay", when: "none")]))])])
        model.duplicates = ["invoice": ("shared-1", relation)]
        let reading = await Clerk(model: model).read(work.event, filing: foreign, hint: name, now: pNow)
        #expect(reading.items.first?.match?.candidate.id == .str("shared-1"))
        #expect(reading.items.first?.match?.relation == relation)
        let outcome = s.inbox.commitClerk(work, reading, filing: retaggedFiling ? scoped : foreign,
                                         rows: rows, commands: s.commands, seconds: 0, now: pNow)
        #expect(!outcome.replaced && outcome.filed == 0)
        #expect(proposed(picked).first?.raw == original.raw)
        #expect(proposed(s.folder).isEmpty)
    }
}

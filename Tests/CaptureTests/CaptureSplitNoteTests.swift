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

/// Another adopted binder of this Mac, named `name`, at `disclosure`, its adoption cards rejected.
func namedBinder(_ s: PSetup, name: String, disclosure: String = "title") throws -> URL {
    let folder = try makeTeka(fixture: "sprava-v0", folderName: name) { f in
        let url = f.appendingPathComponent("catalog.json")
        var o = try #require(try JSONParser.parse(Data(contentsOf: url)).value.objectValue)
        var meta = try #require(o["meta"]?.objectValue)
        meta.set("name", .string(name))
        meta.set("disclosure", .string(disclosure))
        o.set("meta", .object(meta))
        try Data(JSONWriter.pretty(.object(o)).utf8).write(to: url)
    }
    try adoptAsCommand(folder, commands: s.commands, now: pNow, today: today)
    for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: pNow) }
    #expect(Teka.read(folder).isAdopted)
    return folder
}

func shelfRow(_ folder: URL) -> ShelfRow { ShelfRow(folder: folder, source: .picked, archived: false, teka: Teka.read(folder)) }

/// A note whose lines the clerk filed into two binders: a correction follows each item's own line, in its own
/// binder, and is made once even when one binder's card could not be saved. Invented data only.
@Suite(.serialized) struct CaptureSplitNoteTests {
    /// A two-line note from a registered adapter whose items the clerk filed one into each of two binders and the
    /// person approved. Returns the binders, the event and the adapter folder.
    func splitNote(_ s: PSetup, titles: (String, String)) async throws -> (a: URL, b: URL, first: String, adapter: String) {
        let adapter = "11111111-2222-4333-8444-5555555555c1"
        try s.inbox.registerProducer(folder: adapter, app: "adapter")
        let other = try namedBinder(s, name: "household-example")
        let first = try pEvent(s, device: adapter, app: "adapter", ref: "S1", revision: "rev1", text: "Call the roofer\nOrder the blinds")
        _ = s.inbox.sweep(binders: [shelfRow(s.folder), shelfRow(other)], commands: s.commands, now: pNow)
        let work = try #require(s.inbox.nextForClerk())
        let model = BugModel([.obj([("items", .array([item("Call the roofer", titles.0, "call"), item("Order the blinds", titles.1, "other")]))])])
        var interp = await Clerk(model: model).read(work.event, filing: [], hint: nil, now: pNow)
        #expect(interp.items.count == 2)
        interp.items[0].binder = "estate-example"
        interp.items[1].binder = "household-example"
        let out = s.inbox.commitClerk(work, interp, filing: [], rows: [shelfRow(s.folder), shelfRow(other)], commands: s.commands,
                                      seconds: 1, now: pNow)
        #expect(out.filed == 2)
        for folder in [s.folder, other] {
            for (p, _) in ProposalStore.list(in: folder) where p.state == "proposed" { _ = try TekaStore(folder: folder).approve(p, now: pNow) }
        }
        return (s.folder, other, first, adapter)
    }

    func open(_ folder: URL) -> [Proposal] { ProposalStore.list(in: folder).map(\.0).filter { $0.state == "proposed" } }

    @Test func aCorrectionFollowsEachItemsOwnLine() async throws {
        let s = try pSetup()
        let (a, b, _, adapter) = try await splitNote(s, titles: ("Call the roofer", "Order the blinds"))
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "S1", revision: "rev2", text: "Call the roofer on Monday\nOrder the blinds")
        _ = s.inbox.sweep(binders: [shelfRow(a), shelfRow(b)], commands: s.commands, now: pNow)
        let card = try #require(open(a).first)
        #expect(open(a).count == 1)
        #expect(card.ops.map { $0["op"]?.stringValue } == ["update_item"])
        #expect(card.ops.first?["args"]?["set"]?["title"] == .str("Call the roofer on Monday"))
        #expect(open(b).isEmpty)
        #expect(s.inbox.unfiled().isEmpty)
    }

    /// A new line is proposed once, beside the item of the line before it; a clerk's own title (some of the line's
    /// words, never others) stays.
    @Test func aNewLineIsProposedOnce() async throws {
        let s = try pSetup()
        let (a, b, _, adapter) = try await splitNote(s, titles: ("Roofer", "Blinds"))
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "S1", revision: "rev2",
                       text: "Call the roofer before noon\nOrder the blinds\nMeasure the windows")
        _ = s.inbox.sweep(binders: [shelfRow(a), shelfRow(b)], commands: s.commands, now: pNow)
        #expect(open(a).isEmpty)                                    // the clerk's title is its own words
        let card = try #require(open(b).first)
        #expect(card.ops.map { $0["op"]?.stringValue } == ["add_item"])
        #expect(card.ops.first?["args"]?["item"]?["title"] == .str("Measure the windows"))
        #expect(s.inbox.unfiled().isEmpty)
        // A line taken out offers to drop its item, in its own binder only.
        _ = try pEvent(s, device: adapter, app: "adapter", ref: "S1", revision: "rev3", text: "Call the roofer before noon\nMeasure the windows")
        _ = s.inbox.sweep(binders: [shelfRow(a), shelfRow(b)], commands: s.commands, now: pNow)
        #expect(open(a).isEmpty)
        let drop = try #require(open(b).first)
        #expect(drop.ops.map { $0["op"]?.stringValue } == ["drop", "add_item"])
    }

    func corrections(_ folder: URL, of event: String) -> [Proposal] {
        ProposalStore.list(in: folder).map(\.0).filter { CaptureInbox.isCorrection($0, of: event) && $0.state == "proposed" }
    }

    @Test func aRetryAfterAPartialFailureMakesNoSecondCard() async throws {
        let s = try pSetup()
        let (first, second, _, adapter) = try await splitNote(s, titles: ("Call the roofer", "Order the blinds"))
        let event = try pEvent(s, device: adapter, app: "adapter", ref: "S1", revision: "rev2",
                               text: "Call the roofer on Monday\nOrder the blinds on Friday")
        let rows = { [shelfRow(first), shelfRow(second)] }
        // The first binder's card is kept; the second binder's cannot be saved.
        chmod(ProposalStore.dir(second).path, 0o500)
        _ = s.inbox.sweep(binders: rows(), commands: s.commands, now: pNow)
        chmod(ProposalStore.dir(second).path, 0o700)
        #expect(try s.inbox.readState().ingested[event] == "ingested")
        #expect(corrections(first, of: event).count == 1)
        #expect(corrections(second, of: event).isEmpty)

        _ = s.inbox.sweep(binders: rows(), commands: s.commands, now: pNow)
        #expect(try s.inbox.readState().ingested[event] == "proposed")
        #expect(corrections(first, of: event).count == 1)
        #expect(corrections(second, of: event).count == 1)
    }
}

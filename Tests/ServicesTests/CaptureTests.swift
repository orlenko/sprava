import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct CaptureTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    let device = "0f0e0d0c-0b0a-4908-8706-050403020100"

    struct Setup {
        let commands: Commands
        let inbox: CaptureInbox
        let producer: CaptureProducer
        let folder: URL
    }

    func setup(adopt: Bool = true) throws -> Setup {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-capture-\(UUID().uuidString)")
        let support = base.appendingPathComponent("support")
        let root = base.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        if adopt {
            try adoptAsCommand(folder, commands: commands, now: now, today: today)
            // Leave only the capture's cards for the tests to look at.
            for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        }
        let inbox = CaptureInbox(root: root, support: support)
        try inbox.registerProducer(folder: device, app: "sprava")
        return Setup(commands: commands, inbox: inbox, producer: CaptureProducer(root: root, deviceID: device, support: support), folder: folder)
    }

    /// Writes a note the way the app does: the event, then the notice to the runtime.
    @discardableResult
    func note(_ s: Setup, _ text: String, hint: String? = nil, notice: Bool = true) throws -> JSONObject {
        let (event, digest) = try s.producer.writeNote(text, binderHint: hint, startedAt: now, savedAt: now, locale: "en-CA")
        if notice { try s.inbox.recordNotice(event: event["id"]!.stringValue!, digest: digest) }
        return event
    }

    func rows(_ s: Setup) -> [ShelfRow] {
        [ShelfRow(folder: s.folder, source: .picked, archived: false, teka: Teka.read(s.folder))]
    }

    func open(_ s: Setup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }

    func write(_ o: JSONObject, to url: URL) throws { try Data(JSONWriter.pretty(.object(o)).utf8).write(to: url) }

    @Test func aHintNamingAnAdoptedBinderFilesTheCardThereAndItCanBeApproved() throws {
        let s = try setup()
        try note(s, "Send the signed form", hint: Teka.read(s.folder).name)
        let r = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        #expect(r.filed == 1 && r.unfiled == 0)
        let card = try #require(open(s).first)
        let listed = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("proposals")),
                                                                                     ("binder", .string(s.folder.path))])), now: now, today: today)).value
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        #expect(shown["verified"] == .bool(true))
        let approved = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("approve")), ("binder", .string(s.folder.path)), ("proposal", .string(card.id)), ("digest", shown["digest"]!)])),
            now: now, today: today)).value
        #expect(approved["ok"] == .bool(true), "\(approved)")
        let added = Teka.read(s.folder).items.last
        #expect(added?.raw["title"] == .str("Send the signed form"))
        #expect(added?.raw["no_deadline"] == .bool(true))
        #expect(added?.raw["provenance"]?["proposed_by"]?["kind"] == .str("clerk"))
    }

    @Test func aHintIntoABinderAtDisclosureNoneStaysUnfiled() throws {
        let s = try setup()
        let ok = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("set_disclosure")),
            ("args", .obj([("disclosure", .str("none"))]))])), now: now, today: today)).value
        #expect(ok["ok"] == .bool(true), "\(ok)")
        try note(s, "Sign the deed", hint: Teka.read(s.folder).name)
        #expect(s.inbox.sweep(binders: rows(s), commands: s.commands, now: now).unfiled == 1)
    }

    @Test func anUnfiledCardCanBeFiledThroughCommandsButNotWhenTampered() throws {
        let s = try setup()
        try note(s, "Collect the keys")
        try note(s, "Return the keys")
        _ = s.inbox.sweep(binders: rows(s), commands: s.commands, now: now)
        let listed = try JSONParser.parse(s.commands.handle(#"{"command":"unfiled"}"#, now: now, today: today)).value
        let cards = try #require(listed["cards"]?.arrayValue)
        #expect(cards.count == 2)
        let first = try #require(cards[0]["id"])
        // The second card's file is rewritten by another program: it is no longer listed or fileable.
        let tamperedID = try #require(cards[1]["id"]?.stringValue)
        let tampered = s.inbox.unfiledDir.appendingPathComponent("\(tamperedID).json")
        try (String(contentsOf: tampered, encoding: .utf8).replacingOccurrences(of: "Return", with: "Burn")).write(to: tampered, atomically: true, encoding: .utf8)
        #expect(s.inbox.unfiled().count == 1)
        let refused = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("file_card")), ("card", .string(tamperedID)),
                                                                                      ("binder", .string(s.folder.path))])), now: now, today: today)).value
        #expect(refused["ok"] == .bool(false))

        let filed = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("file_card")), ("card", first),
                                                                                    ("binder", .string(s.folder.path))])), now: now, today: today)).value
        #expect(filed["ok"] == .bool(true), "\(filed)")
        let proposal = try #require(open(s).first)
        #expect(proposal.raw["binder"] == nil)
        let applied = try TekaStore(folder: s.folder).approve(proposal, now: now)
        #expect(applied.count == 1)
        let discarded = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("discard_card")), ("card", .string(tamperedID))])),
                                                               now: now, today: today)).value
        #expect(discarded["ok"] == .bool(true))
        #expect(s.inbox.unfiled().isEmpty)
    }
}

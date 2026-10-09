import BinderFormat
import BinderStore
import Capture
import CaptureTestSupport
import Darwin
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

@Suite(.serialized) struct IntakeTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    struct Setup {
        let commands: Commands
        let folder: URL
        let watcher: IntakeWatcher
    }

    func setup() throws -> Setup {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-intake-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "dev")
        let folder = try makeTeka(fixture: "sprava-v0")
        try adoptAsCommand(folder, commands: commands, now: now, today: today)
        for (p, _) in ProposalStore.list(in: folder) { try TekaStore(folder: folder).reject(p, now: now) }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("intake"), withIntermediateDirectories: true)
        return Setup(commands: commands, folder: folder, watcher: IntakeWatcher(support: support))
    }

    func rows(_ s: Setup) -> [ShelfRow] { [ShelfRow(folder: s.folder, source: .picked, archived: false, teka: Teka.read(s.folder))] }

    func open(_ s: Setup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }

    func drop(_ s: Setup, _ name: String, _ text: String = "invented letter body") throws {
        try Data(text.utf8).write(to: s.folder.appendingPathComponent("intake/\(name)"))
    }

    func call(_ s: Setup, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func approve(_ s: Setup, _ card: Proposal, folder: String? = nil) throws -> JSONValue {
        let listed = try call(s, [("command", .str("proposals")), ("binder", .string(s.folder.path))])
        let shown = try #require(listed["proposals"]?.arrayValue?.first { $0["id"] == .string(card.id) })
        var fields: [(String, JSONValue)] = [("command", .str("approve")), ("binder", .string(s.folder.path)),
                                             ("proposal", .string(card.id)), ("digest", shown["digest"]!)]
        if let folder { fields.append(("document_folder", .string(folder))) }
        return try call(s, fields)
    }

    @Test func aFileThatHoldsStillBecomesACardAndIsFiledOnApproval() throws {
        let s = try setup()
        try drop(s, "Notice from the registry.pdf")
        var r = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        #expect(r.carded == 0 && r.waiting == 1)
        r = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        #expect(r.carded == 1)
        let card = try #require(open(s).first)
        let op = try #require(card.ops.first)
        #expect(op["op"] == .str("file_document"))
        #expect(op["args"]?["from"] == .str("intake/Notice from the registry.pdf"))
        // The fixture keeps its documents under correspondence/notary/, so that is the suggestion.
        #expect(op["args"]?["document"]?["path"] == .str("correspondence/notary/Notice from the registry.pdf"))
        #expect(card.raw["provenance"]?["intake"]?["bytes"] == .int(20))
        // A third scan makes no second card.
        #expect(s.watcher.scan(binders: rows(s), commands: s.commands, now: now).carded == 0)

        let approved = try approve(s, card)
        #expect(approved["ok"] == .bool(true), "\(approved)")
        #expect(!FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/Notice from the registry.pdf").path))
        let moved = s.folder.appendingPathComponent("correspondence/notary/Notice from the registry.pdf")
        #expect(try String(contentsOf: moved, encoding: .utf8) == "invented letter body")
        let doc = try #require(Teka.read(s.folder).catalog?["documents"]?.arrayValue?.last)
        #expect(doc["id"]?.stringValue?.contains("-doc-2026-") == true)
        #expect(doc["sha256"] == op["args"]?["document"]?["sha256"])
        #expect(Teka.read(s.folder).catalog?["processing_log"]?.arrayValue?.last?["action"] == .str("filed"))
        _ = try Replay.run(try TekaStore(folder: s.folder).readOpLog().ops)
        // The file is gone from intake/, so the watcher forgets it.
        #expect(s.watcher.scan(binders: rows(s), commands: s.commands, now: now) == .init())
    }

    @Test func theDigestIsCheckedAgainOnApproval() throws {
        let s = try setup()
        try drop(s, "statement.pdf")
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        let card = try #require(open(s).first)
        let documentsBefore = Teka.read(s.folder).catalog?["documents"]?.arrayValue?.count
        try drop(s, "statement.pdf", "changed after the card")
        let refused = try approve(s, card)
        #expect(refused["ok"] == .bool(false))
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/statement.pdf").path))
        #expect(Teka.read(s.folder).catalog?["documents"]?.arrayValue?.count == documentsBefore)
        // The watcher withdraws the stale card and makes a new one once the file holds still.
        var r = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        #expect(r.replaced == 1)
        r = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        #expect(r.carded == 1)
        #expect(open(s).count == 1)
    }

    @Test func thePersonPicksTheFolderAndNamesNeverCollide() throws {
        let s = try setup()
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("letters"), withIntermediateDirectories: true)
        try Data("older".utf8).write(to: s.folder.appendingPathComponent("letters/reply.txt"))
        try drop(s, "reply.txt")
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now)
        let card = try #require(open(s).first)
        // An existing file at the destination is refused; the folder is the person's choice.
        #expect(try approve(s, card, folder: "letters")["ok"] == .bool(false))
        #expect(try approve(s, card, folder: "intake")["ok"] == .bool(false))
        #expect(try approve(s, card, folder: "letters/2026")["ok"] == .bool(true))
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("letters/2026/reply.txt").path))
        #expect(try String(contentsOf: s.folder.appendingPathComponent("letters/reply.txt"), encoding: .utf8) == "older")
        #expect(IntakeWatcher.freePath("letters", "reply.txt", in: s.folder) == "letters/reply (2).txt")
    }
}

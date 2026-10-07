import Darwin
import Foundation
import Testing
@testable import SpravaCore

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
        let r = try JSONParser.parse(commands.handle(JSONWriter.compact(.obj([("command", .str("adopt")), ("binder", .string(folder.path))])),
                                                     now: now, today: today)).value
        #expect(r["ok"] == .bool(true), "\(r)")
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

    @Test func pathRules() {
        #expect(DocumentPaths.isSafe("documents/letter.pdf"))
        #expect(DocumentPaths.isSafe("correspondence/2026/note.txt"))
        #expect(!DocumentPaths.isSafe("catalog.json"))
        #expect(!DocumentPaths.isSafe("Catalog.JSON"))
        #expect(!DocumentPaths.isSafe("Intake/x.pdf"))
        #expect(!DocumentPaths.isSafe("chapters/x.pdf"))
        #expect(DocumentPaths.isSafe("chapters/x.pdf", forFiling: false))
        #expect(!DocumentPaths.isSafe("documents/AGENTS.md"))
        #expect(!DocumentPaths.isSafe(".sprava/x"))
        #expect(!DocumentPaths.isSafe("documents//x"))
        #expect(!DocumentPaths.isSafe("/abs/x"))
        #expect(!DocumentPaths.isSafe("documents/invoice\u{202E}fdp.command"))
        #expect(!DocumentPaths.isSafe("documents/cafe\u{0301}.pdf"))   // not NFC
        #expect(DocumentPaths.isIntake("intake/a.pdf"))
        #expect(!DocumentPaths.isIntake("intake/mail/.env"))
        #expect(!DocumentPaths.isIntake("documents/a.pdf"))
        #expect(DocumentPaths.safeName(".hidden\u{202E}name.pdf") == "hidden_name.pdf")
        #expect(DocumentPaths.safeName("CLAUDE.md") == "_CLAUDE.md")
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

    @Test func dotFilesMailLinksAndFoldersAreSkipped() throws {
        let s = try setup()
        try drop(s, ".DS_Store")
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake/mail"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake/_converted"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("intake/scans"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: s.folder.appendingPathComponent("intake/elsewhere.pdf"),
                                                   withDestinationURL: s.folder.appendingPathComponent("catalog.json"))
        #expect(IntakeWatcher.candidates(in: s.folder).isEmpty)
    }

    @Test func aMoveCutShortIsRolledForwardOrAborted() throws {
        let s = try setup()
        let store = TekaStore(folder: s.folder)
        try drop(s, "deed.pdf")
        let sha = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("intake/deed.pdf")))
        let catalogBefore = try Data(contentsOf: s.folder.appendingPathComponent("catalog.json"))
        let snapshotBefore = try Data(contentsOf: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        func file() -> TekaStore.OpBody {
            .init(op: "file_document", args: JSONObject([
                (key: "document", value: .obj([("id", .str("estate-example-doc-2026-901")), ("title", .str("Deed")),
                                               ("path", .str("documents/deed.pdf")), ("sha256", .string(sha))])),
                (key: "from", value: .str("intake/deed.pdf"))]), actor: JSONObject([(key: "kind", value: .str("user"))]))
        }
        try store.apply([file()], now: now)
        // The crash: the op is logged, but the move and the rename never happened.
        try FileManager.default.moveItem(at: s.folder.appendingPathComponent("documents/deed.pdf"), to: s.folder.appendingPathComponent("intake/deed.pdf"))
        try catalogBefore.write(to: s.folder.appendingPathComponent("catalog.json"))
        try snapshotBefore.write(to: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                    (key: "set", value: .obj([("priority", .str("low"))]))]),
                               actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("documents/deed.pdf").path))
        #expect(Teka.read(s.folder).catalog?["documents"]?.arrayValue?.contains { $0["path"] == .str("documents/deed.pdf") } == true)
        _ = try Replay.run(try store.readOpLog().ops)

        // Again, but the file is gone from both places: the write is aborted, never half applied.
        try drop(s, "will.pdf")
        let sha2 = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("intake/will.pdf")))
        let catalog2 = try Data(contentsOf: s.folder.appendingPathComponent("catalog.json"))
        let snapshot2 = try Data(contentsOf: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        try store.apply([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", .str("estate-example-doc-2026-902")), ("title", .str("Will")),
                                           ("path", .str("documents/will.pdf")), ("sha256", .string(sha2))])),
            (key: "from", value: .str("intake/will.pdf"))]), actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        try FileManager.default.removeItem(at: s.folder.appendingPathComponent("documents/will.pdf"))
        try catalog2.write(to: s.folder.appendingPathComponent("catalog.json"))
        try snapshot2.write(to: s.folder.appendingPathComponent(".sprava/snapshot.json"))
        try store.apply([.init(op: "update_item", args: JSONObject([(key: "id", value: .str("estate-example-2026-007")),
                                                                    (key: "set", value: .obj([("priority", .str("high"))]))]),
                               actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
        let ops = try store.readOpLog().ops
        #expect(ops.contains { $0["op"] == .str("abort") })
        #expect(Teka.read(s.folder).catalog?["documents"]?.arrayValue?.contains { $0["path"] == .str("documents/will.pdf") } == false)
        _ = try Replay.run(ops)
    }

    @Test func theGuardRefusesUnsafeFilings() throws {
        let s = try setup()
        try drop(s, "x.pdf")
        let sha = try #require(DocumentPaths.sha256(of: s.folder.appendingPathComponent("intake/x.pdf")))
        for (path, from) in [("CLAUDE.md", "intake/x.pdf"), ("documents/x.pdf", "documents/other.pdf"), ("scripts/x.pdf", "intake/x.pdf")] {
            #expect(throws: (any Error).self) {
                try TekaStore(folder: s.folder).apply([.init(op: "file_document", args: JSONObject([
                    (key: "document", value: .obj([("id", .str("d-1")), ("title", .str("X")), ("path", .string(path)), ("sha256", .string(sha))])),
                    (key: "from", value: .string(from))]), actor: JSONObject([(key: "kind", value: .str("user"))]))], now: now)
            }
        }
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/x.pdf").path))
    }
}

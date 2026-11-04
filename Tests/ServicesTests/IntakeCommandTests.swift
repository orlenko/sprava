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

/// Intake files through the command table: a file that holds still becomes a card, is checked again on approval
/// and is filed under a name that never collides. Invented data only.
@Suite(.serialized) struct IntakeCommandTests {
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
        // A taken name gets a number and the older file is left alone; a folder that cannot hold documents is refused.
        #expect(try approve(s, card, folder: "intake")["ok"] == .bool(false))
        #expect(try approve(s, card, folder: "letters")["ok"] == .bool(true))
        #expect(try String(contentsOf: s.folder.appendingPathComponent("letters/reply (2).txt"), encoding: .utf8) == "invented letter body")
        #expect(try String(contentsOf: s.folder.appendingPathComponent("letters/reply.txt"), encoding: .utf8) == "older")
        #expect(IntakeWatcher.freePath("letters", "reply.txt", in: s.folder) == "letters/reply (3).txt")
    }

    /// One message from a mail monitor: its text, and its original in its attachments folder under the shared name.
    func dropMail(_ s: Setup, _ base: String, subject: String, date: String = "Sat, 14 Mar 2026 09:00:00 +0000") throws {
        let mail = s.folder.appendingPathComponent("intake/mail")
        let attachments = mail.appendingPathComponent(base + " attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("---\nsubject: \"\(subject)\"\nfrom: \"a@example.invalid\"\ndate: \"\(date)\"\n---\n\nInvented body of \(base).\n".utf8)
            .write(to: mail.appendingPathComponent(base + ".md"))
        try Data("Subject: \(subject)\n\nInvented original of \(base).\n".utf8)
            .write(to: attachments.appendingPathComponent(IntakeWatcher.mailOriginalName))
    }

    func card(_ s: Setup) throws {
        for _ in 0..<2 {
            let prepared = s.watcher.prepare(binders: rows(s), deviceID: "dev", reader: .inProcess)
            _ = s.watcher.scan(binders: rows(s), commands: s.commands, now: now, prepared: prepared)
        }
    }

    func exists(_ s: Setup, _ path: String) -> Bool { FileManager.default.fileExists(atPath: s.folder.appendingPathComponent(path).path) }

    /// Cards written before any of them was filed all named the same original; each must still file.
    @Test func everyWaitingMessageFilesThoughTheirOriginalsShareAName() throws {
        let s = try setup()
        try dropMail(s, "2026-03-14_1_fence", subject: "The fence")
        try dropMail(s, "2026-03-15_2_gate", subject: "The gate")
        try dropMail(s, "2026-03-16_3_shed", subject: "The shed")
        try card(s)
        let cards = open(s)
        #expect(cards.count == 3)
        for card in cards { #expect(try approve(s, card, folder: "documents")["ok"] == .bool(true)) }
        #expect(open(s).isEmpty)
        for name in ["2026-03-14_1_fence", "2026-03-15_2_gate", "2026-03-16_3_shed"] {
            #expect(exists(s, "documents/\(name).md"))
            #expect(exists(s, "documents/\(name).eml"))
        }
        #expect(!exists(s, "documents/000-original-message.eml"))
    }

    /// A name that was free when the card was written and is taken now gets a number; the older file stays.
    @Test func aCardNamingATakenFileGetsAFreeNameOnApproval() throws {
        let s = try setup()
        try dropMail(s, "2026-03-14_1_fence", subject: "The fence")
        let documents = s.folder.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let taken = documents.appendingPathComponent("2026-03-14_1_fence.eml")
        try Data("an earlier file".utf8).write(to: taken)
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        #expect(exists(s, "documents/2026-03-14_1_fence.md"))
        #expect(exists(s, "documents/2026-03-14_1_fence (2).eml"))
        #expect(try String(contentsOf: taken, encoding: .utf8) == "an earlier file")
    }

    func copies(_ s: Setup) throws -> [String] {
        try call(s, [("command", .str("proposals")), ("binder", .string(s.folder.path))])["intake_copies"]?.arrayValue?.compactMap(\.stringValue) ?? []
    }

    /// Once a document is filed, an exact copy arriving later asks nothing of the person and stays where it is.
    @Test func anExactCopyOfAFiledDocumentGetsNoCard() throws {
        let s = try setup()
        try drop(s, "quote.txt")
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        try drop(s, "quote again.txt")
        try card(s)
        #expect(open(s).isEmpty)
        #expect(try copies(s) == ["intake/quote again.txt"])
        #expect(exists(s, "intake/quote again.txt"))
        // The same name with other bytes is a different document: it gets its card and a free name.
        try drop(s, "quote.txt", "a different invented quote")
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        #expect(exists(s, "documents/quote (2).txt"))
    }

    /// A card already waiting goes once its document is filed through another card; it is not left to be refused.
    @Test func aWaitingCardGoesOnceItsDocumentIsFiled() throws {
        let s = try setup()
        try drop(s, "first.txt")
        try drop(s, "second.txt")
        try card(s)
        let cards = open(s)
        #expect(cards.count == 2)
        let chosen = try #require(cards.first)
        #expect(try approve(s, chosen, folder: "documents")["ok"] == .bool(true))
        try card(s)
        #expect(open(s).isEmpty)
        #expect(try copies(s).count == 1)
        // Its record says why, in the card's own reason.
        let other = ProposalStore.list(in: s.folder).map(\.0).first { $0.id == cards[1].id }
        #expect(other?.state == "rejected")
    }

    /// For a message, its original holds everything else, so a different text beside it changes nothing.
    @Test func aMessageWhoseOriginalIsFiledIsACopy() throws {
        let s = try setup()
        try dropMail(s, "2026-03-14_1_fence", subject: "The fence")
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        let mail = s.folder.appendingPathComponent("intake/mail")
        let attachments = mail.appendingPathComponent("again attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("---\nsubject: \"The fence\"\n---\n\nRendered another way.\n".utf8).write(to: mail.appendingPathComponent("again.md"))
        try Data("Subject: The fence\n\nInvented original of 2026-03-14_1_fence.\n".utf8)
            .write(to: attachments.appendingPathComponent(IntakeWatcher.mailOriginalName))
        try card(s)
        #expect(open(s).isEmpty)
        #expect(try copies(s) == ["intake/mail/again.md"])
    }

    /// A record alone must not hide the only copy left: with the filed file gone, the one in intake gets its card.
    @Test func aCopyGetsItsCardOnceTheFiledFileIsGone() throws {
        let s = try setup()
        try drop(s, "quote.txt")
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        try drop(s, "quote again.txt")
        try card(s)
        #expect(open(s).isEmpty)
        try FileManager.default.removeItem(at: s.folder.appendingPathComponent("documents/quote.txt"))
        try card(s)
        #expect(open(s).count == 1)
        #expect(try copies(s).isEmpty)
    }

    /// What counts is what the filed file holds now: after an edit, a copy of the old bytes is the only one left.
    @Test func aCopyOfWhatAFiledDocumentUsedToHoldGetsACard() throws {
        let s = try setup()
        try drop(s, "quote.txt")
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        try Data("invented letter, edited".utf8).write(to: s.folder.appendingPathComponent("documents/quote.txt"))
        try drop(s, "quote again.txt")
        try card(s)
        #expect(open(s).count == 1)
        #expect(try copies(s).isEmpty)
    }

    /// A file added beside a filed original is not in it as far as anyone can tell, and empty files all match.
    @Test func onlyWhatIsReallyFiledMakesACopy() throws {
        let s = try setup()
        try dropMail(s, "2026-03-14_1_fence", subject: "The fence")
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        let mail = s.folder.appendingPathComponent("intake/mail")
        let attachments = mail.appendingPathComponent("again attachments")
        try FileManager.default.createDirectory(at: attachments, withIntermediateDirectories: true)
        try Data("---\nsubject: \"The fence\"\n---\n\nRendered another way.\n".utf8).write(to: mail.appendingPathComponent("again.md"))
        try Data("Subject: The fence\n\nInvented original of 2026-03-14_1_fence.\n".utf8)
            .write(to: attachments.appendingPathComponent(IntakeWatcher.mailOriginalName))
        try Data("an invented drawing added later".utf8).write(to: attachments.appendingPathComponent("drawing.txt"))
        try card(s)
        #expect(open(s).count == 1)
        #expect(try copies(s).isEmpty)
    }

    @Test func emptyFilesAreNeverCopiesOfEachOther() throws {
        let s = try setup()
        try drop(s, "blank.txt", "")
        try card(s)
        #expect(try approve(s, try #require(open(s).first), folder: "documents")["ok"] == .bool(true))
        try drop(s, "another blank.txt", "")
        try card(s)
        #expect(open(s).count == 1)
    }

    /// A record with no digest, as an adopted binder's may be, is compared by the file itself.
    @Test func aFiledDocumentWithNoRecordedDigestIsStillRecognised() throws {
        let s = try setup()
        let catalogURL = s.folder.appendingPathComponent("catalog.json")
        var catalog = try #require(JSONParser.parse(Data(contentsOf: catalogURL)).value.objectValue)
        let documents = s.folder.appendingPathComponent("documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("invented older letter".utf8).write(to: documents.appendingPathComponent("older.txt"))
        var list = catalog["documents"]?.arrayValue ?? []
        list.append(.obj([("id", .str("doc-older")), ("title", .str("Older letter")), ("path", .str("documents/older.txt"))]))
        catalog.set("documents", .array(list))
        try Data(JSONWriter.compact(.object(catalog)).utf8).write(to: catalogURL)
        try drop(s, "older copy.txt", "invented older letter")
        try card(s)
        #expect(open(s).isEmpty)
        #expect(try copies(s) == ["intake/older copy.txt"])
    }

    /// A machine-named message files by its date and subject, whatever its subject holds.
    @Test func aMachineNamedMessageFilesByDateAndSubject() throws {
        let s = try setup()
        func args(title: String?, date: String?, from: String, path: String) -> JSONObject {
            var document = JSONObject()
            if let title { document.set("title", .string(title)) }
            if let date { document.set("date", .string(date)) }
            document.set("path", .string(path))
            return JSONObject([(key: "op", value: .str("file_document")),
                               (key: "args", value: .obj([("document", .object(document)), ("from", .string(from))]))])
        }
        func settled(_ ops: [JSONObject]) -> [String] {
            IntakeWatcher.settlingNames(ops, in: s.folder).compactMap { $0["args"]?["document"]?["path"]?.stringValue }
        }
        let machine = "intake/mail/imap-1234-7-3.md"
        let original = "intake/mail/imap-1234-7-3 attachments/000-original-message.eml"
        #expect(settled([args(title: "Quote: the fence", date: "2026-03-14", from: machine, path: "documents/imap-1234-7-3.md"),
                         args(title: "000-original-message", date: nil, from: original, path: "documents/000-original-message.eml")])
            == ["documents/2026-03-14 Quote - the fence.md", "documents/2026-03-14 Quote - the fence.eml"])
        // No subject: the title was only the machine's name.
        #expect(settled([args(title: "imap-1234-7-3", date: nil, from: machine, path: "documents/imap-1234-7-3.md")]) == ["documents/email.md"])
        // Two files of one card never settle on one name.
        #expect(settled([args(title: "x", date: nil, from: "intake/a/reply.txt", path: "documents/reply.txt"),
                         args(title: "x", date: nil, from: "intake/b/reply.txt", path: "documents/reply.txt")])
            == ["documents/reply.txt", "documents/reply (2).txt"])
        // A subject that would make a credential's name, or one no file system can hold, never reaches the disk as such.
        #expect(settled([args(title: "credentials renewal", date: nil, from: machine, path: "documents/imap-1234-7-3.md")]) == ["documents/imap-1234-7-3.md"])
        let long = settled([args(title: String(repeating: "é", count: 120), date: nil, from: machine, path: "documents/imap-1234-7-3.md")])[0]
        #expect((long as NSString).lastPathComponent.utf8.count <= 255)
        #expect(DocumentPaths.isSafe(long))
        // A path escape in a subject stays one file name.
        let escape = settled([args(title: "../../outside", date: "2026-03-14", from: machine, path: "documents/imap-1234-7-3.md")])[0]
        #expect(escape.hasPrefix("documents/") && escape.split(separator: "/").count == 2)
    }
}

import BinderFormat
import BinderStore
@testable import Capture
import CaptureTestSupport
@testable import Clerk
import ClerkTestSupport
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// The clerk's card files a document where the person's instructions say, under the name they give it
/// (decisions.md D43; docs/binder-instructions.md §4.1). Invented binders and text only.
@Suite(.serialized) struct IntakeInstructionsTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)   // 2026-10-07
    typealias Setup = IntakeReadingTests.Setup
    var base: IntakeReadingTests { IntakeReadingTests() }

    func open(_ s: Setup) -> [Proposal] { ProposalStore.list(in: s.folder).map(\.0).filter { $0.state == "proposed" } }

    func paths(_ card: Proposal) -> [String] {
        card.ops.compactMap { $0["op"] == .str("file_document") ? $0["args"]?["document"]?["path"]?.stringValue : nil }
    }

    /// Cards `path` (with `attachments`) and commits the clerk's reading, with `choose` setting what the instructions chose.
    func commit(_ s: Setup, _ path: String, attachments: [String: String] = [:], text: String,
                choose: (inout DocumentReading) -> Void) async throws -> Proposal {
        try base.write(s, path, text)
        for (name, body) in attachments { try base.write(s, name, body) }
        _ = base.card(s)
        let model = ScriptedModel(extractions: [.obj([("items", .array([]))])])
        model.document = .obj([("class", .str("action")), ("title", .str("Northwind Power bill")), ("date_text", .str("")),
                               ("summary", .str("An invented power bill.")), ("reply_needed", .bool(false))])
        let entry = try #require(s.watcher.nextForReading())
        var doc = await Clerk(model: model).readDocument(entry.reading, name: entry.name, binder: nil, now: now)
        choose(&doc)
        #expect(s.watcher.commitReading(entry, doc, commands: s.commands, now: now).replaced)
        return try #require(open(s).first)
    }

    @Test func theCardFilesWhereTheInstructionsSay() async throws {
        let s = try base.setup()
        // A file already in the chosen folder: the card's name is free, never the taken one.
        try FileManager.default.createDirectory(at: s.folder.appendingPathComponent("bills/Northwind Power"), withIntermediateDirectories: true)
        try Data("an earlier bill".utf8).write(to: s.folder.appendingPathComponent("bills/Northwind Power/Northwind Power 2026-10.txt"))
        let card = try await commit(s, "scan-0042.txt", text: "Northwind Power. Your October bill is $84.20.") {
            $0.folder = "bills/Northwind Power"
            $0.fileName = "Northwind Power 2026-10.txt"
        }
        #expect(paths(card) == ["bills/Northwind Power/Northwind Power 2026-10 (2).txt"])
        #expect(card.cardNotes.contains("Folder from your instructions"))
        #expect(card.cardNotes.contains("File name from your instructions"))
        #expect(card.raw["provenance"]?["reading"]?["folder_from"] == .str("instructions"))
        // Approved, the file is filed there and intake is left empty of it.
        _ = try TekaStore(folder: s.folder).approve(card, now: now)
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("bills/Northwind Power/Northwind Power 2026-10 (2).txt").path))
        #expect(!FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("intake/scan-0042.txt").path))
    }

    @Test func withoutAChoiceTheCardIsCodesAsBefore() async throws {
        let s = try base.setup()
        let card = try await commit(s, "scan-0042.txt", text: "Northwind Power. Your October bill is $84.20.") { _ in }
        #expect(paths(card).allSatisfy { !$0.hasPrefix("bills/") })
        #expect(!card.cardNotes.contains("Folder from your instructions"))
    }

    @Test func aMessagesAttachmentsGoWithItAndItsNameIsKept() async throws {
        let s = try base.setup()
        let card = try await commit(s, "mail/imap-1-2-3.md", attachments: ["mail/imap-1-2-3 attachments/bill.txt": "Invented bill."],
                                    text: IntakeReadingTests.message) {
            $0.folder = "bills"
            $0.fileName = "Northwind Power 2026-10.md"
        }
        #expect(paths(card) == ["bills/Northwind Power 2026-10.md", "bills/bill.txt"])
        // Settled again on approval, the name the instructions gave is not replaced by the message's date and subject.
        #expect(IntakeWatcher.settlingNames(card.ops, in: s.folder).map { $0["args"]?["document"]?["path"]?.stringValue } ==
                ["bills/Northwind Power 2026-10.md", "bills/bill.txt"])
    }

    @Test func anUnsafeChoiceLeavesTheOpAsCodeBuiltIt() {
        let op = JSONObject([(key: "op", value: .str("file_document")),
                             (key: "args", value: .obj([("document", .obj([("path", .str("documents/scan.txt"))])), ("from", .str("intake/scan.txt"))]))])
        let binder = URL(fileURLWithPath: "/invented/binder", isDirectory: true)
        var doc = DocumentReading(id: "r", model: "scripted")
        for folder in ["intake/held", "../outside", ".hidden"] {
            doc.folder = folder
            #expect(IntakeWatcher.following(doc, [op], in: binder).first?["args"]?["document"]?["path"] == .str("documents/scan.txt"))
        }
        doc.folder = nil
        doc.fileName = "credentials.txt"
        #expect(IntakeWatcher.following(doc, [op], in: binder).first?["args"]?["document"]?["path"] == .str("documents/scan.txt"))
    }

    @Test func notesAboutTheInstructionsReachTheCard() async throws {
        let s = try base.setup()
        let card = try await commit(s, "scan-0042.txt", text: "Northwind Power. Your October bill is $84.20.") {
            $0.instructionsNote = "Your instructions changed outside Sprava and were not used."
        }
        #expect(card.cardNotes.contains("Your instructions changed outside Sprava and were not used."))
    }
}

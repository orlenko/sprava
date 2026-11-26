import BinderFormat
import BinderStore
import Brains
import CaptureTestSupport
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// The document tools of a person's conversation turn (decisions.md D45), against a real adopted binder, its files and the
/// real op log. Invented text only.
@Suite struct ClaudeDocumentToolsTests {
    typealias Turn = ClaudeTodoToolsTests.Turn
    static let doc = JSONValue.str("estate-example-doc-2026-010")
    let user = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .str("sprava/0.1"))])

    /// A binder with one filed document, `documents/letter.pdf`, filed before the turn starts.
    func filed() throws -> PSetup {
        let s = try pSetup()
        let intake = s.folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("an invented letter".utf8).write(to: intake.appendingPathComponent("letter.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("letter.pdf")))
        _ = try TekaStore(folder: s.folder).apply([.init(op: "file_document", args: JSONObject([
            (key: "document", value: .obj([("id", Self.doc), ("title", .str("Invented letter")), ("path", .str("documents/letter.pdf")),
                                          ("sha256", .string(sha)), ("date", .str("2026-03-01")), ("kind", .str("letter"))])),
            (key: "from", value: .str("intake/letter.pdf"))]), actor: user)])
        return s
    }

    func record(_ s: PSetup) -> JSONObject? {
        Teka.read(s.folder).catalog?["documents"]?.arrayValue?.first { $0["id"] == Self.doc }?.objectValue
    }
    func exists(_ s: PSetup, _ path: String) -> Bool { FileManager.default.fileExists(atPath: s.folder.appendingPathComponent(path).path) }
    func undo(_ turn: Turn) throws -> [String] {
        try ClaudeDocumentTools.undo(turn: turn.record.turnID, folder: turn.s.folder, history: turn.history, writer: turn.writer)
    }
    func personRetitles(_ s: PSetup, _ title: String) throws {
        _ = try TekaStore(folder: s.folder).apply([.init(op: "update_document", args: JSONObject([(key: "id", value: Self.doc),
            (key: "set", value: .obj([("title", .string(title))]))]), actor: user)])
    }

    @Test func aCorrectionAppliesAtOnceNamesItsTurnAndIsUndoneWithIt() throws {
        let s = try filed(), turn = try Turn(s)
        let before = try #require(record(s))
        let answer = turn.call("edit_document", [("document", .str("documents/letter.pdf")), ("title", .str("Invented notice")), ("date", .str("2026-04-02")), ("kind", .null)])
        #expect(!answer.refused, "\(answer.content)")
        #expect(record(s)?["title"] == .str("Invented notice") && record(s)?["date"] == .str("2026-04-02") && record(s)?["kind"] == nil)
        // The records binder-v0 §6.5 asks of a turn's op: who chose it, who asked, and the revision it was based on.
        let op = try #require(turn.ops.last)
        #expect(op["op"] == .str("update_document") && op["actor"]?["kind"] == .str("brain") && op["approved_by"] == .str("user"))
        #expect(op["conversation"]?["turn"] == .str(turn.record.turnID.uuidString.lowercased()))
        #expect(op["expect"]?["record"] == .string(try Canonical.hash(.object(before))))
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID)?.summary == "Corrected 1 document: Invented notice")

        #expect(try undo(turn).isEmpty)
        #expect(record(s) == before)
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID)?.undone == true)
        #expect(try undo(turn).isEmpty)   // A second Undo finds nothing left to do.
    }

    @Test func aMoveTakesTheFileWithItsRecordAndUndoBringsBothBack() throws {
        let s = try filed(), turn = try Turn(s)
        try turn.history.record(s.folder)   // The baseline a turn with file tools starts from.
        let answer = turn.call("move_document", [("document", Self.doc), ("path", .str("letters/2026/invented-letter.pdf"))])
        #expect(!answer.refused, "\(answer.content)")
        #expect(record(s)?["path"] == .str("letters/2026/invented-letter.pdf"))
        #expect(exists(s, "letters/2026/invented-letter.pdf") && !exists(s, "documents/letter.pdf"))
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID)?.summary == "Moved 1 document: Invented letter")
        // The move is the op's to undo, so the turn's file entry holds nothing.
        #expect(try turn.history.record(s.folder, turn: turn.record.turnID) == nil)

        #expect(try undo(turn).isEmpty)
        #expect(record(s)?["path"] == .str("documents/letter.pdf"))
        #expect(exists(s, "documents/letter.pdf") && !exists(s, "letters/2026/invented-letter.pdf"))
    }

    // Done when (plan Track D, for the tools so far): one turn writes a file, corrects a record and refiles the document;
    // its Undo puts all of it back.
    @Test func aTurnsUndoReversesItsDocumentChangesAndThenItsFiles() throws {
        let s = try filed(), turn = try Turn(s)
        try turn.history.record(s.folder)
        try Data("Invented summary".utf8).write(to: s.folder.appendingPathComponent("summary.md"))
        #expect(!turn.call("edit_document", [("document", Self.doc), ("title", .str("Invented notice"))]).refused)
        #expect(!turn.call("move_document", [("document", .str("documents/letter.pdf")), ("path", .str("notices/notice.pdf"))]).refused)
        let entry = try #require(try turn.history.record(s.folder, turn: turn.record.turnID))
        #expect(entry.summary == "Added 1 file: summary.md")

        #expect(try undo(turn).isEmpty)
        #expect(try turn.history.undo(turn: turn.record.turnID, in: s.folder) == .undone)
        #expect(!exists(s, "summary.md") && exists(s, "documents/letter.pdf") && !exists(s, "notices/notice.pdf"))
        #expect(record(s)?["title"] == .str("Invented letter") && record(s)?["path"] == .str("documents/letter.pdf"))
    }

    @Test func whatCouldDoHarmIsRefusedAndChangesNothing() throws {
        let s = try filed(), turn = try Turn(s)
        try Data("another invented file".utf8).write(to: s.folder.appendingPathComponent("documents/taken.pdf"))
        let before = try #require(record(s)), count = turn.ops.count
        let moves = ["../outside.pdf", "/tmp/outside.pdf", "documents/../../outside.pdf",   // outside the binder
                     "intake/letter.pdf", "scripts/letter.py", ".sprava/letter.pdf", "chapters/a/letter.pdf", "CLAUDE.md", "catalog.json",   // reserved
                     "keys/id_ed25519", "documents/.env", "documents/server.pem",   // a key file's name
                     "documents/taken.pdf", "documents/Letter.pdf", "documents/letter.pdf",   // taken, letter case only, the same
                     "documents/let\u{202E}fdp.exe"]   // a bidirectional override
        for path in moves {
            let answer = turn.call("move_document", [("document", Self.doc), ("path", .str(path))])
            #expect(answer.refused && answer.content["error"] == .str("invalid"), "\(path): \(answer.content)")
        }
        let edits: [[(String, JSONValue)]] = [
            [("document", Self.doc)],
            [("document", Self.doc), ("title", .str("two\nlines"))], [("document", Self.doc), ("title", .str(""))],
            [("document", Self.doc), ("date", .str("next week"))], [("document", Self.doc), ("kind", .str(String(repeating: "k", count: 65)))],
            [("document", Self.doc), ("title", .int(4))], [("title", .str("No document named"))],
        ]
        for fields in edits {
            let answer = turn.call("edit_document", fields)
            #expect(answer.refused && answer.content["error"] == .str("invalid"), "\(fields): \(answer.content)")
        }
        for name in ["edit_document", "move_document"] {
            let answer = turn.call(name, [("document", .str("documents/absent.pdf")), ("title", .str("Invented")), ("path", .str("letters/absent.pdf"))])
            #expect(answer.refused && answer.content["error"] == .str("not_found"), "\(answer.content)")
        }
        #expect(record(s) == before && turn.ops.count == count)
        #expect(exists(s, "documents/letter.pdf"))
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID) == nil)
    }

    @Test func aRecordChangedSinceTheTurnReadItIsNotOverwritten() throws {
        let s = try filed(), turn = try Turn(s)
        try personRetitles(s, "The person's own title")
        let count = turn.ops.count
        for (name, fields) in [("edit_document", [("title", JSONValue.str("Invented notice"))]), ("move_document", [("path", JSONValue.str("letters/letter.pdf"))])] {
            let answer = turn.call(name, [("document", Self.doc)] + fields)
            #expect(answer.refused && answer.content["error"] == .str("changed_since"), "\(answer.content)")
        }
        #expect(record(s)?["title"] == .str("The person's own title") && turn.ops.count == count && exists(s, "documents/letter.pdf"))
        // The turn's own change is the record as it left it, so it can change the same document again.
        let later = try Turn(s)
        #expect(!later.call("edit_document", [("document", Self.doc), ("kind", .str("notice"))]).refused)
        #expect(!later.call("move_document", [("document", Self.doc), ("path", .str("letters/letter.pdf"))]).refused)
        #expect(!later.call("edit_document", [("document", .str("letters/letter.pdf")), ("title", .str("Invented notice"))]).refused)
    }

    @Test func undoLeavesWhatChangedSinceAndNamesIt() throws {
        let s = try filed(), turn = try Turn(s)
        #expect(!turn.call("edit_document", [("document", Self.doc), ("title", .str("Invented notice"))]).refused)
        try personRetitles(s, "The person's own title")
        #expect(try undo(turn) == ["Invented notice"])
        #expect(record(s)?["title"] == .str("The person's own title"))
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID)?.undone == false)

        // A moved file that is gone cannot go back: the move stays, named, and the Undo goes on instead of failing.
        let other = try filed(), second = try Turn(other)
        #expect(!second.call("move_document", [("document", Self.doc), ("path", .str("letters/letter.pdf"))]).refused)
        try FileManager.default.removeItem(at: other.folder.appendingPathComponent("letters/letter.pdf"))
        #expect(try undo(second) == ["Invented letter"])
        #expect(record(other)?["path"] == .str("letters/letter.pdf"))
    }

    @Test func aSessionThatSharesNoDocumentsHasNoDocumentTools() throws {
        let s = try filed(), turn = try Turn(s)
        let narrow = try #require(ClaudeTodoTools(folder: s.folder, record: turn.record, history: turn.history, writer: turn.writer, search: nil))
        #expect(narrow.appTools.tools.map(\.name).filter(ClaudeDocumentTools.names.contains).isEmpty)
        #expect(Set(turn.tools.appTools.tools.map(\.name)).isSuperset(of: ClaudeDocumentTools.names))
        let answer = narrow.appTools.call("edit_document", .init([(key: "document", value: Self.doc), (key: "title", value: .str("Invented notice"))]))
        #expect(answer.refused && record(s)?["title"] == .str("Invented letter"))
    }

    @Test func documentChangesCountAgainstTheTurnsLimit() throws {
        let s = try filed(), turn = try Turn(s)
        for index in 0..<ClaudeTodoTools.maximumChanges - 1 { #expect(!turn.call("add_todo", [("title", .str("Invented \(index)"))]).refused) }
        #expect(!turn.call("edit_document", [("document", Self.doc), ("title", .str("Invented notice"))]).refused)
        let answer = turn.call("move_document", [("document", Self.doc), ("path", .str("letters/letter.pdf"))])
        #expect(answer.refused && answer.content["error"] == .str("too_many"))
        #expect(exists(s, "documents/letter.pdf"))
    }
}

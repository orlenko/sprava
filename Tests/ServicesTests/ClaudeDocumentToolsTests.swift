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

    func filedAt(_ s: PSetup, _ path: String) -> JSONObject? {
        Teka.read(s.folder).catalog?["documents"]?.arrayValue?.first { $0["path"] == .string(path) }?.objectValue
    }
    func write(_ s: PSetup, _ path: String, _ text: String) throws {
        let url = s.folder.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // Done when (plan Track D): "file the summary you wrote" changes the catalog in one turn, and Undo puts it back.
    @Test func aSummaryTheTurnWroteIsFiledAndUndoPutsItAllBack() throws {
        let s = try filed(), turn = try Turn(s)
        try turn.history.record(s.folder)   // The baseline a turn with file tools starts from.
        let before = Teka.read(s.folder).catalog?["documents"]
        try write(s, "summaries/summary.md", "An invented summary")
        let answer = turn.call("file_document", [("path", .str("summaries/summary.md")), ("title", .str("Invented summary")), ("date", .str("2026-04-02")), ("kind", .str("summary"))])
        #expect(!answer.refused, "\(answer.content)")
        let record = try #require(filedAt(s, "summaries/summary.md"))
        #expect(record["title"] == .str("Invented summary") && record["date"] == .str("2026-04-02") && record["kind"] == .str("summary"))
        #expect(record["sensitivity"] == .str("private"))
        #expect(record["sha256"] == DocumentPaths.sha256(of: s.folder.appendingPathComponent("summaries/summary.md")).map(JSONValue.string))
        #expect(record["id"]?.stringValue?.hasPrefix("$new") == false && answer.content["id"] == record["id"])
        let op = try #require(turn.ops.last)
        #expect(op["op"] == .str("file_document") && op["args"]?["from"] == nil)
        #expect(op["actor"]?["kind"] == .str("brain") && op["approved_by"] == .str("user"))
        #expect(op["conversation"]?["turn"] == .str(turn.record.turnID.uuidString.lowercased()))
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID)?.summary == "Filed 1 document: Invented summary")
        // The record is the turn's own, so the turn can correct it afterwards.
        #expect(!turn.call("edit_document", [("document", .str("summaries/summary.md")), ("kind", .str("brief"))]).refused)

        let entry = try #require(try turn.history.record(s.folder, turn: turn.record.turnID))
        #expect(entry.summary == "Added 1 file: summaries/summary.md")
        #expect(try undo(turn).isEmpty)
        #expect(filedAt(s, "summaries/summary.md") == nil && exists(s, "summaries/summary.md"))   // The record first; the file is the file Undo's.
        #expect(try turn.history.undo(turn: turn.record.turnID, in: s.folder) == .undone)
        #expect(!exists(s, "summaries/summary.md"))
        #expect(Teka.read(s.folder).catalog?["documents"] == before)
    }

    // A file the turn made, filed and then moved: the move's Undo takes it back to where it was made, and the file Undo finds it there.
    @Test func aFileTheTurnMadeFiledAndMovedIsUndoneWhole() throws {
        let s = try filed(), turn = try Turn(s)
        try turn.history.record(s.folder)
        let before = Teka.read(s.folder).catalog?["documents"]
        try write(s, "summary.md", "An invented summary")
        #expect(!turn.call("file_document", [("path", .str("summary.md")), ("title", .str("Invented summary"))]).refused)
        #expect(!turn.call("move_document", [("document", .str("summary.md")), ("path", .str("summaries/2026/summary.md"))]).refused)
        let entry = try #require(try turn.history.record(s.folder, turn: turn.record.turnID))
        #expect(entry.summary == "Added 1 file: summary.md")
        #expect(try undo(turn).isEmpty)
        #expect(exists(s, "summary.md") && !exists(s, "summaries/2026/summary.md"))
        #expect(try turn.history.undo(turn: turn.record.turnID, in: s.folder) == .undone)
        #expect(!exists(s, "summary.md") && Teka.read(s.folder).catalog?["documents"] == before)
    }

    @Test func aFileThatWasThereBeforeIsFiledWhereItIsAndUndoLeavesIt() throws {
        let s = try filed()
        try write(s, "notes/meeting.md", "Invented meeting notes")
        let turn = try Turn(s)
        #expect(!turn.call("file_document", [("path", .str("notes/meeting.md")), ("title", .str("Invented meeting notes"))]).refused)
        #expect(filedAt(s, "notes/meeting.md") != nil)
        #expect(try undo(turn).isEmpty)
        #expect(filedAt(s, "notes/meeting.md") == nil && exists(s, "notes/meeting.md"))
    }

    @Test func whatCannotBeFiledIsRefusedAndChangesNothing() throws {
        let s = try filed(), turn = try Turn(s)
        try write(s, "intake/arrived.pdf", "an invented arrival")
        try write(s, "scripts/tool.py", "print('invented')")
        try write(s, "keys/id_ed25519", "invented")
        try write(s, "notes/meeting.md", "Invented meeting notes")
        let before = Teka.read(s.folder).catalog?["documents"], count = turn.ops.count
        let title = ("title", JSONValue.str("Invented"))
        let bad: [[(String, JSONValue)]] = [
            [("path", .str("intake/arrived.pdf")), title],   // what arrives is filed by a drop
            [("path", .str("scripts/tool.py")), title], [("path", .str("catalog.json")), title], [("path", .str("AGENTS.md")), title],   // reserved
            [("path", .str("keys/id_ed25519")), title],   // a key file's name
            [("path", .str("../outside.md")), title], [("path", .str("/tmp/outside.md")), title],   // outside the binder
            [("path", .str("documents/letter.pdf")), title], [("path", .str("Documents/Letter.pdf")), title],   // already filed
            [("path", .str("notes/absent.md")), title], [("path", .str("notes")), title],   // no file there
            [("path", .str("notes/meeting.md"))], [("path", .str("notes/meeting.md")), ("title", .str("two\nlines"))],
            [("path", .str("notes/meeting.md")), title, ("date", .str("spring"))], [title],
        ]
        for fields in bad {
            let answer = turn.call("file_document", fields)
            #expect(answer.refused && answer.content["error"] == .str("invalid"), "\(fields): \(answer.content)")
        }
        #expect(Teka.read(s.folder).catalog?["documents"] == before && turn.ops.count == count)
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID) == nil)
    }

    // A tool call runs inside the turn's loop, which takes no Stop while one is busy, so a file of any size is never
    // read to its end there. A sparse file takes no room and no time to make; filing or moving one is refused at once.
    @Test func aFileTooLargeForATurnIsRefusedWithoutBeingRead() throws {
        let s = try filed(), turn = try Turn(s)
        func sparse(_ path: String, bytes: UInt64) throws {
            let url = s.folder.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: bytes)
            try handle.close()
        }
        try sparse("recordings/long.bin", bytes: 1 << 40)
        try sparse("recordings/just-over.bin", bytes: UInt64(ClaudeDocumentTools.maximumFileBytes) + 1)
        let before = Teka.read(s.folder).catalog?["documents"], count = turn.ops.count
        let clock = ContinuousClock()
        let took = clock.measure {
            for path in ["recordings/long.bin", "recordings/just-over.bin"] {
                let answer = turn.call("file_document", [("path", .str(path)), ("title", .str("Invented recording"))])
                #expect(answer.refused && answer.content["error"] == .str("invalid"), "\(answer.content)")
                #expect("\(answer.content)".contains("larger than 1 GB"))
            }
        }
        #expect(took < .seconds(5))
        #expect(Teka.read(s.folder).catalog?["documents"] == before && turn.ops.count == count)
        // A filed document whose file has since grown past the limit is not moved either.
        try sparse("documents/letter.pdf", bytes: 1 << 40)
        let moved = clock.measure {
            let answer = turn.call("move_document", [("document", Self.doc), ("path", .str("letters/letter.pdf"))])
            #expect(answer.refused && "\(answer.content)".contains("larger than 1 GB"))
        }
        #expect(moved < .seconds(5) && exists(s, "documents/letter.pdf") && !exists(s, "letters/letter.pdf"))
        // The digest itself gives up at its limit, whatever the caller checked first.
        #expect(DocumentPaths.sha256(of: s.folder.appendingPathComponent("recordings/just-over.bin"), limit: ClaudeDocumentTools.maximumFileBytes) == nil)
        try write(s, "notes/small.md", "Invented notes")
        #expect(DocumentPaths.sha256(of: s.folder.appendingPathComponent("notes/small.md"), limit: 14) == DocumentPaths.sha256(of: s.folder.appendingPathComponent("notes/small.md")))
        #expect(DocumentPaths.sha256(of: s.folder.appendingPathComponent("notes/small.md"), limit: 13) == nil)
    }

    @Test func aFiledFileChangedAfterwardsKeepsItsRecordWhenTheTurnIsUndone() throws {
        let s = try filed(), turn = try Turn(s)
        try write(s, "summaries/summary.md", "An invented summary")
        #expect(!turn.call("file_document", [("path", .str("summaries/summary.md")), ("title", .str("Invented summary"))]).refused)
        try write(s, "summaries/summary.md", "An invented summary, with more")
        #expect(try undo(turn) == ["Invented summary"])
        #expect(filedAt(s, "summaries/summary.md") != nil && exists(s, "summaries/summary.md"))
    }

    func log(_ s: PSetup) -> [JSONObject] { Teka.read(s.folder).catalog?["processing_log"]?.arrayValue?.compactMap(\.objectValue) ?? [] }

    // The author, 2026-11-26: "Log entry stays, logs are for traceability."
    @Test func aLogEntryIsAddedAtOnceAndStaysWhenTheTurnIsUndone() throws {
        let s = try filed(), turn = try Turn(s)
        let count = log(s).count
        let answer = turn.call("add_log_entry", [("entry", .str("Phoned the invented office; they confirmed the letter arrived")), ("document", .str("documents/letter.pdf"))])
        #expect(!answer.refused, "\(answer.content)")
        let entry = try #require(log(s).last)
        #expect(log(s).count == count + 1)
        #expect(entry["action"] == .str("Phoned the invented office; they confirmed the letter arrived") && entry["document"] == Self.doc)
        let op = try #require(turn.ops.last)
        #expect(op["op"] == .str("add_log_entry") && op["actor"]?["kind"] == .str("brain") && op["approved_by"] == .str("user"))
        #expect(op["conversation"]?["turn"] == .str(turn.record.turnID.uuidString.lowercased()))
        #expect(entry["op_id"] == op["id"] && entry["id"] == nil)
        // The turn's line says the entry stays, and a turn that did nothing else offers no Undo.
        let noted = try #require(try turn.history.documentChanges(forTurn: turn.record.turnID))
        #expect(noted.summary == "Logged 1 entry, which Undo keeps: Phoned the invented office; they confirmed the letter arrived")
        #expect(!noted.undoable)

        // With a correction in the same turn, Undo takes the correction back and keeps the entry.
        #expect(!turn.call("edit_document", [("document", Self.doc), ("title", .str("Invented notice"))]).refused)
        #expect(try turn.history.documentChanges(forTurn: turn.record.turnID)?.undoable == true)
        #expect(try undo(turn).isEmpty)
        #expect(record(s)?["title"] == .str("Invented letter"))
        #expect(log(s).contains { $0["op_id"] == op["id"] })
    }

    @Test func aLogEntryIsOneLineAboutAKnownDocumentAndATurnAddsFew() throws {
        let s = try filed(), turn = try Turn(s)
        let count = log(s).count, ops = turn.ops.count
        let bad: [[(String, JSONValue)]] = [
            [], [("entry", .str(""))], [("entry", .str("two\nlines"))], [("entry", .str(String(repeating: "e", count: 513)))], [("entry", .int(3))],
            [("entry", .obj([("action", .str("done")), ("id", .str("board-1"))]))],   // never a closure: the entry is text only
            [("entry", .str("Invented note")), ("document", .bool(true))],
        ]
        for fields in bad {
            let answer = turn.call("add_log_entry", fields)
            #expect(answer.refused && answer.content["error"] == .str("invalid"), "\(fields): \(answer.content)")
        }
        let absent = turn.call("add_log_entry", [("entry", .str("Invented note")), ("document", .str("documents/absent.pdf"))])
        #expect(absent.refused && absent.content["error"] == .str("not_found"))
        #expect(log(s).count == count && turn.ops.count == ops)

        for index in 0..<ClaudeDocumentTools.maximumLogEntries { #expect(!turn.call("add_log_entry", [("entry", .str("Invented note \(index)"))]).refused) }
        let over = turn.call("add_log_entry", [("entry", .str("One too many"))])
        #expect(over.refused && !log(s).contains { $0["action"] == .str("One too many") })
        #expect(log(s).count == count + ClaudeDocumentTools.maximumLogEntries)
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

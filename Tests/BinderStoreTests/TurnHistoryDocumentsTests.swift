@testable import BinderStore
import CryptoKit
import Foundation
import Testing

/// A turn's own document changes (decisions.md D45) beside its file entry: they are named for the turn's line, they do
/// not stop the turn's file Undo, and a file moved with its record goes back with the op. Invented fixtures only.
@Suite struct TurnHistoryDocumentsTests {
    typealias Fixture = TurnHistoryTests.Fixture

    /// A catalog with one record, carrying the digest of the letter as it was filed.
    func catalog(_ path: String, title: String = "Invented letter") -> String {
        let sha = SHA256.hash(data: Data("Invented letter".utf8)).map { String(format: "%02x", $0) }.joined()
        return "{\"documents\":[{\"id\":\"d-1\",\"title\":\"\(title)\",\"path\":\"\(path)\",\"sha256\":\"\(sha)\"}]}"
    }

    /// What a document tool does around its op: reads the stamp, changes the catalog (and the file, for a move), and
    /// notes the change.
    func tool(_ f: Fixture, turn: UUID, _ change: TurnHistory.DocumentChange, catalog text: String) throws {
        let before = f.history.documentsStamp(f.folder)
        if let from = change.from, let to = change.to {
            let target = f.folder.appendingPathComponent(to)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: f.folder.appendingPathComponent(from), to: target)
        }
        try f.write(text, "catalog.json")
        try f.history.noteDocumentChange(change, turn: turn, in: f.folder, stampBefore: before)
    }

    func move(_ f: Fixture, _ from: String, _ to: String) throws {
        let target = f.folder.appendingPathComponent(to)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: f.folder.appendingPathComponent(from), to: target)
    }

    @Test func aCorrectionTheTurnMadeItselfDoesNotStopItsFileUndo() throws {
        let f = try Fixture()
        try f.write(catalog("documents/letter.txt"), "catalog.json"); try f.write("Invented letter", "documents/letter.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.write("Invented notes", "notes.md")
        try tool(f, turn: turn, .init(verb: .corrected, title: "Invented notice", opIDs: ["op-1"]), catalog: catalog("documents/letter.txt", title: "Invented notice"))
        let entry = try #require(try f.history.record(f.folder, turn: turn))
        #expect(entry.summary == "Added 1 file: notes.md")
        #expect(try f.history.documentChanges(forTurn: turn)?.summary == "Corrected 1 document: Invented notice")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(!f.exists("notes.md"))
    }

    // The stamp moves on only when nothing else changed the documents first: a filing by the intake while the turn ran
    // still refuses the file Undo, as it did.
    @Test func aFilingBySomethingElseDuringTheTurnStillRefusesItsFileUndo() throws {
        let f = try Fixture()
        try f.write(catalog("documents/letter.txt"), "catalog.json"); try f.write("Invented letter", "documents/letter.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.write("Invented notes", "notes.md")
        let both = catalog("documents/letter.txt").replacingOccurrences(of: "}]}", with: "},{\"id\":\"d-2\",\"title\":\"Arrived\",\"path\":\"documents/arrived.txt\"}]}")
        try f.write("Arrived", "documents/arrived.txt"); try f.write(both, "catalog.json")   // not the turn's tools
        try tool(f, turn: turn, .init(verb: .corrected, title: "Invented notice", opIDs: ["op-1"]),
                 catalog: both.replacingOccurrences(of: "Invented letter", with: "Invented notice"))
        try f.history.record(f.folder, turn: turn)
        #expect(try f.history.undo(turn: turn, in: f.folder) == .recordsChanged)
        #expect(f.exists("notes.md"))
    }

    @Test func aFileTheTurnMovedWithItsRecordIsNotAFileChange() throws {
        let f = try Fixture()
        try f.write(catalog("documents/letter.txt"), "catalog.json"); try f.write("Invented letter", "documents/letter.txt")
        try f.write("first", "notes.md")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.write("second", "notes.md")
        try tool(f, turn: turn, .init(verb: .moved, title: "Invented letter", opIDs: ["op-1"], from: "documents/letter.txt", to: "letters/2026/letter.txt"),
                 catalog: catalog("letters/2026/letter.txt"))
        let entry = try #require(try f.history.record(f.folder, turn: turn))
        #expect(entry.summary == "Changed 1 file: notes.md")
        #expect(try f.history.documentChanges(forTurn: turn)?.summary == "Moved 1 document: Invented letter")

        // The turn's Undo reverses the document op first: the file goes back with its record. Then the files.
        try move(f, "letters/2026/letter.txt", "documents/letter.txt"); try f.write(catalog("documents/letter.txt"), "catalog.json")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(f.read("notes.md") == "first" && f.read("documents/letter.txt") == "Invented letter")
    }

    // A turn that did nothing to files but move a document leaves no file entry at all.
    @Test func aTurnThatOnlyMovedADocumentHasNoFileEntry() throws {
        let f = try Fixture()
        try f.write(catalog("documents/letter.txt"), "catalog.json"); try f.write("Invented letter", "documents/letter.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try tool(f, turn: turn, .init(verb: .moved, title: "Invented letter", opIDs: ["op-1"], from: "documents/letter.txt", to: "letters/letter.txt"),
                 catalog: catalog("letters/letter.txt"))
        try tool(f, turn: turn, .init(verb: .moved, title: "Invented letter", opIDs: ["op-2"], from: "letters/letter.txt", to: "archive/letter.txt"),
                 catalog: catalog("archive/letter.txt"))
        #expect(try f.history.record(f.folder, turn: turn) == nil)
        #expect(try f.history.entry(forTurn: turn) == nil)
    }

    @Test func aFileEditedAndMovedInOneTurnComesBackAsItWasWhereItWas() throws {
        let f = try Fixture()
        try f.write(catalog("documents/letter.txt"), "catalog.json"); try f.write("Invented letter", "documents/letter.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try f.write("Invented letter, edited", "documents/letter.txt")
        try tool(f, turn: turn, .init(verb: .moved, title: "Invented letter", opIDs: ["op-1"], from: "documents/letter.txt", to: "letters/letter.txt"),
                 catalog: catalog("letters/letter.txt"))
        let entry = try #require(try f.history.record(f.folder, turn: turn))
        #expect(entry.summary == "Changed 1 file: documents/letter.txt")

        // While the move stands, the file is not where the entry expects it: a conflict, and nothing changes.
        #expect(try f.history.undo(turn: turn, in: f.folder) == .conflict(["documents/letter.txt"]))
        #expect(f.read("letters/letter.txt") == "Invented letter, edited" && !f.exists("documents/letter.txt"))

        try move(f, "letters/letter.txt", "documents/letter.txt"); try f.write(catalog("documents/letter.txt"), "catalog.json")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .undone)
        #expect(f.read("documents/letter.txt") == "Invented letter" && !f.exists("letters/letter.txt"))
    }

    // Not a plain move: the turn put another file where the document had been. The pair stays as recorded, so the file
    // Undo sees every path and refuses while the catalog still names the new place.
    @Test func aMoveWithSomethingNewAtTheOldPathIsLeftAsRecorded() throws {
        let f = try Fixture()
        try f.write(catalog("documents/letter.txt"), "catalog.json"); try f.write("Invented letter", "documents/letter.txt")
        try f.history.record(f.folder)
        let turn = UUID()
        try tool(f, turn: turn, .init(verb: .moved, title: "Invented letter", opIDs: ["op-1"], from: "documents/letter.txt", to: "letters/letter.txt"),
                 catalog: catalog("letters/letter.txt"))
        try f.write("Another invented file", "documents/letter.txt")
        let entry = try #require(try f.history.record(f.folder, turn: turn))
        #expect(entry.summary == "Added 1 file, changed 1 file: documents/letter.txt, letters/letter.txt")
        #expect(try f.history.undo(turn: turn, in: f.folder) == .recordsChanged)
        #expect(f.read("letters/letter.txt") == "Invented letter" && f.read("documents/letter.txt") == "Another invented file")
    }

    @Test func theChangesAreKeptForTheTurnsLineAndMarkedUndone() throws {
        let f = try Fixture()
        try f.write(catalog("documents/letter.txt"), "catalog.json")
        let turn = UUID()
        #expect(try f.history.documentChanges(forTurn: turn) == nil)
        for n in 1...4 {
            try f.history.noteDocumentChange(.init(verb: .corrected, title: "Invented \(n)", opIDs: ["op-\(n)"]), turn: turn, in: f.folder, stampBefore: nil)
        }
        try f.history.noteDocumentChange(.init(verb: .moved, title: "Invented 5", opIDs: ["op-5"], from: "a.txt", to: "b.txt"), turn: turn, in: f.folder, stampBefore: nil)
        let kept = try #require(try f.history.documentChanges(forTurn: turn))
        #expect(kept.summary == "Corrected 4 documents: Invented 1, Invented 2, Invented 3, …. Moved 1 document: Invented 5")
        #expect(kept.changes.map(\.opIDs) == [["op-1"], ["op-2"], ["op-3"], ["op-4"], ["op-5"]] && !kept.undone)
        try f.history.markDocumentsUndone(forTurn: turn)
        #expect(try f.history.documentChanges(forTurn: turn)?.undone == true)
        // A record that cannot be read is an error, never "this turn changed no documents".
        try Data("not json".utf8).write(to: f.history.root.appendingPathComponent("documents/turn-\(turn.uuidString).json"))
        #expect(throws: TurnHistory.Refused.damaged) { try f.history.documentChanges(forTurn: turn) }
    }
}

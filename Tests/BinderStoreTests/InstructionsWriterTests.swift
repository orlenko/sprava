import BinderFormat
@testable import BinderStore
import Foundation
import SpravaKit
import Testing

/// Saving the person's part of AGENTS.md (decisions.md D43; docs/binder-instructions.md §3). Every text is invented.
@Suite struct InstructionsWriterTests {
    func binder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-instructions-\(UUID().uuidString)/household-example")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent(".sprava"), withIntermediateDirectories: true)
        return folder
    }

    func agents(_ folder: URL) throws -> String { try String(contentsOf: folder.appendingPathComponent("AGENTS.md"), encoding: .utf8) }
    func read(_ folder: URL) throws -> BinderInstructions { try BinderInstructions.read(folder).get() }

    @Test func aSaveKeepsSpravasSectionAndIsAccepted() throws {
        let folder = try binder()
        let section = "<!-- sprava:begin -->\nPropose through Sprava.\n<!-- sprava:end -->\n"
        try Data(("Old rule.\n" + section).utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        let before = try read(folder)
        #expect(!before.isAccepted)
        try BinderInstructions.save("Bills go in bills.\n", expected: before.digest, in: folder)
        #expect(try agents(folder) == section + "Bills go in bills.\n")
        let after = try read(folder)
        #expect(after.text == "Bills go in bills.\n" && after.isAccepted && after.canUndo)
    }

    @Test func aSaveOverTextChangedSinceIsRefusedAndWritesNothing() throws {
        let folder = try binder()
        try Data("First.\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        let seen = try read(folder).digest
        try Data("Changed in a text editor.\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        #expect(throws: BinderInstructions.Refused.changed) { try BinderInstructions.save("Mine.\n", expected: seen, in: folder) }
        #expect(try agents(folder) == "Changed in a text editor.\n")
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(BinderInstructions.recordPath).path))
    }

    @Test func tooLongAmbiguousAndUnadoptedAreRefused() throws {
        let folder = try binder()
        let empty = BinderInstructions.digest("")
        #expect(throws: BinderInstructions.Refused.tooLong) {
            try BinderInstructions.save(String(repeating: "a", count: BinderInstructions.maxCharacters + 1), expected: empty, in: folder)
        }
        try Data("<!-- sprava:begin -->\nno end\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        #expect(throws: BinderInstructions.Refused.file(.ambiguousMarkers)) { try BinderInstructions.save("x", expected: empty, in: folder) }
        let bare = folder.deletingLastPathComponent().appendingPathComponent("not-adopted")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        #expect(throws: BinderInstructions.Refused.notAdopted) { try BinderInstructions.save("x", expected: empty, in: bare) }
        #expect(!FileManager.default.fileExists(atPath: bare.appendingPathComponent("AGENTS.md").path))
    }

    @Test func savingTheSameTextOnlyAcceptsIt() throws {
        let folder = try binder()
        // An empty text where there is no file makes none.
        try BinderInstructions.save("", expected: BinderInstructions.digest(""), in: folder)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("AGENTS.md").path))
        let old = "Written before Sprava.\n"
        try Data(old.utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        try BinderInstructions.save(old, expected: BinderInstructions.digest(old), in: folder)
        let read = try read(folder)
        #expect(read.isAccepted && !read.canUndo)
        #expect(try agents(folder) == old)
    }

    @Test func undoPutsBackALongTextTrimmedInTheSave() throws {
        let folder = try binder()
        let long = String(repeating: "An old manual line.\n", count: 2_000)   // 40,000 characters, over the save's bound
        try Data(long.utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        try BinderInstructions.save("The part worth keeping.\n", expected: BinderInstructions.digest(long), in: folder)
        try BinderInstructions.undoLastSave(in: folder)
        #expect(try agents(folder) == long)
        let back = try read(folder)
        // It was not accepted before the save, so it is not now; and there is one level of Undo.
        #expect(!back.isAccepted && !back.canUndo)
        #expect(throws: BinderInstructions.Refused.nothingToUndo) { try BinderInstructions.undoLastSave(in: folder) }
    }

    @Test func undoAfterAnEditElsewhereIsRefused() throws {
        let folder = try binder()
        try BinderInstructions.save("One.\n", expected: BinderInstructions.digest(""), in: folder)
        try BinderInstructions.save("Two.\n", expected: BinderInstructions.digest("One.\n"), in: folder)
        try Data("Three, by hand.\n".utf8).write(to: folder.appendingPathComponent("AGENTS.md"))
        #expect(throws: BinderInstructions.Refused.nothingToUndo) { try BinderInstructions.undoLastSave(in: folder) }
        #expect(try agents(folder) == "Three, by hand.\n")
    }

    @Test func undoKeepsAcceptanceAsItWas() throws {
        let folder = try binder()
        try BinderInstructions.save("One.\n", expected: BinderInstructions.digest(""), in: folder)
        try BinderInstructions.save("Two.\n", expected: BinderInstructions.digest("One.\n"), in: folder)
        try BinderInstructions.undoLastSave(in: folder)
        let back = try read(folder)
        #expect(back.text == "One.\n" && back.isAccepted)
    }

    @Test func aTurnsUndoLeavesTheManualsAlone() {
        #expect(TurnHistory.excluded("AGENTS.md") && TurnHistory.excluded("CLAUDE.md"))
        #expect(!TurnHistory.excluded("notes/AGENTS.md") && !TurnHistory.excluded("agents-notes.md"))
    }
}

import Foundation
import SpravaKit
@testable import SpravaApp
import Testing

/// What the conversation says when a turn's Undo did not undo everything (decisions.md D45): the turn's document changes
/// are reversed first, so the line never says "nothing was undone" after they were.
@Suite struct TurnUndoWordingTests {
    func reply(_ fields: [(String, JSONValue)]) -> JSONObject { .init(fields.map { (key: $0.0, value: $0.1) }) }

    @Test func aTurnWithNoDocumentChangesReadsAsBefore() {
        #expect(ClaudeBinderConversation.undoRefusal(reply([("undone", .bool(false)), ("conflicts", .array([.str("notes.md")]))]))
                == "Nothing was undone: notes.md changed after that turn.")
        #expect(ClaudeBinderConversation.undoRefusal(reply([("undone", .bool(false)), ("records_changed", .bool(true))]))
                == "Nothing was undone: something was filed or approved during that turn. Use Undo on the History tab for that, and change the files by hand.")
        #expect(ClaudeBinderConversation.undoRefusal(reply([("undone", .bool(false)), ("todos_left", .array([.str("Invented chore")])), ("notes_left", .bool(true)),
                                                            ("documents_left", .array([]))]))
                == "The notes changed after that turn, so they stay as they are. These to-dos changed after that turn, so they stay as they are: Invented chore. Everything else was undone.")
    }

    @Test func documentChangesUndoneBeforeAFileConflictAreSaidToBeUndone() {
        let line = ClaudeBinderConversation.undoRefusal(reply([("undone", .bool(false)), ("conflicts", .array([.str("notes.md")])),
                                                               ("documents_undone", .bool(true)), ("documents_left", .array([]))]))
        #expect(line == "That turn's document changes were undone. Its files were not undone: notes.md changed after that turn.")
    }

    @Test func aDocumentChangedSinceIsNamed() {
        let conflict = ClaudeBinderConversation.undoRefusal(reply([("undone", .bool(false)), ("conflicts", .array([.str("documents/letter.pdf")])),
                                                                   ("documents_undone", .bool(false)), ("documents_left", .array([.str("Invented letter")]))]))
        #expect(conflict == "These documents changed after that turn, so their records and files stay as they are: Invented letter. That turn's files were not undone: documents/letter.pdf changed after that turn.")
        let rest = ClaudeBinderConversation.undoRefusal(reply([("undone", .bool(false)), ("todos_left", .array([])), ("notes_left", .bool(false)),
                                                               ("documents_left", .array([.str("Invented letter")]))]))
        #expect(rest == "These documents changed after that turn, so their records and files stay as they are: Invented letter. Everything else was undone.")
    }
}

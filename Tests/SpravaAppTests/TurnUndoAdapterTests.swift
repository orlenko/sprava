import Foundation
import Services
import SpravaKit
import Testing
@testable import SpravaApp

/// The conversation's line for a turn's file changes, and its Undo, against a runtime stand-in. Invented fixtures only.
@MainActor
@Suite struct TurnUndoAdapterTests {
    let folder = URL(fileURLWithPath: "/invented/workshop")

    final class Server: @unchecked Sendable {
        let scope = UUID().uuidString, request = UUID(), turn = UUID()
        var undone = false
        var conflicts: [String] = []
        var undos: [JSONObject] = []
        func answer(_ text: String) throws -> String {
            let value = try JSONParser.parse(text).value
            var fields: [(String, JSONValue)] = [("ok", .bool(true))]
            switch value["command"]?.stringValue {
            case "claude_binder": fields += [("enabled", .bool(true)), ("binder_id", .str(scope))]
            case "chat_history":
                let reply = JSONWriter.compact(.obj([("answer", .str("Deleted the invented file.")), ("citations", .array([])), ("task", .null), ("draft", .null)]))
                fields.append(("turns", .array([.obj([("binder_id", .str(scope)), ("request_id", .str(request.uuidString)), ("turn_id", .str(turn.uuidString)),
                    ("text", .str("Delete the old notes.")), ("phase", .str("replied")), ("reply", .str(reply)),
                    ("changes", .obj([("summary", .str("Deleted 1 file: old.md")), ("undone", .bool(undone))]))])])))
            case "chat_undo":
                undos.append(value.objectValue ?? .init([]))
                fields.append(("undone", .bool(conflicts.isEmpty)))
                if !conflicts.isEmpty { fields.append(("conflicts", .array(conflicts.map { .str($0) }))) }
            default: throw ChatCommandFailure.invalidRequest
            }
            return JSONWriter.compact(.obj(fields))
        }
    }

    func model(_ server: Server) -> ClaudeBinderConversation {
        ClaudeBinderConversation(client: RuntimeClient(answer: { try server.answer($0) }), authenticate: {})
    }

    @Test func aSavedTurnShowsItsLineAndUndoGoesToTheRuntime() async throws {
        let server = Server(), model = model(server)
        await model.show(folder)
        let change = try #require(model.chat.entries.last?.changes.first)
        #expect(change.summary == "Deleted 1 file: old.md" && change.undo != nil)
        await model.chat.undo(change)
        #expect(server.undos.count == 1 && server.undos[0]["turn_id"] == .str(server.turn.uuidString))
        #expect(model.chat.isUndone(change) && model.chat.message == nil)
    }

    @Test func aConflictNamesTheFilesAndIsNotReportedAsUndone() async throws {
        let server = Server(), model = model(server)
        server.conflicts = ["notes.md"]
        await model.show(folder)
        let change = try #require(model.chat.entries.last?.changes.first)
        await model.chat.undo(change)
        #expect(!model.chat.isUndone(change))
        #expect(model.chat.message == "Nothing was undone: notes.md changed after that turn.")
    }

    @Test func aTurnAlreadyUndoneOffersNoSecondUndo() async throws {
        let server = Server(), model = model(server)
        server.undone = true
        await model.show(folder)
        let change = try #require(model.chat.entries.last?.changes.first)
        #expect(change.undo == nil && change.summary.hasSuffix("(undone)"))
    }
}

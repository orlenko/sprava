import BinderFormat
import BinderStore
import Brains
import CaptureTestSupport
import Foundation
@testable import Services
import SpravaKit
import SpravaTestSupport
import Testing

/// The to-do tools of a person's conversation turn, against a real adopted binder and the real op log. Invented text only.
@Suite struct ClaudeTodoToolsTests {
    struct Turn {
        let s: PSetup, history: TurnHistory, writer: ClaudeTodoWriter, record: ConversationTurnStore.Record, tools: ClaudeTodoTools
        init(_ s: PSetup) throws {
            self.s = s
            let store = try ConversationTurnStore(at: s.support.appendingPathComponent("turns-\(UUID()).sqlite"))
            let requestID = try #require(UUID(uuidString: UUIDv7.make()))
            record = try store.accept(conversationID: UUID(), requestID: requestID, text: "Invented request")
            history = TurnHistory(support: s.support, binder: UUID())
            writer = ClaudeTodoWriter(); writer.attach(commands: s.commands, queue: DispatchQueue(label: "invented-writer"))
            let made = ClaudeTodoTools(folder: s.folder, record: record, history: history, writer: writer, search: { _, _ in .init(sources: [], incomplete: 0) })
            tools = try #require(made)
        }
        func call(_ name: String, _ fields: [(String, JSONValue)]) -> ClaudeAppTools.Answer {
            tools.appTools.call(name, .init(fields.map { (key: $0.0, value: $0.1) }))
        }
        func undo() throws -> [String] { try ClaudeTodoTools.undo(turn: record.turnID, folder: s.folder, history: history, writer: writer) }
        var ops: [JSONObject] { (try? TekaStore(folder: s.folder).readOpLog().ops) ?? [] }
        func item(_ title: String) -> Item? { Teka.read(s.folder).items.first { $0.title == title } }
    }
    func added(_ turn: Turn, _ title: String) throws -> String {
        let answer = turn.call("add_todo", [("title", .str(title))])
        #expect(!answer.refused, "\(answer.content)")
        return try #require(answer.content["id"]?.stringValue)
    }

    private func keptDashboard(_ s: PSetup) throws -> DashboardKeeper {
        let keeper = DashboardKeeper(folder: s.folder)
        if !keeper.isSwitched { try keeper.switchOn(today: CalendarDate.today()) }
        return keeper
    }
    private func notes(_ s: PSetup) throws -> String? {
        Dashboard.split(try String(contentsOf: s.folder.appendingPathComponent("DASHBOARD.md"), encoding: .utf8)).1
    }

    @Test func notesChangeAloneAndATurnsUndoPutsThemBack() throws {
        let s = try pSetup(); _ = try keptDashboard(s)
        let turn = try Turn(s)
        let url = s.folder.appendingPathComponent("DASHBOARD.md")
        let before = try #require(try notes(s)), above = Dashboard.split(try String(contentsOf: url, encoding: .utf8)).0
        #expect(!turn.call("update_notes", [("text", .str("Waiting on the invented roofer."))]).refused)
        #expect(!turn.call("update_notes", [("text", .str("Waiting on the invented roofer.\n\n- Quote due Friday"))]).refused)
        #expect(try notes(s) == "## Notes\n\nWaiting on the invented roofer.\n\n- Quote due Friday\n")
        #expect(Dashboard.split(try String(contentsOf: url, encoding: .utf8)).0 == above)
        #expect(!Dashboard.editedOutsideNotes(try String(contentsOf: url, encoding: .utf8)))
        #expect(try ClaudeTodoTools.undoNotes(turn: turn.record.turnID, folder: s.folder, history: turn.history, writer: turn.writer))
        #expect(try notes(s) == before) // Through both of the turn's changes.
        #expect(try turn.history.notesChange(forTurn: turn.record.turnID)?.undone == true)
    }

    @Test func undoLeavesNotesThePersonChangedSince() throws {
        let s = try pSetup(); _ = try keptDashboard(s)
        let turn = try Turn(s)
        #expect(!turn.call("update_notes", [("text", .str("From the invented turn"))]).refused)
        let url = s.folder.appendingPathComponent("DASHBOARD.md")
        let (above, _) = Dashboard.split(try String(contentsOf: url, encoding: .utf8))
        try Data((above + "## Notes\n\nThe person's own invented line\n").utf8).write(to: url)
        #expect(try !ClaudeTodoTools.undoNotes(turn: turn.record.turnID, folder: s.folder, history: turn.history, writer: turn.writer))
        #expect(try notes(s)?.contains("The person's own invented line") == true)
    }

    @Test func notesRefuseWhatCouldDoHarmAndChangeNothing() throws {
        let s = try pSetup()
        let handKept = try Turn(s)
        if !DashboardKeeper(folder: s.folder).isSwitched { #expect(handKept.call("update_notes", [("text", .str("Invented"))]).refused) }
        _ = try keptDashboard(s)
        let turn = try Turn(s), before = try notes(s)
        #expect(turn.call("update_notes", [("text", .str(String(repeating: "x", count: ClaudeTodoTools.maximumNotesBytes + 1)))]).refused)
        #expect(turn.call("update_notes", [("text", .str("bell \u{07}"))]).refused)
        #expect(turn.call("update_notes", []).refused)
        #expect(try notes(s) == before)
        #expect(try turn.history.notesChange(forTurn: turn.record.turnID) == nil)
    }

    @Test func aRecordThatCannotBeKeptMeansNoNotesChange() throws {
        let s = try pSetup(); _ = try keptDashboard(s)
        let turn = try Turn(s), before = try notes(s)
        // A file where the history's folder would go.
        let keeper = DashboardKeeper(folder: s.folder)
        struct Blocked: Error {}
        #expect(throws: Blocked.self) { try keeper.replaceNotes(with: "Invented") { _, _ in throw Blocked() } }
        #expect(try notes(s) == before)
        _ = turn
    }

    @Test func searchReturnsPassagesWithinABound() throws {
        let s = try pSetup()
        let store = try ConversationTurnStore(at: s.support.appendingPathComponent("turns-\(UUID()).sqlite"))
        let record = try store.accept(conversationID: UUID(), requestID: try #require(UUID(uuidString: UUIDv7.make())), text: "Invented request")
        let writer = ClaudeTodoWriter(); writer.attach(commands: s.commands, queue: DispatchQueue(label: "invented-writer"))
        let long = String(repeating: "invented passage ", count: 400)
        let sources = (1...30).map { (i: Int) in ClaudeBinderContext.Source(id: "S\(i)", path: "documents/n\(i).pdf", page: i, revision: "r", text: long) }
        let made = ClaudeTodoTools(folder: s.folder, record: record, history: TurnHistory(support: s.support, binder: UUID()), writer: writer,
                                   search: { _, _ in .init(sources: sources, incomplete: 2) })
        let tools = try #require(made)
        let answer = tools.appTools.call("search_binder", .init([(key: "query", value: .str("invented"))]))
        #expect(!answer.refused)
        let results = try #require(answer.content["results"]?.arrayValue)
        #expect(!results.isEmpty)
        #expect(results.first?["path"]?.stringValue == "documents/n1.pdf", "\(String(describing: results.first?["path"]))")
        #expect(results.first?["page"]?.numberValue?.safeInteger == 1)
        #expect(answer.content["sources_not_fully_read"] == .int(2))
        #expect(JSONWriter.compact(answer.content).utf8.count <= ClaudeTodoTools.maximumSearchBytes + 256)
        #expect(tools.appTools.call("search_binder", .init([])).refused)
        for _ in 0..<ClaudeTodoTools.maximumSearches { _ = tools.appTools.call("search_binder", .init([(key: "query", value: .str("invented"))])) }
        #expect(tools.appTools.call("search_binder", .init([(key: "query", value: .str("invented"))])).refused)
    }

    /// A connection that shares no documents has the to-do tools and nothing that reaches the rest of the binder.
    @Test func withoutFileConsentThereIsNoSearchAndNoNotes() throws {
        let s = try pSetup(); _ = try keptDashboard(s)
        let store = try ConversationTurnStore(at: s.support.appendingPathComponent("turns-\(UUID()).sqlite"))
        let record = try store.accept(conversationID: UUID(), requestID: try #require(UUID(uuidString: UUIDv7.make())), text: "Invented request")
        let writer = ClaudeTodoWriter(); writer.attach(commands: s.commands, queue: DispatchQueue(label: "invented-writer"))
        let made = ClaudeTodoTools(folder: s.folder, record: record, history: TurnHistory(support: s.support, binder: UUID()), writer: writer)
        let tools = try #require(made), before = try notes(s)
        #expect(Set(tools.appTools.tools.map(\.name)) == ["list_todos", "add_todo", "edit_todo", "complete_todo", "remove_todo"])
        #expect(tools.appTools.call("search_binder", .init([(key: "query", value: .str("invented"))])).refused)
        #expect(tools.appTools.call("update_notes", .init([(key: "text", value: .str("Invented"))])).refused)
        #expect(try notes(s) == before)
    }

    @Test func listingCountsAsHavingSeenTheToDos() throws {
        let turn = try Turn(pSetup())
        let id = try added(turn, "Call the invented plumber")
        let listed = turn.call("list_todos", [])
        #expect(!listed.refused && listed.content["todos"]?.arrayValue?.contains { $0["title"] == .str("Call the invented plumber") } == true)
        #expect(!turn.call("complete_todo", [("id", .str(id))]).refused)
    }

    @Test func aTurnAddsEditsCompletesAndRemovesAtOnce() throws {
        let turn = try Turn(pSetup())
        let answer = turn.call("add_todo", [("title", .str("Call the invented plumber")), ("details", .str("About the leak")), ("due", .str("2026-11-12")), ("priority", .str("high"))])
        #expect(!answer.refused, "\(answer.content)")
        let item = try #require(turn.item("Call the invented plumber"))
        #expect(item.priority == .high && item.object?["due"] == .str("2026-11-12") && item.object?["details"] == .str("About the leak"))
        #expect(item.object?["sensitivity"] == .str("private"))
        let plumber = try #require(answer.content["id"]?.stringValue)
        let second = try added(turn, "Read the invented bylaw"), third = try added(turn, "Book the invented room")

        #expect(!turn.call("edit_todo", [("id", .str(plumber)), ("title", .str("Call the invented plumber today")), ("due", .null)]).refused)
        let edited = try #require(turn.item("Call the invented plumber today"))
        #expect(edited.object?["due"] == nil && edited.object?["no_deadline"] == .bool(true))
        #expect(!turn.call("complete_todo", [("id", .str(second))]).refused)
        #expect(!turn.call("remove_todo", [("id", .str(third))]).refused)
        #expect(turn.item("Read the invented bylaw") == nil && turn.item("Book the invented room") == nil)
        let closed = Teka.read(turn.s.folder).log.filter { $0.closedID != nil }.compactMap { $0.raw["action"]?.stringValue }
        #expect(closed.contains("done") && closed.contains("dropped"), "\(closed)")

        let summary = try #require(try turn.history.todoChanges(forTurn: turn.record.turnID)?.summary)
        #expect(summary == "Added 3 to-dos: Call the invented plumber, Read the invented bylaw, Book the invented room. Changed 1 to-do: Call the invented plumber today. Marked done 1 to-do: Read the invented bylaw. Removed 1 to-do: Book the invented room")
    }

    /// binder-v0 §6.5: who chose it, who asked, and the revision a change to an existing record was based on.
    @Test func eachOpRecordsItsTurn() throws {
        let turn = try Turn(pSetup())
        let id = try added(turn, "Invented task")
        #expect(!turn.call("complete_todo", [("id", .str(id))]).refused)
        let ops = turn.ops.suffix(2)
        for op in ops {
            #expect(op["actor"]?["kind"] == .str("brain") && op["actor"]?["model"] == .str("sonnet") && op["approved_by"] == .str("user"))
            #expect(op["conversation"]?["turn"] == .str(turn.record.turnID.uuidString.lowercased()))
            #expect(op["conversation"]?["message"] == .str(turn.record.requestID.uuidString.lowercased()))
            #expect(op["request"] == .str(turn.record.requestID.uuidString.lowercased()))
        }
        #expect(ops.first?["expect"] == nil && ops.last?["expect"]?["record"]?.stringValue != nil)
    }

    @Test func aToDoThePersonChangedDuringTheTurnIsLeftAlone() throws {
        let s = try pSetup()
        try bAddItem(s, id: "board-1", title: "Invented task the person keeps editing")
        let turn = try Turn(s)
        _ = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("edit_item")),
            ("args", .obj([("id", .str("board-1")), ("set", .obj([("title", .str("The person's newer words"))]))])),
        ]))))
        for tool in ["complete_todo", "remove_todo"] {
            let answer = turn.call(tool, [("id", .str("board-1"))])
            #expect(answer.refused && answer.content["error"] == .str("changed_since"))
        }
        #expect(turn.call("edit_todo", [("id", .str("board-1")), ("priority", .str("low"))]).content["error"] == .str("changed_since"))
        #expect(turn.item("The person's newer words")?.priority != .low)
    }

    @Test func whatATurnWasNotGivenIsRefusedAndChangesNothing() throws {
        let turn = try Turn(pSetup())
        let count = turn.ops.count
        for (name, fields, code): (String, [(String, JSONValue)], String) in [
            ("complete_todo", [("id", .str("no-such-item"))], "not_found"),
            ("remove_todo", [("id", .str("no-such-item"))], "not_found"),
            ("complete_todo", [], "invalid"),
            ("add_todo", [], "invalid"),
            ("add_todo", [("title", .str("   "))], "invalid"),
            ("add_todo", [("title", .str("Two\nlines"))], "invalid"),
            ("add_todo", [("title", .str(String(repeating: "x", count: 513)))], "invalid"),
            ("add_todo", [("title", .str("Invented")), ("due", .str("next friday"))], "invalid"),
            ("add_todo", [("title", .str("Invented")), ("priority", .str("urgent"))], "invalid"),
            ("add_todo", [("title", .str("Invented")), ("details", .str(String(repeating: "x", count: 8_193)))], "invalid"),
        ] {
            let answer = turn.call(name, fields)
            #expect(answer.refused && answer.content["error"] == .str(code), "\(name) \(answer.content)")
        }
        #expect(turn.ops.count == count)
        #expect(try turn.history.todoChanges(forTurn: turn.record.turnID) == nil)
    }

    @Test func oneTurnHasALimit() throws {
        let turn = try Turn(pSetup())
        for index in 0..<ClaudeTodoTools.maximumChanges { _ = try added(turn, "Invented \(index)") }
        let answer = turn.call("add_todo", [("title", .str("One too many"))])
        #expect(answer.refused && answer.content["error"] == .str("too_many"))
        #expect(turn.item("One too many") == nil)
    }

    @Test func undoReversesTheWholeTurn() throws {
        let s = try pSetup()
        try bAddItem(s, id: "board-1", title: "Invented to finish")
        try bAddItem(s, id: "board-2", title: "Invented to remove")
        try bAddItem(s, id: "board-3", title: "Invented to rename")
        let turn = try Turn(s)
        _ = try added(turn, "Invented new")
        #expect(!turn.call("complete_todo", [("id", .str("board-1"))]).refused)
        #expect(!turn.call("remove_todo", [("id", .str("board-2"))]).refused)
        #expect(!turn.call("edit_todo", [("id", .str("board-3")), ("title", .str("Renamed"))]).refused)

        #expect(try turn.undo() == [])
        #expect(turn.item("Invented new") == nil && turn.item("Renamed") == nil)
        #expect(turn.item("Invented to finish") != nil && turn.item("Invented to remove") != nil && turn.item("Invented to rename") != nil)
        #expect(try turn.history.todoChanges(forTurn: turn.record.turnID)?.undone == true)
        let count = turn.ops.count
        #expect(try turn.undo() == [])
        #expect(turn.ops.count == count)
    }

    @Test func undoLeavesAToDoChangedSinceAndNamesIt() throws {
        let s = try pSetup()
        let turn = try Turn(s)
        let kept = try added(turn, "Invented the person kept"); _ = try added(turn, "Invented to go")
        _ = s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("edit_item")),
            ("args", .obj([("id", .str(kept)), ("set", .obj([("details", .str("The person's note"))]))])),
        ])))
        #expect(try turn.undo() == ["Invented the person kept"])
        #expect(turn.item("Invented the person kept") != nil && turn.item("Invented to go") == nil)
        #expect(try turn.history.todoChanges(forTurn: turn.record.turnID)?.undone == false)
        // Asking again reverses nothing more and fails nothing it already did.
        #expect(try turn.undo() == ["Invented the person kept"])
    }

    // MARK: - Through the conversation

    struct Conversation {
        let s: PSetup, runtime: ClaudeConversationRuntime, engine: ClaudeConversationTests.Engine
        init(attach: Bool = true, files: Bool = true) async throws {
            let s = try pSetup(); self.s = s
            let engine = ClaudeConversationTests.Engine(); self.engine = engine
            runtime = try ClaudeConversationRuntime(support: s.support, secrets: .init(read: { engine.lock.withLock { engine.token } }, replace: { token in engine.lock.withLock { engine.token = token } }),
                makeDriver: { _, _, _, session, policy, reach, appTools, _ in
                    engine.lock.withLock { engine.reaches.append(reach); engine.appTools = appTools }
                    return engine.driver(policy: policy, session: session)
                }, context: { _, _, _, _, _ in .init(data: .obj([]), sources: []) })
            if attach { runtime.todoWriter.attach(commands: s.commands, queue: DispatchQueue(label: "invented-writer")) }
            _ = try await runtime.handle(.init([(key: "command", value: .str("claude_configure")), (key: "program", value: .str("/invented/claude")), (key: "credential", value: .str("invented-token"))]))
            _ = try await request("claude_enable", [("documents", .bool(files)), ("intake", .bool(files)), ("files", .bool(files))])
        }
        func request(_ command: String, _ fields: [(String, JSONValue)] = []) async throws -> JSONObject {
            try await runtime.handle(.init([(key: "command", value: .str(command)), (key: "binder", value: .str(s.folder.path))] + fields.map { (key: $0.0, value: $0.1) }))
        }
        func turn(_ text: String = "Invented request", act: @escaping @Sendable (ClaudeAppTools?) -> Void) async throws -> (turn: String, done: JSONObject) {
            let engine = self.engine
            engine.lock.withLock { engine.act = { act(engine.lock.withLock { engine.appTools }) } }
            let id = UUID()
            let accepted = try await request("chat_send", [("request_id", .str(id.uuidString)), ("text", .str(text))])
            for _ in 0..<400 {
                let r = try await request("chat_poll", [("request_id", .str(id.uuidString))])
                if !["accepted", "running"].contains(r["phase"]?.stringValue ?? "") { return (try #require(accepted["turn_id"]?.stringValue), r) }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ClaudeConversationRuntime.Refused.unavailable
        }
    }

    /// The app can say why a turn failed; the log gets the reason and none of the turn's words.
    @Test func aFailedTurnGivesItsReasonAndLogsNoWords() async throws {
        let c = try await Conversation()
        let engine = c.engine
        engine.lock.withLock { engine.failure = ClaudeReadOnlyTurn.Failure.deadline }
        let (_, done) = try await c.turn("Invented words for the log") { _ in }
        #expect(done["phase"] == .str("failed"))
        #expect(done["reason"] == .str("deadline"))
        let log = try String(contentsOf: c.s.support.appendingPathComponent("runtime/jobs.log"), encoding: .utf8)
        #expect(log.contains("claude turn outcome=failed reason=deadline"))
        #expect(!log.contains("Invented words"))
    }

    @Test func everyFailureHasACode() {
        typealias F = ClaudeReadOnlyTurn.Failure
        #expect(ClaudeConversationRuntime.failureCode(F.protocolMismatch) == "protocol")
        #expect(ClaudeConversationRuntime.failureCode(F.engineFailed) == "engine")
        #expect(ClaudeConversationRuntime.failureCode(ClaudeConversationRuntime.Refused.unavailable) == "binder_unavailable")
        #expect(ClaudeConversationRuntime.failureCode(ClaudeConversationRuntime.Refused.tooLarge) == "too_large")
        #expect(ClaudeConversationRuntime.failureCode(CocoaError(.fileNoSuchFile)) == "other")
    }

    @Test func aTurnsToDosGetTheTurnsLineAndItsUndo() async throws {
        let c = try await Conversation()
        let (turn, done) = try await c.turn { tools in
            _ = tools?.call("add_todo", .init([(key: "title", value: .str("Invented from the conversation"))]))
        }
        #expect(done["phase"] == .str("replied"))
        #expect(done["changes"]?["summary"] == .str("Added 1 to-do: Invented from the conversation"))
        #expect(done["changes"]?["undoable"] == .bool(true))
        #expect(Teka.read(c.s.folder).items.contains { $0.title == "Invented from the conversation" })
        #expect(try await c.request("chat_history")["turns"]?.arrayValue?.last?["changes"]?["summary"] == done["changes"]?["summary"])

        #expect(try await c.request("chat_undo", [("turn_id", .str(turn))])["undone"] == .bool(true))
        #expect(!Teka.read(c.s.folder).items.contains { $0.title == "Invented from the conversation" })
        let id = try #require(try await c.request("chat_history")["turns"]?.arrayValue?.last?["changes"])
        #expect(id["undone"] == .bool(true))
    }

    @Test func aTurnsFilesAndToDosUndoTogether() async throws {
        let c = try await Conversation()
        let folder = c.s.folder
        let (turn, done) = try await c.turn { tools in
            _ = tools?.call("add_todo", .init([(key: "title", value: .str("Invented alongside a file"))]))
            try? Data("invented".utf8).write(to: folder.appendingPathComponent("notes-made.md"))
        }
        #expect(done["changes"]?["summary"] == .str("Added 1 file: notes-made.md. Added 1 to-do: Invented alongside a file"))
        #expect(try await c.request("chat_undo", [("turn_id", .str(turn))])["undone"] == .bool(true))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("notes-made.md").path))
        #expect(!Teka.read(folder).items.contains { $0.title == "Invented alongside a file" })
    }

    @Test func aFileConflictLeavesTheToDosToo() async throws {
        let c = try await Conversation()
        let file = c.s.folder.appendingPathComponent("notes-made.md")
        let (turn, _) = try await c.turn { tools in
            _ = tools?.call("add_todo", .init([(key: "title", value: .str("Invented stays"))]))
            try? Data("invented".utf8).write(to: file)
        }
        try Data("the person's words".utf8).write(to: file)
        let refused = try await c.request("chat_undo", [("turn_id", .str(turn))])
        #expect(refused["undone"] == .bool(false) && refused["conflicts"] == .array([.str("notes-made.md")]))
        #expect(Teka.read(c.s.folder).items.contains { $0.title == "Invented stays" })
    }

    @Test func aBinderWithoutFileChangesStillHasItsToDoTools() async throws {
        let c = try await Conversation(files: false)
        let (turn, done) = try await c.turn { tools in
            _ = tools?.call("add_todo", .init([(key: "title", value: .str("Invented without files"))]))
        }
        #expect(c.engine.lock.withLock { c.engine.reaches.last ?? nil } == nil)
        #expect(done["changes"]?["summary"] == .str("Added 1 to-do: Invented without files"))
        #expect(try await c.request("chat_undo", [("turn_id", .str(turn))])["undone"] == .bool(true))
    }

    @Test func thePolicyTellsTheAgentToActAndNotToPropose() async throws {
        let c = try await Conversation()
        _ = try await c.turn { _ in }
        let policy = try #require(c.engine.lock.withLock { c.engine.policies.last })
        #expect(policy.contains("add_todo") && policy.contains("do not ask them to confirm"))
        #expect(!policy.contains("Add To-do") && !policy.contains("\"task\""))
    }

    @Test func withNoWriterTheAgentHasNoToolsAndIsToldSo() async throws {
        let c = try await Conversation(attach: false)
        _ = try await c.turn { _ in }
        #expect(c.engine.lock.withLock { c.engine.appTools } == nil)
        #expect(try #require(c.engine.lock.withLock { c.engine.policies.last }).contains("You cannot change to-dos in this turn"))
    }

    @Test func theSetupCheckNeverHasTools() async throws {
        let c = try await Conversation()
        // Configuring ran the check; connecting ran none. No launch before the first turn had tools.
        #expect(c.engine.lock.withLock { c.engine.appTools } == nil)
    }
}

/// The person's own command, on a real shell. Invented text only.
@Suite struct ClaudeAccountChooserTests {
    @Test func whatItPrintsAndHowItEndsAreRead() {
        #expect(ClaudeAccountChooser.run("echo invented/account", shell: "/bin/sh") == .account("invented/account"))
        #expect(ClaudeAccountChooser.run("printf ''", shell: "/bin/sh") == .noQuota)
        #expect(ClaudeAccountChooser.run("exit 75", shell: "/bin/sh") == .noQuota)
        #expect(ClaudeAccountChooser.run("exit 3", shell: "/bin/sh") == .failed)
        #expect(ClaudeAccountChooser.run("echo first; echo second", shell: "/bin/sh") == .account("first"))
    }
    @Test func aStuckCommandIsStoppedAndABackgroundHelperDoesNotHoldIt() {
        let start = Date()
        #expect(ClaudeAccountChooser.run("/bin/sleep 30", shell: "/bin/sh", timeout: 0.3) == .failed)
        #expect(ClaudeAccountChooser.run("/bin/sleep 5 & echo invented", shell: "/bin/sh") == .account("invented"))
        #expect(Date().timeIntervalSince(start) < 4)
    }
}

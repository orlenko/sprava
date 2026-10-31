import Foundation
import Services
import SpravaKit
import Testing
@testable import SpravaApp

@MainActor @Suite struct ClaudeConversationAdapterTests {
    final class Server {
        let scope = UUID()
        var turns: [UUID: UUID] = [:]
        var calls: [JSONObject] = []
        var loseSendReply = false
        var loseTaskReply = false
        var enabled = true
        /// What claude_status says: whether Claude is set up in Sprava; nil makes the read itself fail.
        var accountReady: Bool? = true
        /// Whether claude_enable refuses, as the runtime does for a binder while Claude is not set up.
        var refuseEnable = false
        func answer(_ text: String) throws -> String {
            let value = try JSONParser.parse(text).value
            let object = try #require(value.objectValue); calls.append(object)
            var fields: [(String, JSONValue)] = [("ok", .bool(true))]
            switch value["command"]?.stringValue {
            case "claude_status":
                guard let ready = accountReady else { throw RuntimeClient.Failure(message: "Invented timeout", kind: .timedOut) }
                fields += [("enabled", .bool(ready)), ("credential_persistent", .bool(true))]
            case "claude_enable" where refuseEnable:
                throw RuntimeClient.Failure(message: "Enable Claude in Brains, then connect this binder.", kind: .refused)
            case "claude_binder", "claude_enable": fields += [("enabled", .bool(enabled)), ("binder_id", .str(scope.uuidString)), ("documents", .bool(true)), ("intake", .bool(true))]
            case "chat_history": fields += [("turns", .array([]))]
            case "chat_send":
                let request = try #require(value["request_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
                let turn = turns[request] ?? UUID(); turns[request] = turn
                if loseSendReply { loseSendReply = false; throw RuntimeClient.Failure(message: "Invented timeout", kind: .timedOut) }
                fields += [("request_id", .str(request.uuidString)), ("turn_id", .str(turn.uuidString)), ("binder_id", .str(scope.uuidString))]
            case "chat_poll":
                let request = try #require(value["request_id"]?.stringValue.flatMap(UUID.init(uuidString:))), turn = try #require(turns[request])
                let reply = JSONWriter.compact(.obj([("answer", .str("The invented bylaw covers pets.")),
                    ("citations", .array([.obj([("path", .str("documents/bylaw.pdf")), ("page", .int(2))])])),
                    ("task", .obj([("title", .str("Ask the board")), ("details", .str("Request written permission."))])),
                    ("draft", .obj([("to", .str("manager@example.com")), ("subject", .str("Pet permission")), ("body", .str("Please confirm permission.")), ("recipient_in_sources", .bool(true))]))]))
                fields += [("phase", .str("replied")), ("request_id", .str(request.uuidString)), ("turn_id", .str(turn.uuidString)), ("binder_id", .str(scope.uuidString)), ("reply", .str(reply))]
            case "apply":
                if loseTaskReply { throw RuntimeClient.Failure(message: "Invented timeout", kind: .timedOut) }
                fields += [("op", .str("invented-op"))]
            default: break
            }
            return JSONWriter.compact(.obj(fields))
        }
    }
    let folder = URL(fileURLWithPath: "/invented/workshop")
    func until(_ condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
    func model(_ server: Server) -> ClaudeBinderConversation {
        ClaudeBinderConversation(client: RuntimeClient(answer: { try server.answer($0) }), authenticate: {})
    }
    @Test func theRealAdapterKeepsExactWordsAndRecoversALostAcceptanceReply() async throws {
        let server = Server(), model = model(server); server.loseSendReply = true
        await model.show(folder); model.chat.draft = "  Which pet bylaw?\n Keep the exact line. "
        let original = model.chat.draft
        await model.chat.send()
        #expect(model.chat.draft == original)
        await model.chat.send(); await until { !model.chat.isReplying }
        let requests = server.calls.filter { $0["command"] == .str("chat_send") }
        #expect(requests.count == 2 && requests[0]["request_id"] == requests[1]["request_id"])
        #expect(requests.allSatisfy { $0["text"] == .str(original) })
        #expect(server.turns.count == 1)
        #expect(model.chat.entries.contains { $0.text.contains("documents/bylaw.pdf, page 2") })
    }
    @Test func suggestedTasksNeedAnExplicitClickAndAreSavedPrivatelyOnlyOnce() async throws {
        let server = Server(), model = model(server)
        await model.show(folder); model.chat.draft = "Draft a reply and suggest a task."
        await model.chat.send(); await until { !model.chat.isReplying }
        #expect(server.calls.allSatisfy { $0["command"] != .str("apply") })
        let id = try #require(model.cards.keys.first)
        #expect(model.cards[id]?.body == "Please confirm permission.")
        model.cards[id]?.taskTitle = "Ask about written permission"
        model.cards[id]?.due = "2026-10-28"
        model.cards[id]?.priority = "high"
        await model.addTask(id); await model.addTask(id)
        let writes = server.calls.filter { $0["command"] == .str("apply") }
        #expect(writes.count == 1 && writes[0]["binder"] == .str(folder.path))
        #expect(writes[0]["args"]?["item"]?["title"] == .str("Ask about written permission"))
        #expect(writes[0]["args"]?["item"]?["sensitivity"] == .str("private"))
        #expect(model.cards[id]?.saved == true)
        #expect(writes[0]["args"]?["item"]?["due"] == .str("2026-10-28"))
        #expect(writes[0]["args"]?["item"]?["priority"] == .str("high"))
        #expect(writes[0]["conversation_binding"] == .str(server.scope.uuidString))
    }
    @Test func anUncertainTaskSaveKeepsTheWordsAndCannotBlindlyRetry() async throws {
        let server = Server(), model = model(server); server.loseTaskReply = true
        await model.show(folder); model.chat.draft = "Add a task suggestion."
        await model.chat.send(); await until { !model.chat.isReplying }
        let id = try #require(model.cards.keys.first)
        await model.addTask(id); await model.addTask(id)
        #expect(server.calls.filter { $0["command"] == .str("apply") }.count == 1)
        #expect(model.cards[id]?.uncertain == true && model.cards[id]?.saved == false)
        #expect(model.cards[id]?.taskTitle == "Ask the board")
    }
    @Test func subscriptionEntryIsPrivateAndOnlyExplicitEnableSubmitsIt() async throws {
        let server = Server(), client = RuntimeClient(answer: { try server.answer($0) })
        let model = ClaudeAccountModel(client: client, authenticate: {})
        await model.load(); model.token = "invented-subscription-token"; model.program = "/invented/claude"
        #expect(!server.calls.contains { $0["command"] == .str("claude_configure") })
        await model.enable()
        #expect(model.token.isEmpty && model.enabled)
        let submitted = server.calls.filter { $0["command"] == .str("claude_configure") }
        #expect(submitted.count == 1)
        #expect(submitted.first?["credential"] == .str("invented-subscription-token"))
        #expect(server.calls.filter { $0["command"] != .str("claude_configure") }.allSatisfy { $0["credential"] == nil })
        #expect(server.calls.last?["command"] == .str("claude_status"))
        #expect(model.persistent && model.message?.contains("Claude is ready") == true)
        #expect(model.message?.contains("invented-subscription-token") == false)
    }

    /// A binder could only say "Enable Claude in Brains first", whatever was missing (2026-10-28: the person had set
    /// up the external Claude Code connection instead, and nothing said which setup the binder needs).
    @Test func aBinderSaysWhichSetupIsMissing() async throws {
        let server = Server(), model = model(server)
        server.enabled = false; server.accountReady = false; server.refuseEnable = true
        await model.show(folder)
        #expect(model.accountReady == false && !model.connected)
        await model.connect()
        #expect(model.message?.contains("Claude is not set up in Sprava yet. Open Assistant") == true)
        // A status read that fails is no evidence that the setup is missing.
        server.accountReady = nil
        await model.connect()
        #expect(model.accountReady == nil)
        #expect(model.message?.contains("could not check Claude's setup") == true)
        #expect(model.message?.contains("not set up") == false)
        server.accountReady = true
        await model.connect()
        #expect(model.message?.contains("Claude is set up; check that this binder is adopted") == true)
    }

    @Test func enablingSaysWhichStepIsMissing() async throws {
        let server = Server(), client = RuntimeClient(answer: { try server.answer($0) })
        let model = ClaudeAccountModel(client: client, authenticate: {})
        #expect(model.enableBlocker?.hasPrefix("Checking") == true)
        server.accountReady = nil
        await model.load()
        #expect(model.enableBlocker?.contains("background part did not answer") == true)
        server.accountReady = false
        await model.load()
        model.program = ""
        #expect(model.enableBlocker?.hasPrefix("Install native Claude Code") == true)
        model.program = "/invented/claude"
        #expect(model.enableBlocker?.hasPrefix("Paste your subscription token") == true)
        model.token = "invented-subscription-token"
        #expect(model.enableBlocker == nil)
        #expect(model.setupCommand == "'/invented/claude' setup-token")
    }

    /// A binder whose setup read is still on its way must not take the page back once another binder is shown: its
    /// conversation would show the old binder while the page belongs to the new one, and Send would stay unavailable.
    @Test func aSlowSetupReadDoesNotTakeThePageBackFromTheNextBinder() async throws {
        let old = URL(fileURLWithPath: "/invented/old-workshop"), new = URL(fileURLWithPath: "/invented/new-workshop")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let server = Server()
        let client = RuntimeClient(answer: { text in
            let value = try JSONParser.parse(text).value
            switch value["command"]?.stringValue {
            case "claude_binder" where value["binder"] == .str(old.path):
                return #"{"ok":true,"enabled":false,"binder_id":null}"#
            case "claude_status":
                for await _ in gate { break }   // held until the new binder is shown
                return #"{"ok":true,"enabled":false,"credential_persistent":true}"#
            default:
                return try server.answer(text)
            }
        })
        let model = ClaudeBinderConversation(client: client, authenticate: {})
        let first = Task { await model.show(old) }
        try await Task.sleep(for: .milliseconds(50))
        await model.show(new)
        #expect(model.connected && model.chat.folder == new.standardizedFileURL && model.chat.isAvailable)
        release.yield()
        await first.value
        #expect(model.folder == new.standardizedFileURL && model.chat.folder == new.standardizedFileURL)
        #expect(model.chat.isAvailable && model.accountReady == true)
    }

    /// A refused connect reports into its own binder only.
    @Test func aConnectRefusalStaysWithItsBinder() async throws {
        let old = URL(fileURLWithPath: "/invented/old-workshop"), new = URL(fileURLWithPath: "/invented/new-workshop")
        let (gate, release) = AsyncStream<Void>.makeStream()
        let server = Server()
        let client = RuntimeClient(answer: { text in
            let value = try JSONParser.parse(text).value
            switch value["command"]?.stringValue {
            case "claude_binder" where value["binder"] == .str(old.path):
                return #"{"ok":true,"enabled":false,"binder_id":null}"#
            case "claude_enable":
                for await _ in gate { break }
                throw RuntimeClient.Failure(message: "Enable Claude in Brains, then connect this binder.", kind: .refused)
            default:
                return try server.answer(text)
            }
        })
        let model = ClaudeBinderConversation(client: client, authenticate: {})
        await model.show(old)
        let connecting = Task { await model.connect() }
        try await Task.sleep(for: .milliseconds(50))
        await model.show(new)
        release.yield()
        await connecting.value
        #expect(model.folder == new.standardizedFileURL && model.message == nil)
    }
}

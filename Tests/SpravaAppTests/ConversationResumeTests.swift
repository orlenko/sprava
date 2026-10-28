import Foundation
import Services
import SpravaKit
@testable import SpravaApp
import Testing

@MainActor @Suite struct ConversationResumeTests {
    @MainActor final class Server {
        let scope = UUID(), request = UUID(), turn = UUID()
        var phase = "running"
        var wrongScope = false
        var calls: [JSONObject] = []
        var polls = 0
        var waiting: [CheckedContinuation<Void, Never>] = []
        var hold = true
        let text = "Keep this exact invented question."

        func finish(_ phase: String) {
            self.phase = phase; hold = false
            let pending = waiting; waiting = []; pending.forEach { $0.resume() }
        }
        func answer(_ text: String) async throws -> String {
            let value = try JSONParser.parse(text).value
            calls.append(try #require(value.objectValue))
            let reply = JSONWriter.compact(.obj([("answer", .str("The saved invented answer.")), ("citations", .array([])), ("task", .null), ("draft", .null)]))
            var record: [(String, JSONValue)] = [("binder_id", .str(wrongScope ? "different-binder" : scope.uuidString)),
                ("request_id", .str(request.uuidString)), ("turn_id", .str(turn.uuidString)), ("text", .str(self.text)), ("phase", .str(phase))]
            switch value["command"]?.stringValue {
            case "claude_binder": return JSONWriter.compact(.obj([("ok", .bool(true)), ("enabled", .bool(true)), ("binder_id", .str(scope.uuidString))]))
            case "chat_history": return JSONWriter.compact(.obj([("ok", .bool(true)), ("turns", .array([.obj(record)]))]))
            case "chat_poll":
                polls += 1
                if hold { await withCheckedContinuation { waiting.append($0) } }
                record.removeAll { $0.0 == "phase" }
                record += [("phase", .str(phase)), ("reply", .str(reply)), ("ok", .bool(true))]
                return JSONWriter.compact(.obj(record))
            case "chat_stop": finish("interrupted"); return #"{"ok":true}"#
            default: Issue.record("A restored turn must never be sent again"); throw ChatCommandFailure.invalidRequest
            }
        }
    }

    let folder = URL(fileURLWithPath: "/invented/workshop")
    func until(_ condition: () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(condition())
    }
    func model(_ server: Server) -> ClaudeBinderConversation {
        ClaudeBinderConversation(client: RuntimeClient(answer: { try await server.answer($0) }), authenticate: {})
    }

    @Test func reopeningAnActiveConversationResumesTheReplyWithoutAcceptingAnotherTurn() async {
        let server = Server(), conversation = model(server)
        defer { server.finish("interrupted") }
        await conversation.show(folder); await until { server.polls == 1 }
        #expect(conversation.chat.isReplying)
        #expect(conversation.chat.entries.filter { $0.speaker == .person }.map(\.text) == [server.text])
        conversation.chat.draft = "A separate unsent follow-up"
        await conversation.show(folder)
        for _ in 0..<10 { await Task.yield() }
        #expect(server.polls == 1) // The first poll is held; another attachment would make two.
        server.finish("replied"); await until { !conversation.chat.isReplying }
        #expect(conversation.chat.entries.contains { $0.text == "The saved invented answer." && $0.state == .replied })
        #expect(conversation.chat.draft == "A separate unsent follow-up")
        #expect(server.calls.allSatisfy { $0["command"] != .str("chat_send") })
    }

    @Test func stopAfterReopeningNamesTheExistingRequestAndTurn() async throws {
        let server = Server(), conversation = model(server)
        defer { server.finish("interrupted") }
        await conversation.show(folder); await until { server.polls == 1 }
        await conversation.chat.stop(); await until { !conversation.chat.isReplying }
        let stop = try #require(server.calls.first { $0["command"] == .str("chat_stop") })
        #expect(stop["request_id"] == .str(server.request.uuidString) && stop["turn_id"] == .str(server.turn.uuidString))
        #expect(stop["binder"] == .str(folder.path))
        #expect(conversation.chat.entries.contains { $0.state == .stopped })
        #expect(server.calls.allSatisfy { $0["command"] != .str("chat_send") })
    }

    @Test func anotherBindersHistoryCannotStartPollingInThisConversation() async {
        let server = Server(); server.wrongScope = true
        let conversation = model(server)
        await conversation.show(folder)
        for _ in 0..<10 { await Task.yield() }
        #expect(server.polls == 0 && !conversation.chat.isReplying)
    }
}

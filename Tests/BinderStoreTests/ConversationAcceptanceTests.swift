import BinderStore
import Foundation
import SpravaKit
import Testing

@Suite struct ConversationAcceptanceTests {
    func database() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-conversation-acceptance-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(root)
        return root.appendingPathComponent("conversation.sqlite")
    }

    @Test func aLostAcceptanceReplyRecoversTheExactOriginalLineAfterReopen() throws {
        let url = try database(), conversation = UUID(), request = UUID()
        let original = "  Please draft a reply.\nKeep the exact words: café 🐈.  "
        let first = try ConversationTurnStore(at: url).accept(conversationID: conversation, requestID: request, text: original)
        let reopened = try ConversationTurnStore(at: url)
        let again = try reopened.accept(conversationID: conversation, requestID: request, text: original)
        #expect(first == again && again.text == original && again.phase == .accepted)
        #expect(throws: ConversationTurnStore.Refused.requestConflict) {
            try reopened.accept(conversationID: conversation, requestID: request, text: original + "changed")
        }
        #expect(try reopened.history(conversationID: conversation).count == 1)
        #expect(!String(describing: first).contains("café") && !String(reflecting: first).contains("reply"))
    }

    @Test func independentConnectionsAcceptAndClaimTheSameRequestOnlyOnce() async throws {
        let url = try database(), conversation = UUID(), request = UUID()
        let a = try ConversationTurnStore(at: url), b = try ConversationTurnStore(at: url)
        let results = try await withThrowingTaskGroup(of: (UUID, Bool).self) { group in
            for n in 0..<40 {
                group.addTask {
                    let store = n.isMultiple(of: 2) ? a : b
                    let record = try store.accept(conversationID: conversation, requestID: request, text: "Explain the pet regulation.")
                    return (record.turnID, try store.claim(conversationID: conversation, requestID: request))
                }
            }
            var all: [(UUID, Bool)] = []
            for try await result in group { all.append(result) }
            return all
        }
        #expect(Set(results.map(\.0)).count == 1)
        #expect(results.filter(\.1).count == 1)
        #expect(try a.history(conversationID: conversation).count == 1)
    }

    @Test func successfulCompletionIsDurableAndCannotBeRunOrRewrittenAgain() throws {
        let url = try database(), conversation = UUID(), request = UUID()
        let store = try ConversationTurnStore(at: url)
        _ = try store.accept(conversationID: conversation, requestID: request, text: "Which bylaw covers pets?")
        #expect(throws: ConversationTurnStore.Refused.invalidTransition) {
            try store.finish(conversationID: conversation, requestID: request, phase: .replied, reply: "Not started")
        }
        #expect(try store.claim(conversationID: conversation, requestID: request))
        let answer = "Section 9.4 requires written permission [bylaws, p. 2]."
        let done = try store.finish(conversationID: conversation, requestID: request, phase: .replied, reply: answer)
        let reopened = try ConversationTurnStore(at: url)
        #expect(try reopened.record(conversationID: conversation, requestID: request) == done)
        #expect(try !reopened.claim(conversationID: conversation, requestID: request))
        #expect(try reopened.finish(conversationID: conversation, requestID: request, phase: .replied, reply: answer) == done)
        #expect(throws: ConversationTurnStore.Refused.invalidTransition) {
            try reopened.finish(conversationID: conversation, requestID: request, phase: .replied, reply: "Changed later")
        }
    }

    @Test func recoveryKeepsThePersonsWordsAndDoesNotReplayInterruptedWork() throws {
        let url = try database(), conversation = UUID(), running = UUID(), queued = UUID()
        let store = try ConversationTurnStore(at: url)
        _ = try store.accept(conversationID: conversation, requestID: running, text: "Draft an inspection reply.")
        _ = try store.accept(conversationID: conversation, requestID: queued, text: "Show the current tasks.")
        #expect(try store.claim(conversationID: conversation, requestID: running))
        let restarted = try ConversationTurnStore(at: url)
        try restarted.recoverInterrupted(conversationID: conversation)
        let records = try restarted.history(conversationID: conversation)
        #expect(records.map(\.phase) == [.interrupted, .accepted])
        #expect(records.first?.text == "Draft an inspection reply." && records.first?.reply == nil)
        #expect(try !restarted.claim(conversationID: conversation, requestID: running))
        #expect(try restarted.claim(conversationID: conversation, requestID: queued))
        #expect(throws: ConversationTurnStore.Refused.invalidTransition) {
            try restarted.finish(conversationID: conversation, requestID: queued, phase: .interrupted, reply: "Partial text")
        }
    }

    @Test func clearingOneConversationNeverClearsAnotherAndInvalidLinesAreNotAccepted() throws {
        let store = try ConversationTurnStore(at: database()), a = UUID(), b = UUID(), request = UUID()
        for text in [" \n ", String(repeating: "x", count: ConversationTurnStore.maximumLineBytes + 1)] {
            #expect(throws: ConversationTurnStore.Refused.invalidLine) {
                try store.accept(conversationID: a, requestID: request, text: text)
            }
        }
        _ = try store.accept(conversationID: a, requestID: request, text: "First binder")
        _ = try store.accept(conversationID: b, requestID: request, text: "Other binder")
        try store.clear(conversationID: a)
        #expect(try store.history(conversationID: a).isEmpty)
        #expect(try store.history(conversationID: b).map(\.text) == ["Other binder"])
    }

    @Test func damagedAndFutureStateArePreservedAndNeverResetToEmpty() throws {
        let broken = try database(), bytes = Data("not a SQLite database".utf8)
        try bytes.write(to: broken)
        #expect(throws: (any Error).self) { try ConversationTurnStore(at: broken) }
        #expect(try Data(contentsOf: broken) == bytes)
        let future = try database()
        let state = try StateStore.open(future, schema: .init(version: 2, statements: ["CREATE TABLE keep (value INTEGER)"]))
        try state.write { try $0.execute("INSERT INTO keep VALUES (17)") }
        #expect(throws: (any Error).self) { try ConversationTurnStore(at: future) }
        #expect(try state.read { try $0.rows("SELECT value FROM keep").first?.first?.integer } == 17)
    }

    @Test func manyTinyTurnsCannotDefeatTheHistoryMemoryBound() throws {
        let url = try database(), conversation = UUID()
        let turns = try ConversationTurnStore(at: url)
        let fixture = try StateStore.open(url, schema: .init(version: 1, statements: []))
        try fixture.write { t in
            try t.execute("""
                WITH RECURSIVE entries(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM entries WHERE n < ?)
                INSERT INTO conversation_turns (conversation_id, request_id, turn_id, text, phase, created_at)
                SELECT ?, printf('00000000-0000-4000-8000-%012d', n), printf('10000000-0000-4000-8000-%012d', n),
                       'x', 'accepted', '2026-10-24T10:00:00Z' FROM entries
                """, .integer(Int64(ConversationTurnStore.maximumTurns)), .text(conversation.uuidString))
        }
        #expect(throws: ConversationTurnStore.Refused.historyFull) {
            try turns.accept(conversationID: conversation, requestID: UUID(), text: "One more line")
        }
    }
}

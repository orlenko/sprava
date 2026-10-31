import BinderStore
import Foundation
import SpravaKit
import Testing
@testable import Services

@Suite struct ConversationExportTests {
    @Test func runtimePagesCompleteHistoryWhileDisconnectedWithoutLaunchingAModel() async throws {
        let f = try ClaudeConversationTests.Fixture(); try await f.connect()
        let scope = try await f.request("claude_binder")
        let binder = try #require(scope["binder_id"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let store = try ConversationTurnStore(at: f.root.appendingPathComponent("support/binder-store/conversation.sqlite"))
        for n in 0..<205 { _ = try store.accept(conversationID: binder, requestID: UUID(), text: "Invented workshop \(n)") }
        _ = try await f.request("claude_disable")
        let runs = f.engine.lock.withLock { f.engine.lines.count }
        #expect(try await f.request("chat_history")["more"] == .bool(true))
        let first = try await f.request("chat_export")
        let fields: [(String, JSONValue)] = [("export_id", try #require(first["export_id"])), ("after", try #require(first["after"]))]
        let second = try await f.request("chat_export", fields)
        let third = try await f.request("chat_export", [("export_id", try #require(second["export_id"])), ("after", try #require(second["after"]))])
        let rows = [first, second, third].flatMap { $0["turns"]?.arrayValue ?? [] }
        #expect(rows.count == 205 && Set(rows.compactMap { $0["request_id"]?.stringValue }).count == 205)
        #expect(third["done"] == .bool(true) && first["count"] == .int(205))
        #expect(rows.first?["text"] == .str("Invented workshop 0") && rows.last?["text"] == .str("Invented workshop 204"))
        #expect(f.engine.lock.withLock { f.engine.lines.count } == runs)
        _ = try await f.request("chat_clear")
        await #expect(throws: ConversationTurnStore.Refused.snapshotChanged) { try await f.request("chat_export", fields) }
    }
    @Test func ticketsAreBoundToTheConversationAndExpireAndOversizePagesRefuse() throws {
        let root = try ClaudeConversationTests.Fixture().root
        let store = try ConversationTurnStore(at: root.appendingPathComponent("export/conversation.sqlite")), binder = UUID()
        let now = Date(); var exporter = ConversationExport()
        let first = try exporter.page(.init(), binder: binder, store: store, now: now)
        let fields = JSONObject([(key: "export_id", value: try #require(first["export_id"])), (key: "after", value: .int(0))])
        #expect(throws: ClaudeConversationRuntime.Refused.self) { try exporter.page(fields, binder: UUID(), store: store, now: now) }
        #expect(throws: ClaudeConversationRuntime.Refused.self) { try exporter.page(fields, binder: binder, store: store, now: now.addingTimeInterval(301)) }
        let record = try store.accept(conversationID: binder, requestID: UUID(), text: String(repeating: "\u{1}", count: 2 * 1024 * 1024))
        #expect(try store.claim(conversationID: binder, requestID: record.requestID))
        _ = try store.finish(conversationID: binder, requestID: record.requestID, phase: .replied, reply: "Invented answer")
        #expect(throws: ClaudeConversationRuntime.Refused.self) { try exporter.page(.init(), binder: binder, store: store) }
    }
}

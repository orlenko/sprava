import BinderStore
import Foundation
import Testing

@Suite struct ConversationExportTests {
    @Test func pagesKeepOrderPastTheHistoryLimitAndFreezeUnfinishedTurns() throws {
        let store = try ConversationTurnStore(at: ConversationAcceptanceTests().database()), binder = UUID(), other = UUID()
        var originals: [UUID] = []
        for n in 0..<235 {
            let request = UUID(); originals.append(request)
            _ = try store.accept(conversationID: binder, requestID: request, text: "Workshop line \(n)")
        }
        _ = try store.accept(conversationID: other, requestID: UUID(), text: "Other binder excluded")
        let snapshot = try store.snapshot(conversationID: binder)
        let first = try store.page(snapshot)
        #expect(first.records.count == 100 && !first.done)
        let active = originals[150]
        #expect(try store.claim(conversationID: binder, requestID: active))
        _ = try store.finish(conversationID: binder, requestID: active, phase: .replied, reply: "Completed later")
        _ = try store.accept(conversationID: binder, requestID: UUID(), text: "Appended later")
        let second = try store.page(snapshot, after: first.after), third = try store.page(snapshot, after: second.after)
        let rows = first.records + second.records + third.records
        #expect(third.done && snapshot.count == 235 && rows.map(\.requestID) == originals)
        #expect(rows[150].phase == .accepted && rows[150].reply == nil)
        #expect(rows.allSatisfy { $0.conversationID == binder })
        try store.clear(conversationID: binder)
        _ = try store.accept(conversationID: binder, requestID: UUID(), text: "New after clear")
        #expect(throws: ConversationTurnStore.Refused.snapshotChanged) { try store.page(snapshot, after: first.after) }
    }
    @Test func byteBudgetMakesSmallerPagesWithoutDroppingOversizeRecords() throws {
        let store = try ConversationTurnStore(at: ConversationAcceptanceTests().database()), binder = UUID()
        for _ in 0..<3 { _ = try store.accept(conversationID: binder, requestID: UUID(), text: String(repeating: "x", count: 600_000)) }
        let snapshot = try store.snapshot(conversationID: binder)
        var after: Int64 = 0
        for n in 0..<3 {
            let page = try store.page(snapshot, after: after)
            #expect(page.records.count == 1 && page.done == (n == 2)); after = page.after
        }
        let empty = try store.snapshot(conversationID: UUID())
        #expect(try store.page(empty).done && empty.count == 0)
        #expect(throws: ConversationTurnStore.Refused.snapshotChanged) { try store.page(snapshot, after: -1) }
    }
}

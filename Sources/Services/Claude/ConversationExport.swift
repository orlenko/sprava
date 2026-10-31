import BinderStore
import Foundation
import SpravaKit

/// App-only paged snapshots. Tickets contain no text and grant no model or binder operation authority.
/// Every page must be resolved through the selected physical binder's saved connection again.
struct ConversationExport {
    private struct Ticket {
        let binder: UUID
        let snapshot: ConversationTurnStore.Snapshot
        let expires: Date
    }
    private var tickets: [UUID: Ticket] = [:]
    mutating func page(_ request: JSONObject, binder: UUID, store: ConversationTurnStore,
                       now: Date = Date()) throws -> JSONObject {
        tickets = tickets.filter { $0.value.expires > now }
        let token: UUID, ticket: Ticket, after: Int64
        if let raw = request["export_id"] {
            guard let id = raw.stringValue.flatMap(UUID.init(uuidString:)), let saved = tickets[id], saved.binder == binder,
                  let offset = request["after"]?.numberValue?.safeInteger, offset >= 0 else {
                throw ClaudeConversationRuntime.Refused.invalidRequest
            }
            token = id; ticket = saved; after = Int64(offset)
        } else {
            guard request["after"] == nil else { throw ClaudeConversationRuntime.Refused.invalidRequest }
            if tickets.count >= 8, let oldest = tickets.min(by: { $0.value.expires < $1.value.expires })?.key { tickets[oldest] = nil }
            token = UUID(); after = 0
            ticket = Ticket(binder: binder, snapshot: try store.snapshot(conversationID: binder), expires: now.addingTimeInterval(300))
            tickets[token] = ticket
        }
        let page = try store.page(ticket.snapshot, after: after)
        let turns = page.records.map { record in
            JSONValue.obj([("binder_id", .str(record.conversationID.uuidString)), ("request_id", .str(record.requestID.uuidString)),
                           ("turn_id", .str(record.turnID.uuidString)), ("text", .str(record.text)),
                           ("phase", .str(record.phase.rawValue)), ("reply", record.reply.map(JSONValue.str) ?? .null)])
        }
        let result = JSONObject([(key: "binder_id", value: .str(binder.uuidString)), (key: "export_id", value: .str(token.uuidString)),
                                (key: "after", value: .int(Int(page.after))), (key: "count", value: .int(ticket.snapshot.count)),
                                (key: "done", value: .bool(page.done)), (key: "turns", value: .array(turns))])
        // JSON escaping can enlarge a page. Refuse explicitly rather than silently dropping a turn.
        guard JSONWriter.compact(.object(result)).utf8.count <= 8 * 1024 * 1024 else {
            throw ClaudeConversationRuntime.Refused.unavailable
        }
        return result
    }
}

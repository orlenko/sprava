import BinderStore
import Brains
import Foundation
import SpravaKit

/// The brain commands (architecture 7.5): listing and retiring old external MCP clients (D29).
extension Commands {
    static let brainCommands: [String: Handler] = [
        "list_clients": { c, _, r, now, today in try c.listClients(r, now: now, today: today) },
        "revoke_client": { c, _, r, now, today in try c.revokeClient(r, now: now, today: today) },
    ]

    func listClients(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let all = try MCPClients.load(support).clients
        let clients = all.filter { !$0.revoked }
        return JSONObject([(key: "legacy_terminal", value: .bool(!clients.contains { $0.id == "claude-code-1" } && all.contains { $0.id == "claude-code-1" })), (key: "clients", value: .array(clients.map { c in
            .obj([("id", .string(c.id)), ("name", .string(c.name)), ("created_at", .string(c.createdAt)),
                  ("binders", .obj(c.binders.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })),
                  ("documents", .bool(c.readsDocuments))])
        }))])
    }

    func revokeClient(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        guard case .string(let id)? = r["client_id"] else { throw Failure(message: "revoke_client needs client_id") }
        var clients = try MCPClients.load(support)
        // Every record under this id, so a client registered again after a revoke has its cards withdrawn too.
        let scope = Set(clients.clients.filter { $0.id == id }.flatMap(\.binders.keys)).sorted()
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
        clients.revoke(id: id)
        try clients.save(support)
        // Its cards still waiting are withdrawn (architecture 7.5).
        var withdrawn = 0
        do {
            for folder in scope where Owner.device(of: folder) == deviceID {
                for (p, _) in try ProposalStore.boundedList(in: folder) where p.state == "proposed" && p.actor["kind"] == .str("brain")
                    && p.actor["model"]?.stringValue == id {
                    try TekaStore(folder: folder, client: client).reject(p, reason: "the brain was disconnected", now: now)
                    withdrawn += 1
                }
            }
        } catch {
            // Access has already ended. A failed withdrawal must remain visible and retryable, never counted as done.
            throw Failure(message: "the client was revoked, but its waiting proposals could not all be withdrawn; try revoking it again")
        }
        return JSONObject([(key: "withdrawn", value: .int(withdrawn))])
    }
}

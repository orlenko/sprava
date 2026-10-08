import BinderStore
import Brains
import Foundation
import SpravaKit

/// The brain commands (architecture 7.5): registering, listing and revoking MCP clients.
extension Commands {
    static let brainCommands: [String: Handler] = [
        "register_client": { c, _, r, now, today in try c.registerClient(r, now: now, today: today) },
        "list_clients": { c, _, r, now, today in try c.listClients(r, now: now, today: today) },
        "client_documents": { c, _, r, now, today in try c.clientDocuments(r, now: now, today: today) },
        "revoke_client": { c, _, r, now, today in try c.revokeClient(r, now: now, today: today) },
    ]

    func registerClient(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // A brain client (architecture 7.5). The token is returned once and never stored, only its hash.
        guard case .string(let id)? = r["client_id"], case .object(let scope)? = r["binders"] else {
            throw Failure(message: "register_client needs client_id and binders")
        }
        var binders: [String: String] = [:]
        for e in scope.entries {
            guard e.key.hasPrefix("/"), ["read", "propose"].contains(e.value.stringValue ?? "") else {
                throw Failure(message: "binders map absolute paths to read or propose")
            }
            binders[URL(fileURLWithPath: e.key).standardizedFileURL.path] = e.value.stringValue!
        }
        var clients = try MCPClients.load(support)
        let token = try clients.register(id: id, name: r["name"]?.stringValue ?? id, binders: binders,
                                         documents: r["documents"] == .bool(true), now: now)
        try clients.save(support)
        return JSONObject([(key: "token", value: .string(token))])
    }

    func listClients(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        let clients = try MCPClients.load(support).clients.filter { !$0.revoked }
        return JSONObject([(key: "clients", value: .array(clients.map { c in
            .obj([("id", .string(c.id)), ("name", .string(c.name)), ("created_at", .string(c.createdAt)),
                  ("binders", .obj(c.binders.sorted { $0.key < $1.key }.map { ($0.key, .string($0.value)) })),
                  ("documents", .bool(c.readsDocuments))])
        }))])
    }

    func clientDocuments(_ r: JSONObject, now: Date, today: CalendarDate) throws -> JSONObject {
        // Whether a brain may read the full text of documents waiting for a careful reading.
        guard case .string(let id)? = r["client_id"], case .bool(let allowed)? = r["documents"] else {
            throw Failure(message: "client_documents needs client_id and documents")
        }
        var clients = try MCPClients.load(support)
        guard let i = clients.clients.firstIndex(where: { $0.id == id && !$0.revoked }) else { throw Failure(message: "no client \(id)") }
        clients.clients[i].documents = allowed ? true : nil
        try clients.save(support)
        return JSONObject()
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
        for folder in scope {
            for (p, _) in ProposalStore.list(in: folder) where p.state == "proposed" && p.actor["kind"] == .str("brain")
                && p.actor["model"]?.stringValue == id {
                try? TekaStore(folder: folder, client: client).reject(p, reason: "the brain was disconnected", now: now)
                withdrawn += 1
            }
        }
        return JSONObject([(key: "withdrawn", value: .int(withdrawn))])
    }
}

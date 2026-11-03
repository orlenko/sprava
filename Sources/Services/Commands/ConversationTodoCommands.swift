import BinderFormat
import BinderStore
import Foundation
import SpravaKit

/// The to-do writes of a person's conversation turn (conversation.md 18.5). Not in the command table: nothing that sends
/// commands can reach them, only `ClaudeTodoTools`, on the command queue.
extension Commands {
    /// One to-do's op, with the records binder-v0 §6.5 asks of a turn's op: who chose it, who asked, and for a record that
    /// exists, the revision it was based on. Returns the ops written.
    func applyTurnOp(_ op: String, args: JSONObject, expect: String?, folder f: URL, model: String, turn: UUID, request: UUID, now: Date = Date()) throws -> [JSONObject] {
        try refuseUnwritable(f)
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .string(client)), (key: "model", value: .string(model))])
        var extra: [(String, JSONValue)] = [
            ("approved_by", .str("user")), ("request", .str(request.uuidString.lowercased())),
            ("conversation", .obj([("turn", .str(turn.uuidString.lowercased())), ("message", .str(request.uuidString.lowercased()))])),
        ]
        if let expect { extra.append(("expect", .obj([("record", .str(expect))]))) }
        let store = TekaStore(folder: f, client: client)
        let body = TekaStore.OpBody(op: op, args: args, actor: actor, extra: extra)
        let applied = op == "add_item" ? try store.applyMinting([body], now: now) : try store.apply([body], now: now)
        try recordDigests(store.createdProposals, in: f)
        return applied
    }

    /// Reverses one op of a turn. True when it is reversed, this time or before; false when it changed since and stays.
    func undoTurnOp(_ opID: String, folder f: URL, now: Date = Date()) throws -> Bool {
        try refuseUnwritable(f)
        let store = TekaStore(folder: f, client: client)
        do {
            _ = try store.undoChange(opID: opID, now: now)
            try recordDigests(store.createdProposals, in: f)
            return true
        } catch let refused as TekaStore.Refused where refused.reason == "already undone" {
            return true
        } catch is Undo.Unsupported {
            return false
        }
    }

    /// What `run` checks of a command that writes: no interrupted expunge, and this Mac owns an adopted binder.
    /// Replaces the Notes section of the binder's dashboard for a conversation turn; `noting` records the way back first.
    func replaceTurnNotes(_ body: String, folder f: URL, now: Date = Date(), noting: (String, String) throws -> Void) throws {
        try refuseUnwritable(f)
        try DashboardKeeper(folder: f, impl: client).replaceNotes(with: body, now: now, noting: noting)
    }

    /// Puts a turn's earlier Notes back. False when the person changed them since, and they stay.
    func restoreTurnNotes(_ before: String, ifStill after: String, folder f: URL, now: Date = Date()) throws -> Bool {
        try refuseUnwritable(f)
        return try DashboardKeeper(folder: f, impl: client).restoreNotes(before, ifStill: after, now: now)
    }

    private func refuseUnwritable(_ f: URL) throws {
        if Teka.expungePending(in: f) { throw Failure(message: "an expunge in this binder was interrupted") }
        if FileManager.default.fileExists(atPath: f.appendingPathComponent(".sprava/ops.ndjson").path), ownerDevice(f) != deviceID {
            throw Failure(message: "this binder is read-only here")
        }
    }
}

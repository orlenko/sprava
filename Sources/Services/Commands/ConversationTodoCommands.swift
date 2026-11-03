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
    /// Files a finished conversation's transcript as a private document of the binder and returns its path. The person asked for this
    /// from the app, so it is theirs. A filing that fails may already be recorded, so its file stays: an extra file harms nothing and a
    /// retry takes a new name, where deleting could leave a record with no document.
    func fileConversation(_ text: String, folder f: URL, now: Date = Date()) throws -> String {
        try refuseUnwritable(f)
        let day = String(ISOTime.string(now).prefix(10))
        var stamp = ISOTime.string(now).prefix(16).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "-"), path = "conversations/\(stamp).md", n = 1
        while !DocumentPaths.isFreeDestination(path, in: f) {
            n += 1
            guard n <= 100 else { throw Failure(message: "a transcript could not be given a free name") }
            stamp = "\(ISOTime.string(now).prefix(16).replacingOccurrences(of: ":", with: "").replacingOccurrences(of: "T", with: "-"))-\(n)"; path = "conversations/\(stamp).md"
        }
        let url = f.appendingPathComponent(path), data = Data(text.utf8)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure(message: "a transcript could not be given a free name") }
        try AtomicFile.write(data, to: url)
        guard let sha = DocumentPaths.sha256(of: url) else { throw Failure(message: "the transcript could not be read back") }
        let document = JSONValue.obj([("id", .str("$new:1")), ("title", .str("Conversation of \(day)")), ("path", .str(path)), ("sha256", .str(sha)), ("sensitivity", .str("private"))])
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        let store = TekaStore(folder: f, client: client)
        _ = try store.applyMinting([.init(op: "file_document", args: .init([(key: "document", value: document)]), actor: actor)], now: now)
        try recordDigests(store.createdProposals, in: f)
        return path
    }

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

import BinderFormat
import Foundation
import SpravaKit

/// A settled binder session held under its existing write lock. Methods expire when the callback returns.
/// No method takes another lock. Only the restricted phone item operations can be prepared or written here.
public final class CompanionOperationTransaction {
    fileprivate let store: TekaStore
    fileprivate var state: TekaStore.State
    fileprivate var active = true
    fileprivate init(store: TekaStore, state: TekaStore.State) { self.store = store; self.state = state }
    private func check() throws { guard active else { throw TekaStore.Refused(reason: "the companion binder transaction has ended") } }
    public func currentState() throws -> TekaStore.State { try check(); return state }
    public func proof(effectID: String, tag: String) throws -> CompanionOperationProof {
        try check(); return try store.companionOperationProof(effectID: effectID, tag: tag)
    }
    /// companion-v0 §9.6: complete canonical op bytes before the higher caller durably records its intent.
    /// The caller supplies already authorized args, including occurrence_due/next_due for a recurring completion.
    public func prepare(_ body: TekaStore.OpBody, effectID: String, tag: String, now: Date) throws -> Data {
        try check()
        guard body.extra.isEmpty, !state.opLog.contains(where: { $0["id"] == .string(effectID) }) else {
            throw TekaStore.Refused(reason: "the companion effect identity was already used or has extra fields")
        }
        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        var args = body.args
        if ["complete", "drop"].contains(body.op) {
            if args["next_due"] == nil, args["closed_at"] == nil { args.set("closed_at", .string(at)) }
            if args["source"] == nil { args.set("source", .string("user")) }
            if args["next_due"] == nil, args["keep_title_as"] == nil, let id = args["id"],
               let item = state.catalog["open_items"]?.arrayValue?.first(where: { $0["id"] == id })?.objectValue,
               let title = item["title"], title != .null, title.stringValue == nil {
                let final = JSONObject(item.entries.filter { !["id", "title", "kind"].contains($0.key) })
                if let key = Adoption.legacyKey("title", in: final) { args.set("keep_title_as", .string(key)) }
            }
        }
        var actor = body.actor
        if actor["client"] == nil { actor.set("client", .string(store.client)) }
        var op = JSONObject([("id", .string(effectID)), ("at", .string(at)), ("actor", .object(actor)),
            ("before_hash", .string(state.hash)), ("after_hash", .null), ("op", .string(body.op)),
            ("args", .object(args)), ("note", .string(tag))])
        try validate(op)
        let (_, hashes) = try guarded(op)
        op.set("after_hash", .string(hashes[0]))
        let bytes = Data(JSONWriter.compact(.object(op)).utf8)
        guard bytes.count <= 262144 else { throw TekaStore.Refused(reason: "the companion operation is too large") }
        return bytes
    }
    /// Apply ONLY bytes already flushed in the companion decision record, never mint or alter any op field.
    /// Returns false for a proven applied effect; aborted or stale records are refused for reauthorization.
    @discardableResult
    public func applyRecorded(_ bytes: Data) throws -> Bool {
        try check()
        guard bytes.count <= 262144 else { throw TekaStore.Refused(reason: "the companion operation is too large") }
        let parsed = try JSONParser.parse(bytes)
        guard parsed.safety.isSafe, let op = parsed.value.objectValue,
              Data(JSONWriter.compact(.object(op)).utf8) == bytes else {
            throw TekaStore.Refused(reason: "the companion operation is not the recorded canonical line")
        }
        try validate(op)
        switch try proof(effectID: op["id"]!.stringValue!, tag: op["note"]!.stringValue!) {
        case .tookEffect:
            let logged = try store.readOpLog().ops.first { $0["id"] == op["id"] }
            guard let logged, Data(JSONWriter.compact(.object(logged)).utf8) == bytes else {
                throw TekaStore.Refused(reason: "the logged companion operation differs from its record")
            }
            return false
        case .unknown: throw TekaStore.Refused(reason: "the companion operation needs a recovery decision")
        case .notApplied: break
        }
        guard op["before_hash"] == .string(state.hash) else { throw TekaStore.Refused(reason: "the binder changed since the companion decision") }
        let (catalog, hashes) = try guarded(op)
        guard op["after_hash"] == .string(hashes[0]) else { throw TekaStore.Refused(reason: "the companion operation's result differs from its record") }
        try store.write(catalog: catalog, appending: [op], expectedHash: state.hash)
        state = TekaStore.State(catalog: catalog, hash: hashes[0], opLog: state.opLog + [op])
        return true
    }
    private func guarded(_ op: JSONObject) throws -> (JSONObject, [String]) {
        guard CatalogLevel.classify(state.catalog) != .brokenStamp else { throw TekaStore.Refused(reason: "the binder's stamp needs repair before a phone action") }
        let result = try TransactionGuard.check([op], on: state.catalog, knownIDs: Set(IDMint.usedIDs(opLog: state.opLog)))
        switch CatalogLevel.classify(result.catalog) {
        case .unknown, .brokenStamp: throw TekaStore.Refused(reason: "the companion operation would leave an unsupported catalog")
        default: break
        }
        return (result.catalog, result.hashes)
    }
    private func validate(_ op: JSONObject) throws {
        guard Set(op.keys) == Set(["id", "at", "actor", "before_hash", "after_hash", "op", "args", "note"]),
              op.entries.count == 8, let id = op["id"]?.stringValue, UUID(uuidString: id)?.uuidString.lowercased() == id,
              CompanionOperationTag.isValid(op["note"]?.stringValue), op["actor"]?["kind"] == .string("user"),
              let type = op["op"]?.stringValue, let args = op["args"]?.objectValue, ItemID(args["id"]) != nil else {
            throw TekaStore.Refused(reason: "invalid companion item operation")
        }
        let keys = Set(args.keys)
        switch type {
        case "complete", "drop":
            let permitted: Set<String> = type == "complete" ? ["id", "closed_at", "source", "occurrence_due", "next_due", "keep_title_as"] :
                ["id", "closed_at", "source", "keep_title_as"]
            guard keys.isSubset(of: permitted), args["source"] == .string("user") else { throw TekaStore.Refused(reason: "invalid companion closure") }
        case "update_item":
            guard keys == ["id", "set"], let set = args["set"]?.objectValue, set.entries.count == 1,
                  let field = set.entries.first, ["due", "follow_up_at"].contains(field.key),
                  let date = field.value.stringValue, CalendarDate.strict(date) != nil else { throw TekaStore.Refused(reason: "invalid companion date update") }
        case "set_status":
            guard keys == ["id", "status"], args["status"] == .string("open") else { throw TekaStore.Refused(reason: "invalid companion status update") }
        default: throw TekaStore.Refused(reason: "this operation is not a phone item action")
        }
    }
}

extension TekaStore {
    /// companion-v0 §§9.5–9.6: settle and authorize/record/apply under one binder lock, without nesting settle().
    /// A recovery callback may classify a recorded op here; it must never reapply an unknown effect.
    public func withCompanionTransaction<T>(now: Date = Date(), _ body: (CompanionOperationTransaction) throws -> T) throws -> T {
        try withLock {
            var (catalog, hash, _) = try readCatalog()
            var log = try readOpLog().ops
            guard !log.isEmpty else { throw Refused(reason: "this binder has not been adopted") }
            try Self.refuseUnknownLevel(catalog); try Self.refuseUnknownOps(log)
            _ = try absorbOutsideEdits(catalog: catalog, hash: hash, log: log, now: now)
            (catalog, hash, _) = try readCatalog(); log = try readOpLog().ops
            guard log.last?["after_hash"] == .string(hash) else { throw Refused(reason: "the binder's recovery is unfinished") }
            let session = CompanionOperationTransaction(store: self, state: State(catalog: catalog, hash: hash, opLog: log))
            defer { session.active = false }
            return try body(session)
        }
    }
}

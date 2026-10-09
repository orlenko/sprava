import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// Absorbing what happened outside (binder-v0 §6.7): writes cut short are rolled forward or aborted, outside
/// edits recorded, and a change of the person's that another program overwrote offered again on a card.
extension TekaStore {
    public enum Absorbed: Equatable {
        case none
        case snapshotRewritten
        case rolledForward(Int)
        case aborted(Int)
        case externalEdit(revertedLastBatch: Bool)
    }

    /// Compares the catalog's hash `H` with the op log's head `a`, the trailing write's start `b` and the
    /// snapshot `S`, and records what happened outside. Returns the op lines it appended.
    func absorbOutsideEdits(catalog: JSONObject, hash H: String, log: [JSONObject], now: Date) throws -> [JSONObject]? {
        lastAbsorbed = .none
        guard let last = log.last, case .string(let a)? = last["after_hash"] else { return nil }
        let trailing = trailingWrite(log)
        let b = trailing.first?["before_hash"]?.stringValue
        let S = snapshotHash()

        if H == a {
            if S != a {
                try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: snapshotURL)
                lastAbsorbed = .snapshotRewritten
            }
            return nil
        }
        if H == b, S == b, let b {
            // A write was logged but never renamed into place: roll it forward. Ops are pure, so the result
            // has the same hash. A logged move is finished when the file is still in intake/ and the destination
            // is free, or taken as done when the destination holds the recorded digest; otherwise the write is
            // aborted (binder-v0 §6.9).
            var state = catalog
            for op in trailing { state = try OpApplier.apply(op, to: state) }
            guard try Canonical.hash(.object(state)) == a else { throw Refused(reason: "roll-forward did not reach the logged hash") }
            var moves: [(from: String, to: String, sha: String)] = []
            var possible = true
            for op in trailing where op["op"] == .str("file_document") {
                let args = op["args"]?.objectValue ?? JSONObject()
                guard let to = args["document"]?["path"]?.stringValue, let sha = args["document"]?["sha256"]?.stringValue else { continue }
                // A key or credential file is never read or moved, even for a logged write (binder-v0 §3.3), and a
                // logged path outside the filing rules is never read or moved either: the log is not sealed, so it is
                // held to the rules the guard applies (binder-v0 §4.3).
                let from = args["from"]?.stringValue
                if DocumentPaths.isKeyFile(to) || from.map(DocumentPaths.isKeyFile) == true
                    || !DocumentPaths.isSafe(to) || from.map(DocumentPaths.isIntake) == false {
                    possible = false
                    continue
                }
                let placed = DocumentPaths.plainFile(to, in: folder) && DocumentPaths.sha256(of: folder.appendingPathComponent(to)) == sha
                if let from, !placed {
                    if DocumentPaths.plainFile(from, in: folder), DocumentPaths.sha256(of: folder.appendingPathComponent(from)) == sha,
                       DocumentPaths.isFreeDestination(to, in: folder) {
                        moves.append((from, to, sha))
                    } else {
                        possible = false
                    }
                } else if !placed {
                    possible = false
                }
            }
            guard possible else {
                let stranded = restoreMoves(trailing, catalog: catalog)
                let reason = "a filed file is missing from both intake/ and its destination"
                    + (stranded.isEmpty ? "" : "; moved but not recorded: " + stranded.joined(separator: ", "))
                var abort = JSONObject()
                abort.set("id", .string(UUIDv7.make(now: now)))
                abort.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
                abort.set("actor", .obj([("kind", .str("import")), ("client", .string(client))]))
                abort.set("before_hash", .string(b))
                abort.set("after_hash", .string(b))
                abort.set("op", .str("abort"))
                abort.set("args", .obj([("ops", .array(trailing.compactMap { $0["id"] })), ("reason", .string(reason))]))
                try appendLines([abort])
                lastAbsorbed = .aborted(trailing.count)
                return [abort]
            }
            try write(catalog: state, appending: [], expectedHash: H, moves: moves)
            lastAbsorbed = .rolledForward(trailing.count)
            return nil
        }

        // Someone else edited the file (or reverted our last write). When the snapshot shows the trailing write
        // never reached the disk (S = b), an abort names its ops first and the snapshot is the expected state;
        // when it matches the head (S = a), the snapshot is the expected state; otherwise replay decides.
        var appended: [JSONObject] = []
        var expected: JSONObject
        let utc = TimeZone(identifier: "UTC")!
        let snapshot: JSONObject? = (try? Data(contentsOf: snapshotURL)).flatMap { try? JSONParser.parse($0).value.objectValue } ?? nil
        var effectiveLog = log
        if S == b, S != a, let snap = snapshot, let b {
            // The aborted write may have moved files before it stopped: they go back too.
            let stranded = restoreMoves(trailing, catalog: catalog)
            var abort = JSONObject()
            abort.set("id", .string(UUIDv7.make(now: now)))
            abort.set("at", .string(ISOTime.string(now, timeZone: utc)))
            abort.set("actor", .obj([("kind", .str("import")), ("client", .string(client))]))
            abort.set("before_hash", .string(b))
            abort.set("after_hash", .string(b))
            abort.set("op", .str("abort"))
            abort.set("args", .obj([("ops", .array(trailing.compactMap { $0["id"] })),
                                    ("reason", .string("the catalog was edited outside before this write reached the disk"
                                        + (stranded.isEmpty ? "" : "; moved but not recorded: " + stranded.joined(separator: ", "))))]))
            appended.append(abort)
            effectiveLog.append(abort)
            expected = snap
        } else if S == a, let snap = snapshot {
            expected = snap
        } else {
            expected = try Replay.run(log)
        }
        let expectedHash = try Canonical.hash(.object(expected))
        let patch = JSONPatch.diff(from: .object(expected), to: .object(catalog))
        let ambiguous = H == b && S == nil
        let reverted = H == b && S == a
        let lostOps: [JSONObject]
        if appended.isEmpty, reverted || ambiguous {
            lostOps = trailing
        } else if appended.isEmpty, let (before, since) = Self.sincePreviousExternalEdit(log) {
            // Every approved op since the previous external edit, not only the last batch: a copy saved from before
            // several approvals undoes them all (architecture 4.5).
            lostOps = Self.lostOps(found: catalog, expected: expected, before: before, ops: since)
        } else {
            lostOps = []
        }
        var args = JSONObject()
        args.set("patch", .array(patch))
        args.set("detected_at", .string(ISOTime.string(now, timeZone: utc)))
        if reverted { args.set("hint", .str("the catalog was put back as it was before the last change")) }
        else if !lostOps.isEmpty { args.set("hint", .str("a change of yours was overwritten by another program")) }
        else if let hint = Self.hint(for: patch) { args.set("hint", .string(hint)) }
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .string(ISOTime.string(now, timeZone: utc)))
        line.set("actor", .obj([("kind", .str("external")), ("client", .string(client)), ("origin", .str("unknown"))]))
        line.set("before_hash", .string(expectedHash))
        line.set("after_hash", .string(H))
        line.set("op", .str("external_edit"))
        line.set("args", .object(args))
        appended.append(line)
        // The loss is never absorbed silently (binder-v0 §6.7 step 6): a card offers the lost ops again, as the
        // person's own new ops. It is saved before the edit is recorded, so a card that cannot be saved leaves the
        // edit unrecorded and the next pass finds the loss again; a card an earlier pass saved for the same ops is
        // written over, never doubled.
        if !lostOps.isEmpty, var card = Self.reapplyCard(lostOps, client: client, now: now) {
            let lost = card.raw["provenance"]?["overwritten_ops"]
            if let earlier = ProposalStore.list(in: folder).first(where: {
                $0.0.state == "proposed" && $0.0.raw["provenance"]?["overwritten_ops"] == lost
            }) {
                card.raw.set("id", .string(earlier.0.id))
            }
            try ProposalStore.save(card, in: folder)
            if !createdProposals.contains(card.id) { createdProposals.append(card.id) }
        }
        try appendLines(appended)
        try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: snapshotURL)
        lastAbsorbed = .externalEdit(revertedLastBatch: !lostOps.isEmpty)
        return appended
    }

    /// Files a write cut short already moved go back to intake/, so its card can be approved again. A file the
    /// found catalog records stays where it is, and a key or credential file is never touched (binder-v0 §3.3).
    /// Returns the files that could not go back, for the abort to name.
    func restoreMoves(_ trailing: [JSONObject], catalog: JSONObject) -> [String] {
        let recorded = Set((catalog["documents"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue })
        var stranded: [String] = []
        for op in trailing where op["op"] == .str("file_document") {
            let args = op["args"]?.objectValue ?? JSONObject()
            guard let from = args["from"]?.stringValue, let to = args["document"]?["path"]?.stringValue,
                  let sha = args["document"]?["sha256"]?.stringValue, !recorded.contains(to),
                  !DocumentPaths.isKeyFile(from), !DocumentPaths.isKeyFile(to), DocumentPaths.isSafe(to),
                  DocumentPaths.plainFile(to, in: folder), DocumentPaths.sha256(of: folder.appendingPathComponent(to)) == sha else { continue }
            if DocumentPaths.isIntake(from), DocumentPaths.isFreeDestination(from, in: folder),
               (try? DocumentPaths.makeParents(from, in: folder)) != nil,
               renamex_np(folder.appendingPathComponent(to).path, folder.appendingPathComponent(from).path, UInt32(RENAME_EXCL)) == 0 {
                continue
            }
            stranded.append(to)
        }
        return stranded
    }

    /// "Apply again" for ops another program overwrote: the same ops as new ops by the user. An added item or a
    /// filed document gets a placeholder, because its old id was used once and is never reused; later ops that named
    /// it name the placeholder. A filing is recorded where the file already is, without `from`. When any lost op
    /// cannot be rebuilt, the card lists them all and asks for a repair by hand; it is never a part of the batch
    /// (binder-v0 §6.7 step 6).
    package static func reapplyCard(_ ops: [JSONObject], client: String, now: Date) -> Proposal? {
        var n = 0
        var renamed: [JSONValue: JSONValue] = [:]
        var rebuilt = true
        let bodies: [JSONObject] = ops.compactMap { op in
            guard let type = op["op"]?.stringValue, var args = op["args"]?.objectValue else { return nil }
            switch type {
            case "add_item":
                if var item = args["item"]?.objectValue {
                    n += 1
                    if let old = item["id"] { renamed[old] = .string("$new:\(n)") }
                    item.set("id", .string("$new:\(n)"))
                    args.set("item", .object(item))
                }
            case "file_document":
                if var document = args["document"]?.objectValue {
                    n += 1
                    document.set("id", .string("$new:\(n)"))
                    args.set("document", .object(document))
                }
                args.remove("from")
            case "update_item", "set_status", "complete", "drop":
                if let id = args["id"], let placeholder = renamed[id] { args.set("id", placeholder) }
            default:
                rebuilt = false
            }
            return JSONObject([(key: "op", value: .string(type)), (key: "args", value: .object(args))])
        }
        guard !bodies.isEmpty else { return nil }
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        var provenance = JSONObject([(key: "overwritten_ops", value: .array(ops.compactMap { $0["id"] }))])
        if !rebuilt { provenance.set("manual_repair", .bool(true)) }
        return Proposal.make(title: rebuilt ? "A change of yours was overwritten by another program. Apply it again?"
                                 : "A change of yours was overwritten by another program and cannot be applied again from here; repair it by hand, then reject this card",
                             actor: actor, ops: bodies, provenance: provenance, now: now)
    }

    /// The last complete batch, or the last single op.
    func trailingWrite(_ log: [JSONObject]) -> [JSONObject] {
        guard let last = log.last else { return [] }
        guard case .string(let batch)? = last["batch"] else { return [last] }
        return Array(log.reversed().prefix { $0["batch"]?.stringValue == batch }.reversed())
    }

    /// A likely editor named from the patch, e.g. a closure entry lifeproj's drain wrote.
    static func hint(for patch: [JSONValue]) -> String? {
        for step in patch where step["value"]?["via"]?.stringValue == "lifeproj drain" {
            return "a processing_log entry written by lifeproj drain"
        }
        return nil
    }

    /// The catalog as the previous external edit (or the adoption) left it, and the ops applied since, aborted ones
    /// left out: what an outside edit is compared with (architecture 4.5). Nil when no op followed it.
    static func sincePreviousExternalEdit(_ log: [JSONObject]) -> (JSONObject, [JSONObject])? {
        let aborted = Set(log.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        // An aborted op and its abort never took effect; the chain runs on without them.
        let effective = log.filter { $0["op"] != .str("abort") && !aborted.contains($0["id"]?.stringValue ?? "") }
        guard let start = effective.lastIndex(where: { ["external_edit", "import_snapshot"].contains($0["op"]?.stringValue ?? "") }),
              start < effective.count - 1, let before = try? Replay.run(Array(effective[...start])) else { return nil }
        return (before, Array(effective[(start + 1)...]))
    }

    /// The ops among `ops` (applied in order to `before`) whose change the outside edit put back (binder-v0 §6.7
    /// step 6): another program overwrote that part of the person's change. Replaying the ops gives every value each
    /// field and record held in the interval. A value the outside edit left that is not the last one but is one of
    /// those, the original or one in between (an editor that held a copy from halfway saved it), is a loss, and the
    /// op that last set that field is offered again. A value no op ever wrote is the other program's own change and
    /// is kept. An `update_item` is narrowed to its lost fields, so a change that survived is never written over.
    static func lostOps(found: JSONObject, expected: JSONObject, before: JSONObject, ops: [JSONObject]) -> [JSONObject] {
        // Records are compared by id, so an unrelated edit elsewhere in the same array does not hide the loss.
        func record(_ catalog: JSONObject, _ id: JSONValue) -> JSONValue? {
            for key in ["open_items", "documents"] {
                if let r = catalog[key]?.arrayValue?.first(where: { $0["id"] == id }) { return r }
            }
            return nil
        }
        func field(_ path: String) -> String { (try? JSONPatch.tokens(path))?.first ?? path }
        func paths(_ a: JSONValue, _ b: JSONValue) -> [String] { JSONPatch.diff(from: a, to: b).compactMap { $0["path"]?.stringValue } }
        // A field of a record (or, with no record, a path in the catalog): every value it held, and the op that
        // last changed it.
        struct Key: Hashable { let id: JSONValue?; let path: String }
        var values: [Key: [JSONValue?]] = [:], lastSet: [Key: Int] = [:]
        // A record's versions, and the op that last created or removed it.
        var versions: [JSONValue: [JSONValue?]] = [:], lastPresence: [JSONValue: Int] = [:]
        var touched: [[JSONValue]] = []
        func note(_ key: Key, from old: JSONValue?, to new: JSONValue?, by i: Int) {
            values[key, default: [old]].append(new)
            lastSet[key] = i
        }
        var state = before
        for (i, op) in ops.enumerated() {
            let prior = state
            guard let next = try? OpApplier.apply(op, to: prior) else { break }
            state = next
            let args = op["args"]?.objectValue ?? JSONObject()
            let ids = [args["id"], args["item"]?["id"], args["document"]?["id"]].compactMap { $0 }
            touched.append(ids)
            if ids.isEmpty {
                for path in paths(.object(prior), .object(next)) {
                    note(Key(id: nil, path: path), from: JSONPatch.value(at: path, in: .object(prior)),
                         to: JSONPatch.value(at: path, in: .object(next)), by: i)
                }
            }
            for id in ids {
                let opOld = record(prior, id), opNew = record(next, id)
                guard opOld != opNew else { continue }
                versions[id, default: [opOld]].append(opNew)
                guard let opOld, let opNew else { lastPresence[id] = i; continue }
                // Bookkeeping the op sets on its own (`updated_at`, `derived`) is no loss by itself.
                for path in paths(opOld, opNew) where !["updated_at", "derived"].contains(field(path)) {
                    note(Key(id: id, path: path), from: JSONPatch.value(at: path, in: opOld), to: JSONPatch.value(at: path, in: opNew), by: i)
                }
            }
        }

        var whole = Set<Int>()
        var fields: [Int: Set<String>] = [:]
        // A record created or removed in the interval that the outside edit took back: gone again, or back as one
        // of its earlier versions. A record that is there as it should be is judged by its fields below.
        for (id, i) in lastPresence {
            let current = record(found, id)
            if (current == nil) != (record(expected, id) == nil), versions[id]?.contains(current) == true { whole.insert(i) }
        }
        for (key, i) in lastSet {
            let holder: JSONValue?
            if let id = key.id {
                // A record the outside edit removed, or put back whole, is judged above.
                guard let current = record(found, id), let final = record(expected, id) else { continue }
                holder = current
                guard JSONPatch.value(at: key.path, in: current) != JSONPatch.value(at: key.path, in: final) else { continue }
            } else {
                holder = .object(found)
                guard JSONPatch.value(at: key.path, in: .object(found)) != JSONPatch.value(at: key.path, in: .object(expected)) else { continue }
            }
            guard let holder, values[key]?.contains(JSONPatch.value(at: key.path, in: holder)) == true else { continue }
            if key.id == nil { whole.insert(i) } else { fields[i, default: []].insert(field(key.path)) }
        }
        // Every later op on a record whose creation is offered again goes with it, under its placeholder.
        var recreated = Set<JSONValue>()
        for i in touched.indices {
            if whole.contains(i), ["add_item", "reopen", "file_document"].contains(ops[i]["op"]?.stringValue ?? "") {
                recreated.formUnion(touched[i])
            } else if !recreated.isDisjoint(with: touched[i]) {
                whole.insert(i)
            }
        }

        var lost: [JSONObject] = []
        for (i, op) in ops.enumerated() where i < touched.count {
            guard ["user", "clerk", "brain"].contains(op["actor"]?["kind"]?.stringValue ?? "") else { continue }
            // A closure whose processing_log entry is still there was not undone.
            if let opID = op["id"], found["processing_log"]?.arrayValue?.contains(where: { $0["op_id"] == opID }) == true { continue }
            if whole.contains(i) {
                lost.append(op)
            } else if let f = fields[i] {
                lost.append(op["op"] == .str("update_item") ? narrowed(op, to: f) : op)
            }
        }
        return lost
    }

    /// An `update_item` that sets and removes only `fields`, the ones another program put back. A `derived` it
    /// supplied goes with it only when every field is kept, since it names the fields the whole op derived.
    static func narrowed(_ op: JSONObject, to fields: Set<String>) -> JSONObject {
        guard var args = op["args"]?.objectValue else { return op }
        let set = args["set"]?.objectValue ?? JSONObject()
        let unset = args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !(Set(set.keys).subtracting(["derived"]).union(unset)).isSubset(of: fields) else { return op }
        args.set("set", .object(JSONObject(set.entries.filter { fields.contains($0.key) && $0.key != "derived" })))
        let keptUnset = unset.filter(fields.contains)
        if keptUnset.isEmpty { args.remove("unset") } else { args.set("unset", .array(keptUnset.map(JSONValue.string))) }
        var out = op
        out.set("args", .object(args))
        return out
    }
}

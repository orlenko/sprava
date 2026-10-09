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
        let reverted = H == b && S == a
        let lostOps: [JSONObject]
        // A catalog put back as it was before the last write is judged by the same rule as any other outside edit:
        // what it takes back is offered again only where an approval wrote it, never an outside edit's own change.
        if let (before, since) = Self.sinceAdoption(effectiveLog) {
            // Every approved op that still stands, not only the last batch: a copy saved from before several
            // approvals undoes them all, and an unrelated outside edit in between hides none of them (architecture
            // 4.5). A write just aborted is left out, through its abort in the effective log.
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
    /// it name the placeholder, a log entry's `item` or `document` included. Items and documents are renamed apart,
    /// since an item and a document may have the same id. A filing is recorded where the file already is, without
    /// `from`. A reopening reopens as a new item again. Settings and log entries are written again as they were; a
    /// privacy level, a rename or a migration is not (those go through their own cards). When any lost op cannot be
    /// rebuilt, the card lists them all and asks for a repair by hand; it is never a part of the batch (binder-v0
    /// §6.7 step 6).
    package static func reapplyCard(_ ops: [JSONObject], client: String, now: Date) -> Proposal? {
        var n = 0
        var renamed: [String: [JSONValue: JSONValue]] = ["item": [:], "document": [:]]
        var rebuilt = true
        func fresh(_ key: String, in args: inout JSONObject) {
            guard var record = args[key]?.objectValue else { return }
            n += 1
            if let old = record["id"] { renamed[key]?[old] = .string("$new:\(n)") }
            record.set("id", .string("$new:\(n)"))
            args.set(key, .object(record))
        }
        func rename(_ field: String, of object: inout JSONObject, as kind: String) {
            if let id = object[field], let placeholder = renamed[kind]?[id] { object.set(field, placeholder) }
        }
        let bodies: [JSONObject] = ops.compactMap { op in
            guard let type = op["op"]?.stringValue, var args = op["args"]?.objectValue else { return nil }
            // A loss that cannot be put back without writing over the other program's own value (lostOps).
            if op["repair_by_hand"] == .bool(true) { rebuilt = false }
            switch type {
            case "add_item":
                fresh("item", in: &args)
            case "reopen":
                rename("id", of: &args, as: "item")
                fresh("item", in: &args)
            case "file_document":
                fresh("document", in: &args)
                args.remove("from")
            case "update_item", "set_status", "complete", "drop", "dismiss", "undismiss":
                rename("id", of: &args, as: "item")
            case "update_document":
                rename("id", of: &args, as: "document")
            case "add_log_entry":
                if var entry = args["entry"]?.objectValue {
                    rename("item", of: &entry, as: "item")
                    rename("document", of: &entry, as: "document")
                    args.set("entry", .object(entry))
                }
            case "set_meta":
                break
            default:
                rebuilt = false
            }
            return JSONObject([(key: "op", value: .string(type)), (key: "args", value: .object(args))])
        }
        guard !bodies.isEmpty else { return nil }
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        // Several ops rebuilt from one lost op name it once.
        var seen = Set<JSONValue>()
        let overwritten = ops.flatMap { ($0["also_restores"]?.arrayValue ?? []) + [$0["id"]].compactMap { $0 } }.filter { seen.insert($0).inserted }
        var provenance = JSONObject([(key: "overwritten_ops", value: .array(overwritten))])
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

    /// The catalog as adopted, and every op applied since, outside edits included and aborted ones left out: what an
    /// outside edit is compared with (architecture 4.5). Nil when no op followed the adoption.
    static func sinceAdoption(_ log: [JSONObject]) -> (JSONObject, [JSONObject])? {
        let aborted = Set(log.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        // An aborted op and its abort never took effect; the chain runs on without them.
        let effective = log.filter { $0["op"] != .str("abort") && !aborted.contains($0["id"]?.stringValue ?? "") }
        guard let start = effective.lastIndex(where: { $0["op"] == .str("import_snapshot") }),
              start < effective.count - 1, let before = try? Replay.run(Array(effective[...start])) else { return nil }
        return (before, Array(effective[(start + 1)...]))
    }

    /// One place of the catalog an op can write: a field of an item or a document (`field` empty for whether the
    /// record is there at all), a processing_log entry by the op that wrote it, a meta field, or another top-level
    /// key. Bookkeeping an op sets on its own (`updated_at`, `derived`) is no place of its own.
    struct Cell: Hashable {
        let kind: String
        let id: JSONValue?
        let field: String
    }

    /// Every cell of a catalog with its value.
    static func cells(_ c: JSONObject) -> [Cell: JSONValue] {
        var out: [Cell: JSONValue] = [:]
        for e in c.entries {
            switch e.key {
            case "open_items", "documents":
                for case .object(let r) in e.value.arrayValue ?? [] {
                    guard let id = r["id"], out[Cell(kind: e.key, id: id, field: "")] == nil else { continue }
                    out[Cell(kind: e.key, id: id, field: "")] = .bool(true)
                    for f in r.entries where !["updated_at", "derived"].contains(f.key) { out[Cell(kind: e.key, id: id, field: f.key)] = f.value }
                }
            case "processing_log":
                for entry in e.value.arrayValue ?? [] {
                    if let op = entry["op_id"], op != .null, out[Cell(kind: e.key, id: op, field: "")] == nil {
                        out[Cell(kind: e.key, id: op, field: "")] = entry
                    }
                }
            case "meta":
                if case .object(let meta) = e.value {
                    for f in meta.entries { out[Cell(kind: "meta", id: nil, field: f.key)] = f.value }
                } else {
                    out[Cell(kind: "top", id: nil, field: "meta")] = e.value
                }
            default:
                out[Cell(kind: "top", id: nil, field: e.key)] = e.value
            }
        }
        return out
    }

    /// `cells(c)`, from the cells of `prior` (`flat`), looking again only at the top-level keys, records and log
    /// entries that differ, and the cells it looked at (every cell whose value differs is among them): a replay of a
    /// long log stays linear in what each op changes.
    static func cells(_ c: JSONObject, after prior: JSONObject, were flat: [Cell: JSONValue]) -> ([Cell: JSONValue], Set<Cell>) {
        var out = flat
        var looked = Set<Cell>()
        func put(_ cell: Cell, _ value: JSONValue?) {
            out[cell] = value
            looked.insert(cell)
        }
        func byID(_ v: JSONValue?, _ idKey: String) -> [JSONValue: JSONObject] {
            var d: [JSONValue: JSONObject] = [:]
            for case .object(let o) in v?.arrayValue ?? [] {
                guard let id = o[idKey], idKey == "id" || id != .null, d[id] == nil else { continue }
                d[id] = o
            }
            return d
        }
        for key in Set(prior.keys).union(c.keys) where prior[key] != c[key] {
            switch key {
            case "open_items", "documents":
                let old = byID(prior[key], "id"), new = byID(c[key], "id")
                for (id, r) in old where new[id] != r {
                    put(Cell(kind: key, id: id, field: ""), nil)
                    for f in r.keys where !["updated_at", "derived"].contains(f) { put(Cell(kind: key, id: id, field: f), nil) }
                }
                for (id, r) in new where old[id] != r {
                    put(Cell(kind: key, id: id, field: ""), .bool(true))
                    for f in r.entries where !["updated_at", "derived"].contains(f.key) { put(Cell(kind: key, id: id, field: f.key), f.value) }
                }
            case "processing_log":
                let old = byID(prior[key], "op_id"), new = byID(c[key], "op_id")
                for id in old.keys where new[id] == nil { put(Cell(kind: key, id: id, field: ""), nil) }
                for (id, entry) in new where old[id] != entry { put(Cell(kind: key, id: id, field: ""), .object(entry)) }
            case "meta":
                for f in prior["meta"]?.objectValue?.keys ?? [] { put(Cell(kind: "meta", id: nil, field: f), nil) }
                put(Cell(kind: "top", id: nil, field: "meta"), nil)
                if case .object(let meta)? = c["meta"] {
                    for f in meta.entries { put(Cell(kind: "meta", id: nil, field: f.key), f.value) }
                } else if let v = c["meta"] {
                    put(Cell(kind: "top", id: nil, field: "meta"), v)
                }
            default:
                put(Cell(kind: "top", id: nil, field: key), c[key])
            }
        }
        return (out, looked)
    }

    /// The ops that put back what an outside edit took from the approved ops among `ops` (applied in order to
    /// `before`, outside edits included) (binder-v0 §6.7 step 6), each carrying the `id` and actor of the op whose
    /// effect it restores. One rule for every place the ops write, judged place by place: replaying them gives every
    /// value each cell held since the last outside edit that changed that cell, or since adoption. An outside edit
    /// elsewhere does not end it. A cell whose found value differs from the latest approved one is a loss when the
    /// found value is one of those, the first or one in between (an editor held a copy from before or halfway), or
    /// when it is missing where an approved op left a value. A present value none of them is, is the other
    /// program's own change and is kept; so is a cell an outside edit wrote last.
    ///
    /// A lost field of a record that is still there is put back by itself, to its approved value, so nothing else
    /// on the record is written: `update_item`, `set_status`, `dismiss` or `undismiss` for an item, `update_document`
    /// for a document, `set_meta` for a meta field. A record the interval created that is gone takes every op on it
    /// along, in order; a closure or log entry that is gone brings its op back whole, with the fields the closure saw
    /// put back first. What cannot be put back that way without writing over the other program's own value is
    /// marked `repair_by_hand`, and the card then asks for a repair by hand.
    static func lostOps(found: JSONObject, expected: JSONObject, before: JSONObject, ops: [JSONObject]) -> [JSONObject] {
        struct Record: Hashable { let kind: String; let id: JSONValue? }
        var values: [Cell: [JSONValue?]] = [:], setters: [Cell: [Int]] = [:]
        var created: [Record: Int] = [:]
        var touched: [Set<Record>] = []
        // The fields of a record that stays, and the meta and other keys, each op wrote; and what each op that closed
        // a record saw in it.
        var rewrote: [Int: [Cell]] = [:]
        var closed: [Int: [Record: [String: JSONValue]]] = [:]
        var state = before, flat = cells(before)
        for (i, op) in ops.enumerated() {
            guard let next = try? OpApplier.apply(op, to: state) else { break }
            let (flatNext, looked) = cells(next, after: state, were: flat)
            var records = Set<Record>()
            if op["op"] == .str("external_edit") {
                // A cell an outside edit changed starts its history again from the value it left; no approval before
                // that counts for it any more, and a record it made or removed was not made by an approved op.
                for cell in looked where flat[cell] != flatNext[cell] {
                    values[cell] = [flatNext[cell]]
                    setters[cell] = []
                    if cell.field.isEmpty { created[Record(kind: cell.kind, id: cell.id)] = nil }
                }
                touched.append(records)
                state = next
                flat = flatNext
                continue
            }
            for cell in looked where flat[cell] != flatNext[cell] {
                values[cell, default: [flat[cell]]].append(flatNext[cell])
                setters[cell, default: []].append(i)
                switch cell.kind {
                case "open_items", "documents":
                    let record = Record(kind: cell.kind, id: cell.id)
                    let presence = Cell(kind: cell.kind, id: cell.id, field: "")
                    records.insert(record)
                    if cell.field.isEmpty {
                        if flat[cell] == nil { created[record] = i }
                    } else if flatNext[presence] == nil {
                        if let old = flat[cell] { closed[i, default: [:]][record, default: [:]][cell.field] = old }
                    } else if flat[presence] != nil {
                        rewrote[i, default: []].append(cell)
                    }
                case "meta", "top":
                    rewrote[i, default: []].append(cell)
                default:
                    break
                }
            }
            touched.append(records)
            state = next
            flat = flatNext
        }

        let foundCells = cells(found), expectedCells = cells(expected)
        // A present value no op wrote in the interval: the other program's own, never written over.
        func own(_ cell: Cell) -> Bool {
            guard let now = foundCells[cell] else { return false }
            return values[cell]?.contains(now) != true
        }
        func present(_ kind: String, _ id: JSONValue?, in c: [Cell: JSONValue]) -> Bool { c[Cell(kind: kind, id: id, field: "")] != nil }
        var whole = Set<Int>(), byHand = Set<Int>()
        // Fields to put back, at the op that last wrote them: record (or meta) → field → value, nil to remove it.
        var restore: [Int: [Record: [String: JSONValue?]]] = [:]
        for (cell, setBy) in setters {
            guard let i = setBy.last else { continue }
            let final = expectedCells[cell]
            guard foundCells[cell] != final, !own(cell) else { continue }
            switch cell.kind {
            case "open_items", "documents":
                if cell.field.isEmpty {
                    // A record the ops created is gone again, or one they closed is open again: its closure goes back
                    // whole, unless the found log still closes it (the copy kept an earlier closure of it).
                    if final != nil {
                        whole.insert(i)
                    } else if found["processing_log"]?.arrayValue?.contains(where: { $0["id"] == cell.id }) != true {
                        whole.insert(i)
                    }
                } else if present(cell.kind, cell.id, in: foundCells), present(cell.kind, cell.id, in: expectedCells),
                          cell.field != "created_at" {
                    restore[i, default: [:]][Record(kind: cell.kind, id: cell.id), default: [:]][cell.field] = final
                } else if present(cell.kind, cell.id, in: expectedCells), created[Record(kind: cell.kind, id: cell.id)] == nil {
                    // A record from before the interval that the other program removed, with approved changes on it:
                    // it cannot come back under its id from a card, so the change is repaired by hand.
                    whole.insert(i)
                    byHand.insert(i)
                }
            case "meta":
                restore[i, default: [:]][Record(kind: "meta", id: nil), default: [:]][cell.field] = final
            case "processing_log":
                whole.insert(i)
            default:
                whole.insert(i)
                byHand.insert(i)
            }
        }
        // A record the interval created that is gone now: every op on it goes with any of them that is offered.
        var gone = Set(created.keys.filter { !present($0.kind, $0.id, in: foundCells) })
        var grew = true
        while grew {
            grew = false
            for i in touched.indices where whole.contains(i) || restore[i] != nil {
                let linked = touched[i].intersection(gone)
                guard !linked.isEmpty else { continue }
                gone.subtract(linked)
                for j in touched.indices where !whole.contains(j) && !touched[j].isDisjoint(with: linked) {
                    whole.insert(j)
                    grew = true
                }
            }
        }
        // A closure offered again records the item as it is then: a field the closure saw that the found copy holds
        // an earlier state of, or lacks, is put back first, at the op that last wrote it.
        for i in whole.sorted() {
            for (record, seen) in closed[i] ?? [:] where present(record.kind, record.id, in: foundCells) {
                let names = Set(seen.keys).union(foundCells.keys.filter { $0.kind == record.kind && $0.id == record.id && !$0.field.isEmpty }.map(\.field))
                for name in names where name != "created_at" {
                    let cell = Cell(kind: record.kind, id: record.id, field: name)
                    guard foundCells[cell] != seen[name], !own(cell),
                          let j = setters[cell]?.last(where: { $0 < i }), !whole.contains(j) else { continue }
                    restore[j, default: [:]][record, default: [:]][name] = seen[name]
                }
            }
        }
        // An op made again whole writes every field it wrote before: never over the other program's own value.
        for i in whole where (rewrote[i] ?? []).contains(where: own) { byHand.insert(i) }

        var lost: [JSONObject] = []
        // The fields of one record put back together, so the record is valid after the one op that writes them all,
        // up to the next op made again whole; each op whose effect it restores is named on the card.
        var pending: [(record: Record, fields: [String: JSONValue?], ops: [JSONObject])] = []
        func flush() {
            for p in pending {
                for body in restoring(p.record.kind, p.record.id, p.fields, found: foundCells) {
                    var line = body
                    line.set("id", p.ops.last?["id"] ?? .null)
                    line.set("actor", p.ops.last?["actor"] ?? .null)
                    if p.ops.count > 1 { line.set("also_restores", .array(p.ops.dropLast().compactMap { $0["id"] })) }
                    lost.append(line)
                }
            }
            pending.removeAll()
        }
        for (i, op) in ops.enumerated() where i < touched.count {
            guard ["user", "clerk", "brain"].contains(op["actor"]?["kind"]?.stringValue ?? "") else { continue }
            if whole.contains(i) {
                flush()
                var line = op
                // A closure of an item that is not open as found, and that no op of this card makes again: closed
                // already (by an earlier closure the copy kept), nothing to do; otherwise it cannot be made again.
                if ["complete", "drop"].contains(op["op"]?.stringValue ?? ""), op["args"]?["next_due"] == nil,
                   let id = op["args"]?["id"], !present("open_items", id, in: foundCells),
                   !whole.contains(where: { created[Record(kind: "open_items", id: id)] == $0 }) {
                    if found["processing_log"]?.arrayValue?.contains(where: { $0["id"] == id }) == true { continue }
                    line.set("repair_by_hand", .bool(true))
                }
                if byHand.contains(i) { line.set("repair_by_hand", .bool(true)) }
                lost.append(line)
                continue
            }
            let records = (restore[i] ?? [:]).sorted { ($0.key.kind, canonicalText($0.key.id ?? .null)) < ($1.key.kind, canonicalText($1.key.id ?? .null)) }
            for (record, fields) in records {
                if let k = pending.firstIndex(where: { $0.record == record }) {
                    pending[k].fields.merge(fields) { _, new in new }
                    pending[k].ops.append(op)
                } else {
                    pending.append((record, fields, [op]))
                }
            }
        }
        flush()
        return lost
    }

    /// The ops that put the given fields of one record, or of meta (`kind` "meta"), back to their approved values
    /// (nil removes a field), touching nothing else on it: what they would do is tried on the record as found, and
    /// ops that would write any other field, or not reach those values, ask for a repair by hand instead. A status
    /// goes back through `set_status` with the waiting fields it carries, and with those that survived as found, so
    /// that `open`, which removes the waiting fields it is not given, removes none.
    static func restoring(_ kind: String, _ id: JSONValue?, _ fields: [String: JSONValue?], found: [Cell: JSONValue]) -> [JSONObject] {
        func op(_ type: String, _ args: [(String, JSONValue)]) -> JSONObject {
            JSONObject([(key: "op", value: .string(type)), (key: "args", value: .obj(args))])
        }
        func setAndUnset(_ f: [String: JSONValue?]) -> [(String, JSONValue)] {
            let keys = f.keys.sorted()
            let set: [(String, JSONValue)] = keys.compactMap { k in f[k].flatMap { $0 }.map { (k, $0) } }
            let unset = keys.filter { f[$0] == .some(nil) }
            return (set.isEmpty ? [] : [("set", .obj(set))]) + (unset.isEmpty ? [] : [("unset", .array(unset.map(JSONValue.string)))])
        }
        func foundValue(_ field: String) -> JSONValue? { found[Cell(kind: kind, id: id, field: field)] }
        var target = fields
        target.removeValue(forKey: "id")
        var rest = target
        var out: [JSONObject] = []
        switch kind {
        case "open_items":
            let id = id ?? .null
            let waiting = ["waiting_on", "follow_up_at", "expected_by"]
            if let status = rest.removeValue(forKey: "status") {
                var args: [(String, JSONValue)] = [("id", id), ("status", status ?? .null)]
                for w in waiting {
                    if let value = rest.removeValue(forKey: w) {
                        // A waiting field put back with the status; one to remove is removed by `open` itself, or by
                        // update_item below.
                        if let value { args.append((w, value)) } else if status != .str("open") { rest[w] = .some(nil) }
                    } else if let kept = foundValue(w) {
                        args.append((w, kept))
                    }
                }
                out.append(op("set_status", args))
            }
            if let dismissed = rest.removeValue(forKey: "dismissed") {
                out.append(op(dismissed == .bool(true) ? "dismiss" : "undismiss", [("id", id)]))
            }
            if !rest.isEmpty { out.append(op("update_item", [("id", id)] + setAndUnset(rest))) }
        case "documents":
            if !rest.isEmpty { out.append(op("update_document", [("id", id ?? .null)] + setAndUnset(rest))) }
        default:
            if !rest.isEmpty { out.append(op("set_meta", setAndUnset(rest))) }
        }
        guard !out.isEmpty else { return [] }

        // Tried on the record as found, alone with the binder's settings: every field must end as it was or as asked,
        // and the record must be valid afterwards, as the guard will require of it.
        var record = JSONObject(), meta = JSONObject()
        for (cell, value) in found where cell.kind == kind && cell.id == id && !cell.field.isEmpty { record.set(cell.field, value) }
        for (cell, value) in found where cell.kind == "meta" { meta.set(cell.field, value) }
        var trial = kind == "meta" ? JSONObject([(key: "meta", value: .object(record))])
            : JSONObject([(key: "meta", value: .object(meta)), (key: kind, value: .array([.object(record)]))])
        var exact = true
        for body in out {
            var line = body
            line.set("id", .str("trial"))
            line.set("at", .str("2000-01-01T00:00:00Z"))
            line.set("actor", .obj([("kind", .str("user")), ("client", .str("trial"))]))
            guard let next = try? OpApplier.apply(line, to: trial) else { exact = false; break }
            trial = next
        }
        if exact {
            let after = cells(trial)
            let names = Set(record.keys).union(after.keys.filter { $0.kind == kind && $0.id == id && !$0.field.isEmpty }.map(\.field))
            exact = names.allSatisfy { name in
                after[Cell(kind: kind, id: id, field: name)] == (target[name] ?? foundValue(name))
            }
            if kind != "meta", let id {
                exact = exact && !TransactionGuard.violations(trial).contains { $0.array == kind && $0.recordKey == canonicalText(id) }
            }
        }
        return exact ? out : out.map { var o = $0; o.set("repair_by_hand", .bool(true)); return o }
    }
}

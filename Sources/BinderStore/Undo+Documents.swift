import Foundation
import SpravaKit

/// The undo of a change to a document record (binder-v0 §6.10): `update_document` again, restoring the earlier values.
extension Undo {
    /// The document field the privacy ratchet watches (architecture 4.5).
    static let documentPrivacyFields: Set<String> = ["sensitivity"]

    /// The compensating `update_document` for `target`, field by field as an item's edit is undone: a field changed
    /// since keeps its newer value and is reported in `kept`, and the op carries `expect` for the fields it restores,
    /// so the guard refuses it when one changed under it. It is refused whole:
    /// - when no field is left to restore;
    /// - when the record changed since and the undo would touch its `sensitivity`, or `sensitivity` itself changed
    ///   since, so a restored value never meets a looser privacy state than it had;
    /// - when it would leave the record without a `title` or a `path`, which a record always has (binder-v0 §4.3).
    /// A restored `path` is checked as any recorded path is, when the op is applied: the file must be there.
    static func documentCompensation(_ target: JSONObject, catalog: JSONObject, opLog: [JSONObject], stateBefore: JSONObject,
                                     stateAfter: JSONObject?) throws -> Compensation {
        let args = target["args"]?.objectValue ?? JSONObject()
        func document(_ c: JSONObject, _ id: JSONValue) -> JSONObject? {
            c["documents"]?.arrayValue?.first { $0["id"] == id }?.objectValue
        }
        guard let id = args["id"], let before = document(stateBefore, id) else {
            throw Unsupported(message: "the document's earlier state is unknown")
        }
        guard let current = document(catalog, id) else { throw Unsupported(message: "the document is no longer in the catalog") }
        // The record as the undone op left it; without `stateAfter`, as it is now.
        let then = document(stateAfter ?? catalog, id)
        // The record's fields any later op wrote, even one set back to the value the undone op left. Nil when the log
        // after the target cannot be stepped through, which counts as every field changed.
        let later: Set<String>? = stateAfter.flatMap { after in
            opLog.firstIndex { $0["id"] == target["id"] }.flatMap { writes(after: $0, in: opLog, from: after, item: id, list: "documents") }
        } ?? (stateAfter == nil ? [] : nil)
        func changedSince(_ fields: [String]) -> [String] {
            fields.filter { current[$0] != then?[$0] || later?.contains($0) ?? true }
        }
        var fields: [String] = []
        for name in (args["set"]?.objectValue?.keys ?? []) + (args["unset"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        where !fields.contains(name) {
            fields.append(name)
        }
        let recordChanged = current != then || !(later?.isEmpty ?? false)
        if recordChanged, !documentPrivacyFields.isDisjoint(with: fields) || !changedSince(documentPrivacyFields.sorted()).isEmpty {
            throw Unsupported(message: "the document changed since and this undo touches its sensitivity; edit it instead")
        }
        let kept = changedSince(fields)
        let restoring = fields.filter { !kept.contains($0) }
        guard !restoring.isEmpty else { throw Unsupported(message: "\(kept.joined(separator: ", ")) changed since; edit it instead") }
        var restore = JSONObject()
        var remove: [String] = []
        for key in restoring {
            if let old = before[key] { if current[key] != old { restore.set(key, old) } } else if current[key] != nil { remove.append(key) }
        }
        if let needed = remove.first(where: { $0 == "title" || $0 == "path" }) {
            throw Unsupported(message: "the record had no \(needed) before this change, and a record needs one; edit it instead")
        }
        guard !restore.entries.isEmpty || !remove.isEmpty else {
            throw Unsupported(message: "this change left the record as it was, so there is nothing to undo")
        }
        var undo = JSONObject([(key: "id", value: id)])
        if !restore.entries.isEmpty { undo.set("set", .object(restore)) }
        if !remove.isEmpty { undo.set("unset", .array(remove.map(JSONValue.string))) }
        // What the compensating op assumes: each restored field as the undone op left it, or absent.
        var set = JSONObject(), absent: [JSONValue] = []
        for field in restoring { if let value = then?[field] { set.set(field, value) } else { absent.append(.string(field)) } }
        var expect = JSONObject()
        if !set.entries.isEmpty { expect.set("set", .object(set)) }
        if !absent.isEmpty { expect.set("absent", .array(absent)) }
        return Compensation(op: "update_document", args: undo, expect: expect.entries.isEmpty ? nil : expect, kept: kept)
    }

    /// The undo of a filing recorded where the file already was (`file_document` without `from`): `unfile_document`
    /// in place, which removes the record and leaves the file where it is, an ordinary file of the binder as it was
    /// before (binder-v0 §6.10). Nothing is held, since automatic filing reads only intake/. Refused when the filing
    /// took the file from intake/ (returning it there needs the intake hold), when the record is gone, and when the
    /// record changed since the filing: it is not as the filing left it, or a later change wrote to it that was not
    /// undone, even one that put the same values back, or the history cannot say. Such a record holds the person's
    /// later choice; that change is undone first, or the record is corrected by hand.
    static func filingCompensation(_ target: JSONObject, catalog: JSONObject, opLog: [JSONObject], stateAfter: JSONObject) throws -> Compensation {
        let args = target["args"]?.objectValue ?? JSONObject()
        guard args["from"] == nil else {
            throw Unsupported(message: "this filing took the file from intake/, and this version cannot return it there; correct or move the document instead")
        }
        guard let id = args["document"]?["id"] else { throw Unsupported(message: "no document id") }
        let records = (catalog["documents"]?.arrayValue ?? []).filter { $0["id"] == id }
        guard records.count == 1, case .object(let record) = records[0] else { throw Unsupported(message: "the document's record is gone") }
        let changed = Unsupported(message: "the record changed since the document was filed; correct it instead")
        guard stateAfter["documents"]?.arrayValue?.first(where: { $0["id"] == id }) == .object(record) else { throw changed }
        guard let index = opLog.firstIndex(where: { $0["id"] == target["id"] }),
              let later = writes(after: index, in: opLog, from: stateAfter, item: id, list: "documents"), later.isEmpty else { throw changed }
        guard case .string(let path)? = record["path"], case .string(let sha)? = record["sha256"] else {
            throw Unsupported(message: "the record has no path and digest to check its file by")
        }
        let unfile = JSONObject([(key: "id", value: id), (key: "from", value: .string(path)), (key: "sha256", value: .string(sha)),
                                 (key: "document", value: .object(record))])
        return Compensation(op: "unfile_document", args: unfile, expect: nil, kept: [])
    }
}

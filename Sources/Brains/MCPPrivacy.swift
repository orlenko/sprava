import BinderFormat
import BinderStore
import Capture
import Foundation
import Shelf
import SpravaKit

/// Document-level privacy for what a brain reads (architecture 7.3; the privacy ratchet, 4.5). A careful reading is
/// the text of a file in a binder: a brain never sees it, or its title or summary, once the file is private, as
/// filed, as last confirmed by Sprava, or as its filing card says. The binder's disclosure (`visible`) is the ceiling
/// above this; this is the rule for one document.
extension MCPServer {
    /// A `sensitivity` that keeps a document from brains: any value but `unmarked`, so an unknown one reads as
    /// private (capture-event-v0 §3.3). An absent or null marker is no marker.
    static func isPrivate(_ sensitivity: JSONValue?) -> Bool {
        guard let sensitivity, sensitivity != .null else { return false }
        return sensitivity.stringValue != "unmarked"
    }

    /// The documents of one binder a brain may not read, by digest and by path (folded).
    struct PrivateDocuments {
        var digests: Set<String> = []
        var paths: Set<String> = []

        func covers(_ e: IntakeReadings.Entry) -> Bool {
            digests.contains(e.sha256.lowercased()) || paths.contains(DocumentPaths.fold("intake/" + e.name))
        }
    }

    /// The private documents of a binder: those its catalog marks private now (a narrowing counts at once), and those
    /// Sprava last applied as private (a widening an outside edit made waits for the person: only the person's own
    /// op lowers a marker). Nil when the op log cannot be read: then nothing in the binder is shown.
    static func privateDocuments(catalog: JSONObject?, folder: URL) -> PrivateDocuments? {
        guard let ops = try? TekaStore(folder: folder).readOpLog().ops else { return nil }
        return privateDocuments(catalog: catalog, ops: ops)
    }

    static func privateDocuments(catalog: JSONObject?, ops: [JSONObject]) -> PrivateDocuments {
        func key(_ id: JSONValue?) -> String? { id.flatMap { try? Canonical.serialize($0) } }
        // Every digest and path each document id has had, from the catalog and the log.
        var digests: [String: Set<String>] = [:]
        var paths: [String: Set<String>] = [:]
        func note(_ id: String, _ doc: JSONValue?, from: JSONValue? = nil) {
            if let sha = doc?["sha256"]?.stringValue { digests[id, default: []].insert(sha.lowercased()) }
            for p in [doc?["path"], from].compactMap({ $0?.stringValue }) { paths[id, default: []].insert(DocumentPaths.fold(p)) }
        }
        var marked = Set<String>()   // private as found in the catalog
        for doc in catalog?["documents"]?.arrayValue ?? [] {
            guard let k = key(doc["id"]) else { continue }
            note(k, doc)
            if isPrivate(doc["sensitivity"]) { marked.insert(k) }
        }
        // As Sprava last applied it: from the latest import_snapshot, skipping aborted ops; an external_edit never counts.
        var confirmed = Set<String>()
        let start = ops.lastIndex { $0["op"] == .str("import_snapshot") } ?? 0
        let aborted = Set(ops.filter { $0["op"] == .str("abort") }.flatMap { $0["args"]?["ops"]?.arrayValue ?? [] }.compactMap(\.stringValue))
        for (i, op) in ops.enumerated() where i >= start && !aborted.contains(op["id"]?.stringValue ?? "") {
            let args = op["args"]
            switch op["op"]?.stringValue {
            case "import_snapshot"?:
                for doc in args?["catalog"]?["documents"]?.arrayValue ?? [] {
                    guard let k = key(doc["id"]) else { continue }
                    note(k, doc)
                    if isPrivate(doc["sensitivity"]) { confirmed.insert(k) }
                }
            case "file_document"?:
                guard let k = key(args?["document"]?["id"]) else { continue }
                note(k, args?["document"], from: args?["from"])
                if isPrivate(args?["document"]?["sensitivity"]) { confirmed.insert(k) }
            case "update_document"?:
                guard let k = key(args?["id"]) else { continue }
                note(k, args?["set"])
                let set = args?["set"]?.objectValue
                if let s = set?["sensitivity"], isPrivate(s) {
                    confirmed.insert(k)
                } else if op["actor"]?["kind"] == .str("user"),
                          set?["sensitivity"] != nil || args?["unset"]?.arrayValue?.contains(.str("sensitivity")) == true {
                    confirmed.remove(k)
                }
            default:
                break
            }
        }
        var out = PrivateDocuments()
        for k in marked.union(confirmed) {
            out.digests.formUnion(digests[k] ?? [])
            out.paths.formUnion(paths[k] ?? [])
        }
        return out
    }

    /// Whether the filing card a reading belongs to keeps it from brains: a card that is not as Sprava last wrote it,
    /// one that no longer waits and was not approved, one marked private (a private capture, or a raise to private),
    /// or one that files any document as private.
    func cardWithholds(_ e: IntakeReadings.Entry, in folder: URL) -> Bool {
        guard let card = try? commands.loadTrusted(e.card, in: folder), ["proposed", "applied"].contains(card.state) else { return true }
        if card.raw["provenance"]?["private"] == .bool(true) { return true }
        return card.ops.contains { Self.isPrivate($0["args"]?["document"]?["sensitivity"]) }
    }

    /// Whether a reading may be shown to a brain at all, given its binder's private documents (nil: unknown, so no).
    func mayShow(_ e: IntakeReadings.Entry, in row: ShelfRow, privacy: PrivateDocuments?) -> Bool {
        guard let privacy, !privacy.covers(e) else { return false }
        return !cardWithholds(e, in: row.folder)
    }
}

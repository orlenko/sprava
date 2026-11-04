import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Recognising a file in intake that is already filed, by its exact bytes. Anything less exact (the same email saved
/// another way) is not decided here: such a file still gets a card. A file left out stays in intake; nothing is deleted.
extension IntakeWatcher {
    /// By digest, the path of each filed document: as its record says, or as `unrecorded` found for a record with none.
    static func filedDigests(_ catalog: JSONObject?, unrecorded: [String: String]) -> [String: [String]] {
        var filed = unrecorded.mapValues { [$0] }
        for doc in catalog?["documents"]?.arrayValue ?? [] {
            guard let digest = doc["sha256"]?.stringValue, let path = doc["path"]?.stringValue else { continue }
            filed[digest, default: []].append(path)
        }
        return filed
    }

    /// Digests of filed documents whose records carry none (an adopted binder's need not), hashed only when a file in
    /// intake has the same size: most never do. A catalog's path is untrusted, so it is checked as any other.
    static func unrecordedDigests(_ row: ShelfRow, candidates: [Candidate]) -> [String: String] {
        let manager = FileManager.default
        var sizes = Set<Int>()
        for candidate in candidates {
            for name in [candidate.name] + candidate.attachments {
                let path = row.folder.appendingPathComponent("intake/" + name).path
                if let size = (try? manager.attributesOfItem(atPath: path))?[.size] as? Int { sizes.insert(size) }
            }
        }
        guard !sizes.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for doc in row.teka.catalog?["documents"]?.arrayValue ?? [] where doc["sha256"] == nil {
            guard let path = doc["path"]?.stringValue, usable(path, in: row.folder),
                  let size = (try? manager.attributesOfItem(atPath: row.folder.appendingPathComponent(path).path))?[.size] as? Int,
                  sizes.contains(size), let digest = DocumentPaths.sha256(of: row.folder.appendingPathComponent(path)) else { continue }
            out[digest] = path
        }
        return out
    }

    private static func usable(_ path: String, in folder: URL) -> Bool {
        DocumentPaths.isSafe(path, forFiling: false) && !DocumentPaths.isKeyFile(path) && DocumentPaths.plainFile(path, in: folder)
    }

    /// Whether this digest names a document whose file is still there: a record alone would hide the only copy left.
    private static func holds(_ digest: String?, filed: [String: [String]], in folder: URL) -> Bool {
        digest.flatMap { filed[$0] }?.contains { usable($0, in: folder) } ?? false
    }

    /// Whether a thing in intake is already filed: every file it would file, or for a message its original, which holds
    /// all the rest. Names are relative to `intake/`. A key or credential file is never read, so it never decides.
    static func isFiled(names: [String], filed: [String: [String]], in folder: URL, digest: (String) -> String?) -> Bool {
        let fileable = names.filter { !DocumentPaths.isKeyFile($0) }
        guard !fileable.isEmpty else { return false }
        if let original = fileable.first(where: { ($0 as NSString).lastPathComponent == mailOriginalName }),
           holds(digest(original), filed: filed, in: folder) { return true }
        return fileable.allSatisfy { holds(digest($0), filed: filed, in: folder) }
    }

    /// The same, from the digests a card recorded when it was written.
    static func isFiled(card: Proposal, filed: [String: [String]], in folder: URL) -> Bool {
        var digests: [String: String] = [:]
        for op in card.ops where op["op"] == .str("file_document") {
            guard let from = op["args"]?["from"]?.stringValue, from.hasPrefix("intake/"),
                  let digest = op["args"]?["document"]?["sha256"]?.stringValue else { return false }
            digests[String(from.dropFirst("intake/".count))] = digest
        }
        return isFiled(names: Array(digests.keys).sorted(), filed: filed, in: folder) { digests[$0] }
    }

    /// The files of this binder's intake left out of review, as `intake/...` paths, in a stable order.
    package func copies(in folder: URL) -> [String] {
        guard let seen = (try? load())?[folder.standardizedFileURL.path] else { return [] }
        return seen.filter { $0.value.copy == true }.keys.sorted().map { "intake/" + $0 }
    }
}

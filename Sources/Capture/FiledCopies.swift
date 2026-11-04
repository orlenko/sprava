import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Recognising a file in intake that is already filed, by its exact bytes. Anything less exact (the same email saved
/// another way) is not decided here: such a file still gets a card. A file left out stays in intake; nothing is deleted.
extension IntakeWatcher {
    /// What filed documents hold now, by digest: a record's own digest may be out of date, and may be missing from an
    /// adopted binder's. Only a file of the same size as one in intake is hashed, and most have none. An empty file
    /// says nothing about what a document is, so it never matches. A catalog's path is untrusted and checked as any other.
    static func filedDigests(_ row: ShelfRow, candidates: [Candidate]) -> [String: String] {
        let manager = FileManager.default
        func size(_ url: URL) -> Int? { (try? manager.attributesOfItem(atPath: url.path))?[.size] as? Int }
        var sizes = Set<Int>()
        for candidate in candidates {
            for name in [candidate.name] + candidate.attachments {
                if let found = size(row.folder.appendingPathComponent("intake/" + name)), found > 0 { sizes.insert(found) }
            }
        }
        guard !sizes.isEmpty else { return [:] }
        var out: [String: String] = [:]
        for path in Set((row.teka.catalog?["documents"]?.arrayValue ?? []).compactMap({ $0["path"]?.stringValue })) {
            guard DocumentPaths.isSafe(path, forFiling: false), !DocumentPaths.isKeyFile(path),
                  DocumentPaths.plainFile(path, in: row.folder) else { continue }
            let url = row.folder.appendingPathComponent(path)
            if let found = size(url), sizes.contains(found), let digest = DocumentPaths.sha256(of: url) { out[digest] = path }
        }
        return out
    }

    /// Whether a thing in intake is already filed: every file it would file. A message's text may be rendered another
    /// way, so with its original filed that text does not count; any other file beside them still does. `names` are
    /// relative to `intake/`. A key or credential file is never read, so it never decides.
    static func isFiled(names: [String], filed: [String: String], digest: (String) -> String?) -> Bool {
        let fileable = names.filter { !DocumentPaths.isKeyFile($0) }
        guard !fileable.isEmpty else { return false }
        func holds(_ name: String) -> Bool { digest(name).map { filed[$0] != nil } ?? false }
        // `mail/x attachments/000-original-message.eml` is the original of `mail/x.md`, and of nothing else.
        let folder = fileable.first { ($0 as NSString).lastPathComponent == mailOriginalName && holds($0) }
            .map { ($0 as NSString).deletingLastPathComponent }
        return fileable.allSatisfy { name in
            let text = (name as NSString).deletingPathExtension + " attachments"
            return text == folder || holds(name)
        }
    }

    /// The same, from the digests a card recorded when it was written.
    static func isFiled(card: Proposal, filed: [String: String]) -> Bool {
        var names: [String] = [], digests: [String: String] = [:]
        for op in card.ops where op["op"] == .str("file_document") {
            guard let from = op["args"]?["from"]?.stringValue, from.hasPrefix("intake/"),
                  let digest = op["args"]?["document"]?["sha256"]?.stringValue else { return false }
            let name = String(from.dropFirst("intake/".count))
            names.append(name)
            digests[name] = digest
        }
        return isFiled(names: names, filed: filed) { digests[$0] }
    }

    /// The files of this binder's intake left out of review, as `intake/...` paths, in a stable order.
    package func copies(in folder: URL) -> [String] {
        guard let seen = (try? load())?[folder.standardizedFileURL.path] else { return [] }
        return seen.filter { $0.value.copy == true }.keys.sorted().map { "intake/" + $0 }
    }
}

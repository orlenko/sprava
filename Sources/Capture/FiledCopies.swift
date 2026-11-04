import BinderFormat
import BinderStore
import Foundation
import Shelf
import SpravaKit

/// Recognising a file in intake that is already filed: by its exact bytes, or, for an email, by its headers
/// and body, since the same email fetched or saved again differs in bytes. Anything else still gets a card. A file left out
/// stays in intake; nothing is deleted.
extension IntakeWatcher {
    /// The catalog's document paths that are plain files of this binder now. A catalog's path is untrusted and checked
    /// as any other; a key or credential file is never read.
    static func filedPaths(_ row: ShelfRow) -> [String] {
        Set((row.teka.catalog?["documents"]?.arrayValue ?? []).compactMap { $0["path"]?.stringValue }).sorted().filter { path in
            DocumentPaths.isSafe(path, forFiling: false) && !DocumentPaths.isKeyFile(path) && DocumentPaths.plainFile(path, in: row.folder)
        }
    }

    /// What filed documents hold now, by digest: a record's own digest may be out of date, and may be missing from an
    /// adopted binder's. Only a file of the same size as one in intake is hashed, and most have none. An empty file
    /// says nothing about what a document is, so it never matches.
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
        for path in filedPaths(row) {
            let url = row.folder.appendingPathComponent(path)
            if let found = size(url), sizes.contains(found), let digest = DocumentPaths.sha256(of: url) { out[digest] = path }
        }
        return out
    }

    /// Whether a thing in intake is already filed: every file it would file. A message's text may be rendered another
    /// way, so with its original filed that text does not count; any other file beside them still does. A message file
    /// (a dropped `.eml`, or an imported message's original) also counts as filed when a filed email has its key
    /// (`messageKey`) now. `names` are relative to `intake/`. A key or credential file is never read, so it never decides.
    static func isFiled(names: [String], filed: [String: String], filedKeys: Set<String>, messageKey: (String) -> String?,
                        digest: (String) -> String?) -> Bool {
        let fileable = names.filter { !DocumentPaths.isKeyFile($0) }
        guard !fileable.isEmpty else { return false }
        func holds(_ name: String) -> Bool {
            digest(name).map { filed[$0] != nil } == true || messageKey(name).map(filedKeys.contains) == true
        }
        // `mail/x attachments/000-original-message.eml` is the original of `mail/x.md`, and of nothing else.
        let folder = fileable.first { ($0 as NSString).lastPathComponent == mailOriginalName && holds($0) }
            .map { ($0 as NSString).deletingLastPathComponent }
        return fileable.allSatisfy { name in
            let text = (name as NSString).deletingPathExtension + " attachments"
            return text == folder || holds(name)
        }
    }

    /// The same, from the digests a card recorded when it was written, and the messages its files hold now.
    static func isFiled(card: Proposal, filed: [String: String], filedKeys: Set<String> = [],
                        messageKey: (String) -> String? = { _ in nil }) -> Bool {
        var names: [String] = [], digests: [String: String] = [:]
        for op in card.ops where op["op"] == .str("file_document") {
            guard let from = op["args"]?["from"]?.stringValue, from.hasPrefix("intake/"),
                  let digest = op["args"]?["document"]?["sha256"]?.stringValue else { return false }
            let name = String(from.dropFirst("intake/".count))
            names.append(name)
            digests[name] = digest
        }
        return isFiled(names: names, filed: filed, filedKeys: filedKeys, messageKey: messageKey) { digests[$0] }
    }

    /// The files of this binder's intake left out of review, as `intake/...` paths, in a stable order.
    package func copies(in folder: URL) -> [String] {
        guard let seen = (try? load())?[folder.standardizedFileURL.path] else { return [] }
        return seen.filter { $0.value.copy == true }.keys.sorted().map { "intake/" + $0 }
    }
}

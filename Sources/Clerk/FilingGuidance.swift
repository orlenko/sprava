import BinderFormat
import Foundation
import SpravaKit

/// The person's filing guidance for one binder: the accepted person's part of its `AGENTS.md`, and the binder's own folders
/// (decisions.md D43; docs/binder-instructions.md §4). A reader of intake may take from it only which folder, the file
/// name and which requests are to-dos; code checks the folder and the name here, whatever the reader answered.
public struct FilingGuidance: Sendable, Equatable {
    public let text: String
    /// Only the first part was given: the person's part is longer than the bound.
    public let cut: Bool
    /// The binder's own folders, most used first.
    public let folders: [String]

    public init(text: String, cut: Bool, folders: [String]) {
        self.text = text
        self.cut = cut
        self.folders = folders
    }

    /// The most folders listed for a reader.
    static let mostFolders = 200
    /// The most segments of a folder a reader may name.
    static let mostSegments = 4

    /// The guidance of the binder at `folder`, or why there is none to follow when the person's part is not empty: one
    /// line for the card, never the text. Only the text the person saved or confirmed in the app is followed (§2).
    public static func of(_ folder: URL, catalog: JSONObject?) -> (guidance: FilingGuidance?, note: String?) {
        guard case .success(let found) = BinderInstructions.read(folder), let given = found.guidance else { return (nil, nil) }
        guard found.isAccepted else { return (nil, "Your instructions changed outside Sprava and were not used.") }
        return (FilingGuidance(text: given.text, cut: given.cut, folders: folders(in: folder, catalog: catalog)), nil)
    }

    /// The binder's own folders (§4.1): the parents of its catalog's documents, then folders on disk up to two levels
    /// down, each one a document may be filed in, without links or hidden folders; at most `mostFolders`, most used first.
    public static func folders(in binder: URL, catalog: JSONObject?) -> [String] {
        var counts: [String: Int] = [:]
        for doc in catalog?["documents"]?.arrayValue ?? [] {
            guard let path = doc["path"]?.stringValue, path.contains("/") else { continue }
            let parent = (path as NSString).deletingLastPathComponent
            if allowed(parent) { counts[parent, default: 0] += 1 }
        }
        var onDisk: [String] = []
        func walk(_ relative: String, depth: Int) {
            let url = relative.isEmpty ? binder : binder.appendingPathComponent(relative, isDirectory: true)
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = relative.isEmpty ? name : relative + "/" + name
                var st = stat()
                guard lstat(binder.appendingPathComponent(path).path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, allowed(path) else { continue }
                onDisk.append(path)
                if depth < 2, onDisk.count < mostFolders { walk(path, depth: depth + 1) }
            }
        }
        walk("", depth: 1)
        let used = counts.keys.sorted { counts[$0]! > counts[$1]! || (counts[$0]! == counts[$1]! && $0 < $1) }
        var seen = Set<String>()
        return (used + onDisk).filter { seen.insert(DocumentPaths.fold($0)).inserted }.prefix(mostFolders).map { $0 }
    }

    /// A folder a document may be filed in: the document path rules, at most `mostSegments` segments.
    static func allowed(_ folder: String) -> Bool {
        !folder.isEmpty && folder.split(separator: "/", omittingEmptySubsequences: false).count <= mostSegments
            && DocumentPaths.isSafe(folder + "/x")
    }

    /// The folder a reader named, when it is one of the binder's own, one the text writes out whole, or either of those
    /// plus one new last segment (§4.1); nil otherwise. Returned as the binder or the text spells it, with any new segment
    /// as the reader gave it.
    public func checkedFolder(_ raw: String) -> String? {
        var folder = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while folder.hasPrefix("/") { folder.removeFirst() }
        while folder.hasSuffix("/") { folder.removeLast() }
        folder = folder.precomposedStringWithCanonicalMapping
        guard Self.allowed(folder) else { return nil }
        if let known = known(folder) { return known }
        let parent = (folder as NSString).deletingLastPathComponent
        guard !parent.isEmpty, let base = known(parent) else { return nil }
        return base + "/" + (folder as NSString).lastPathComponent
    }

    /// `folder` as one of the binder's own folders, or as the text writes it out whole; nil when it is neither.
    func known(_ folder: String) -> String? {
        let folded = DocumentPaths.fold(folder)
        if let own = folders.first(where: { DocumentPaths.fold($0) == folded }) { return own }
        return Self.writesOut(text, folder) ? folder : nil
    }

    /// Whether `text` holds `path` whole: with nothing but the text's ends, spaces or punctuation other than `/ - _` on
    /// either side, compared without case.
    static func writesOut(_ text: String, _ path: String) -> Bool {
        let haystack = Array(DocumentPaths.fold(text).unicodeScalars), needle = Array(DocumentPaths.fold(path).unicodeScalars)
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        func joins(_ s: Unicode.Scalar) -> Bool { s.properties.isAlphabetic || s.properties.numericType != nil || "/-_".unicodeScalars.contains(s) }
        var i = 0
        while i + needle.count <= haystack.count {
            if haystack[i..<(i + needle.count)].elementsEqual(needle),
               i == 0 || !joins(haystack[i - 1]), i + needle.count == haystack.count || !joins(haystack[i + needle.count]) {
                return true
            }
            i += 1
        }
        return false
    }

    /// The file name a reader gave, without its extension, made into a whole name with the original's extension (§4.1):
    /// nil when it is empty, too long, or would make the file a key file when the original is not one.
    public static func checkedName(_ raw: String, original: String) -> String? {
        var stem = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let ext = (original as NSString).pathExtension
        // A reader that wrote the extension anyway does not get it twice.
        if !ext.isEmpty, stem.lowercased().hasSuffix("." + ext.lowercased()) { stem = String(stem.dropLast(ext.count + 1)) }
        guard !stem.isEmpty, stem.count <= 120 else { return nil }
        let name = DocumentPaths.safeName(ext.isEmpty ? stem : stem + "." + ext)
        guard DocumentPaths.isSafe("x/" + name), !DocumentPaths.isKeyFile(name) || DocumentPaths.isKeyFile(original) else { return nil }
        return name
    }
}

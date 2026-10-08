import CryptoKit
import Foundation

/// Each binder's one-line description and whether it is on the clerk's filing list (mvp.md feature 1), kept in
/// Sprava's own state and never in the binder. A binder at disclosure `none` is offered only when the person
/// opted it in with a description they wrote (architecture 5.4).
public struct FilingList: Sendable {
    public let support: URL

    public init(support: URL) { self.support = support }

    public struct Entry: Codable, Equatable, Sendable {
        public var description: String
        public var filing: Bool
        public init(description: String, filing: Bool) {
            self.description = description
            self.filing = filing
        }
    }

    var url: URL { support.appendingPathComponent("binders.json") }

    /// The list, for readers: empty when it cannot be read.
    public func load() -> [String: Entry] { (try? read()) ?? [:] }

    /// The list, for writers: empty only when `binders.json` does not exist; one that cannot be read throws, so
    /// one binder's setting never saves over every other's.
    public func read() throws -> [String: Entry] {
        try OwnState.read([String: Entry].self, from: url) ?? [:]
    }

    public func set(_ folder: URL, _ entry: Entry) throws {
        var all = try read()
        all[folder.standardizedFileURL.path] = Entry(description: String(entry.description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)),
                                                     filing: entry.filing)
        try AtomicFile.makePrivateFolder(support)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(all), to: url)
    }

    /// The summary line of the binder's README.md, offered as the default description; the file is never edited.
    public static func readmeLine(_ folder: URL) -> String? {
        guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent("README.md"), limit: 256 * 1024) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") || t.hasPrefix("---") || t.hasPrefix("<!--") { continue }
            return String(t.prefix(160))
        }
        return nil
    }

    /// The binders the clerk may file into, with their index words. Only adopted binders this Mac manages, on the
    /// list, with a description; names must be unique and never `not-sure`. A binder at disclosure `none` goes by an
    /// opaque label, so the model never sees its name; code maps the label back by `folder` (architecture 5.4).
    public func binders(rows: [ShelfRow], deviceID: String) -> [FilingBinder] {
        let all = load()
        var seen = Set<String>()
        return rows.compactMap { row in
            guard row.teka.isAdopted, !row.teka.writesBlocked, Owner.device(of: row.folder) == deviceID,
                  let entry = all[row.folder.standardizedFileURL.path], entry.filing, !entry.description.isEmpty else { return nil }
            let name = Self.name(of: row)
            guard name != "not-sure", seen.insert(name).inserted else { return nil }
            return FilingBinder(name: name, description: entry.description, folder: row.folder,
                                words: FilingBinder.index(catalog: row.teka.catalog, description: entry.description),
                                openItems: FilingBinder.candidates(catalog: row.teka.catalog))
        }
    }

    /// The name the clerk and the model know a binder by: its opaque label while the disclosure the person
    /// confirmed is `none`, whatever an outside edit wrote since (the privacy ratchet, architecture 4.5), else its
    /// name.
    public static func name(of row: ShelfRow) -> String {
        PrivacyRatchet.disclosure(row) == "none" ? label(row.folder) : row.name
    }

    /// A stable opaque label for a binder whose name the model must not see: `binder-` and six hex digits of the
    /// SHA-256 of its folder path.
    static func label(_ folder: URL) -> String {
        "binder-" + SHA256.hash(data: Data(folder.standardizedFileURL.path.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
    }
}

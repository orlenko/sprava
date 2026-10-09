import BinderStore
import CryptoKit
import Foundation
import SpravaKit

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

    package var url: URL { support.appendingPathComponent("binders.json") }

    /// The list, for readers: empty when it cannot be read.
    public func load() -> [String: Entry] { (try? read()) ?? [:] }

    /// The list, for writers: empty only when `binders.json` does not exist; one that cannot be read throws, so
    /// one binder's setting never saves over every other's.
    public func read() throws -> [String: Entry] {
        try StateFile.read([String: Entry].self, from: url) ?? [:]
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

    /// The name the clerk and the model know a binder by: its opaque label while the disclosure the person
    /// confirmed is `none`, whatever an outside edit wrote since (the privacy ratchet, architecture 4.5), else its
    /// name. Throws when the label's key cannot be read or made; the binder is then left out, never named.
    public func name(of row: ShelfRow) throws -> String {
        PrivacyRatchet.disclosure(row) == "none" ? try label(row.folder) : row.name
    }

    /// A stable opaque label for a binder whose name the model must not see: `binder-` and six hex digits of an
    /// HMAC of its folder path under this Mac's random key. A plain hash of the path could be matched against
    /// guessed paths and give the name away; without the key it cannot.
    func label(_ folder: URL) throws -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(folder.standardizedFileURL.path.utf8), using: try labelKey())
        return "binder-" + mac.prefix(3).map { String(format: "%02x", $0) }.joined()
    }

    package var keyURL: URL { support.appendingPathComponent("label-key") }

    /// The key of the labels, 32 random bytes in Sprava's own state (`label-key`), made once. A key that exists but
    /// cannot be read throws and is never replaced, since replacing it would rename every labelled binder; two
    /// processes making it at once keep the first one linked into place.
    func labelKey() throws -> SymmetricKey {
        switch SafeFile.read(keyURL, limit: 64) {
        case .ok(let data) where data.count == 32: return SymmetricKey(data: data)
        case .missing: break
        default: throw StateFile.Unreadable(path: keyURL.path)
        }
        try AtomicFile.makePrivateFolder(support)
        let temp = support.appendingPathComponent(".label-key-\(UUID().uuidString.lowercased())")
        try AtomicFile.write(SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }, to: temp)
        defer { unlink(temp.path) }
        guard link(temp.path, keyURL.path) == 0 || errno == EEXIST else { throw StateFile.Unreadable(path: keyURL.path) }
        try AtomicFile.flushFolder(support, step: "fsync folder")
        guard case .ok(let data) = SafeFile.read(keyURL, limit: 64), data.count == 32 else { throw StateFile.Unreadable(path: keyURL.path) }
        return SymmetricKey(data: data)
    }
}

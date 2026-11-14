import Companion
import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// The stable phone identity of each binder, by its place on the Shelf (companion-v0 §8.4): 16 random bytes kept in
/// Sprava's own state, never derived from the binder's name, path or contents. The identity belongs to the folder at
/// that path as it was when the switch was turned on (its device, inode and birth time), so a binder moved away, or
/// another folder put in its place, or one restored from a backup, comes back with "Show on my phone" off.
public struct CompanionBinderIdentities: Sendable {
    private let database: URL
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE binders (path TEXT PRIMARY KEY, identity BLOB NOT NULL UNIQUE CHECK (length(identity) = 16), " +
        "folder TEXT NOT NULL)",
    ])

    public init(support: URL) { database = support.appendingPathComponent("runtime/companion-binders.sqlite") }

    /// The identity recorded for this folder, or nil when none was made for the folder now at that path.
    public func existing(for folder: URL) throws -> CompanionLocalBinderIdentity? {
        try recorded(for: folder).map { try CompanionLocalBinderIdentity(bytes: $0) }
    }

    /// The identity for this folder, made and recorded on first use. A record made for another folder at this path is
    /// replaced, after `retire` has switched that folder's identity off.
    public func identity(for folder: URL, retire: (CompanionLocalBinderIdentity) throws -> Void = { _ in }) throws -> CompanionLocalBinderIdentity {
        try CompanionLocalBinderIdentity(bytes: try recorded(for: folder, create: true, retire: retire)!)
    }

    /// Whether the folder now at a recorded path is the one its identity was made for.
    public enum Match: Sendable, Equatable { case same, missing, replaced }

    /// Every identity ever made, with its path and whether the folder there is still the one it was made for; the
    /// companion job matches them to the Shelf.
    public func all() throws -> [(folder: URL, identity: CompanionLocalBinderIdentity, match: Match)] {
        let rows = try StateStore.open(database, schema: Self.schema).read { t in
            try t.rows("SELECT path, identity, folder FROM binders ORDER BY path")
        }
        return try rows.map { row in
            guard row.count == 3, let path = row[0].text, let bytes = row[1].blob, let stamp = row[2].text else {
                throw CompanionPublicationError.invalid
            }
            let folder = URL(fileURLWithPath: path, isDirectory: true)
            let current = try Self.stamp(folder)
            return (folder, try CompanionLocalBinderIdentity(bytes: bytes), current == nil ? .missing : current == stamp ? .same : .replaced)
        }
    }

    /// The folder's physical identity, or nil when nothing is there. A link or a file is never a binder folder.
    static func stamp(_ folder: URL) throws -> String? {
        var info = stat()
        guard lstat(folder.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw CompanionPublicationError.unavailable
        }
        guard info.st_mode & S_IFMT == S_IFDIR else { return "not-a-folder" }
        return "\(info.st_dev):\(info.st_ino):\(info.st_birthtimespec.tv_sec):\(info.st_birthtimespec.tv_nsec)"
    }

    func recorded(for folder: URL, create: Bool = false,
                  retire: (CompanionLocalBinderIdentity) throws -> Void = { _ in }) throws -> Data? {
        let path = folder.standardizedFileURL.path
        let current = try Self.stamp(folder)
        let store = try StateStore.open(database, schema: Self.schema)
        let lookup = { (t: Transaction) throws -> (bytes: Data, stamp: String)? in
            guard let row = try t.rows("SELECT identity, folder FROM binders WHERE path = ?", .text(path)).first else { return nil }
            guard row.count == 2, let bytes = row[0].blob, bytes.count == 16, let stamp = row[1].text else { throw CompanionPublicationError.invalid }
            return (bytes, stamp)
        }
        guard create else {
            guard let row = try store.read(lookup), row.stamp == current else { return nil }
            return row.bytes
        }
        guard let current, current != "not-a-folder" else { throw CompanionPublicationError.unavailable }
        return try store.write { t in
            if let row = try lookup(t) {
                if row.stamp == current { return row.bytes }
                try retire(try CompanionLocalBinderIdentity(bytes: row.bytes))
            }
            let bytes = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
            _ = try t.execute("INSERT OR REPLACE INTO binders (path, identity, folder) VALUES (?, ?, ?)",
                              .text(path), .blob(bytes), .text(current))
            return bytes
        }
    }
}

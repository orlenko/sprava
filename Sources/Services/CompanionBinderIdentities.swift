import Companion
import CryptoKit
import Foundation
import SpravaKit

/// The stable phone identity of each binder, by its place on the Shelf (companion-v0 §8.4): 16 random bytes kept in
/// Sprava's own state, never derived from the binder's name, path or contents. A binder moved to another folder gets a
/// new identity, so its "Show on my phone" comes back off there.
public struct CompanionBinderIdentities: Sendable {
    private let database: URL
    private static let schema = StateStore.Schema(version: 1, statements: [
        "CREATE TABLE binders (path TEXT PRIMARY KEY, identity BLOB NOT NULL UNIQUE CHECK (length(identity) = 16))",
    ])

    public init(support: URL) { database = support.appendingPathComponent("runtime/companion-binders.sqlite") }

    /// The identity recorded for this folder, or nil when none was ever made. Never makes one.
    public func existing(for folder: URL) throws -> CompanionLocalBinderIdentity? {
        try recorded(for: folder).map { try CompanionLocalBinderIdentity(bytes: $0) }
    }

    /// The identity for this folder, made and recorded on first use.
    public func identity(for folder: URL) throws -> CompanionLocalBinderIdentity {
        try CompanionLocalBinderIdentity(bytes: try recorded(for: folder, create: true)!)
    }

    func recorded(for folder: URL, create: Bool = false) throws -> Data? {
        let path = folder.standardizedFileURL.path
        let store = try StateStore.open(database, schema: Self.schema)
        let lookup = { (t: Transaction) throws -> Data? in
            guard let row = try t.rows("SELECT identity FROM binders WHERE path = ?", .text(path)).first else { return nil }
            guard row.count == 1, let bytes = row[0].blob, bytes.count == 16 else { throw CompanionPublicationError.invalid }
            return bytes
        }
        guard create else { return try store.read(lookup) }
        return try store.write { t in
            if let bytes = try lookup(t) { return bytes }
            let bytes = SymmetricKey(size: .bits128).withUnsafeBytes { Data($0) }
            _ = try t.execute("INSERT INTO binders (path, identity) VALUES (?, ?)", .text(path), .blob(bytes))
            return bytes
        }
    }
}

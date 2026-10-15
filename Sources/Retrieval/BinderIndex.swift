import BinderFormat
import CryptoKit
import Foundation
import SpravaKit

/// One binder's search index (docs/conversation.md §9.1; architecture 5.5): `.sprava/index.sqlite`, SQLite FTS5,
/// rebuildable from the catalog and the documents (binder-v0 §7.2). It holds passages of each filed document's
/// text with page and span, translations beside their originals, open and closed items, log entries and the
/// person's own lines, each with its source's revision, and each document's coverage.
public final class BinderIndex {
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        init(_ description: String) { self.description = description }
    }

    /// About this many words to a passage (§9.1).
    public static let passageWords = 300
    /// A passage is cut here whatever its words, so one long run of text cannot make a huge row.
    public static let maxPassageScalars = 3_000
    /// Passages kept from one source: past this, the rest is left out and the coverage says so.
    public static let maxPassagesPerSource = 4_000
    /// UTF-8 bytes of document text the whole index keeps: past this, documents are left out, and say so.
    public static let maxIndexTextBytes = 128 << 20
    public static let maxSearchLimit = 50
    static let maxQueryTerms = 32, maxQueryScalars = 4_096
    /// The file's hard cap in 4 KiB pages (512 MiB), behind the text cap.
    static let maxFilePages = (512 << 20) / 4096
    static let fileName = "index.sqlite"
    static let schemaVersion = 1

    static let schema = [
        "CREATE TABLE sources (kind TEXT NOT NULL, key TEXT NOT NULL, revision TEXT NOT NULL, coverage TEXT, PRIMARY KEY (kind, key)) WITHOUT ROWID",
        """
        CREATE TABLE passages (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, key TEXT NOT NULL, page INTEGER, span_start INTEGER NOT NULL,
        span_end INTEGER NOT NULL, revision TEXT NOT NULL, language TEXT NOT NULL, text TEXT NOT NULL, bytes INTEGER NOT NULL,
        translation_of INTEGER, translator TEXT)
        """,
        "CREATE INDEX passages_source ON passages (kind, key)",
        "CREATE VIRTUAL TABLE passages_fts USING fts5(text, content='', contentless_delete=1, tokenize='unicode61 remove_diacritics 2')",
    ]

    let db: IndexDatabase
    private let folder: SpravaFolder

    private init(db: IndexDatabase, folder: SpravaFolder) { self.db = db; self.folder = folder }

    /// The binder's index, or nil when it must be rebuilt first: there is none, it is not one this installation
    /// created (it is removed then, never opened), or it does not open as this schema's version.
    public static func open(binder: URL, trust: IndexTrust) throws -> BinderIndex? {
        let folder = try SpravaFolder(binder: binder)
        guard let found = folder.identity(fileName) else { return nil }
        let trusted = found.plain ? try trust.contains(found.id) : false
        if trusted, let db = try? IndexDatabase(path: folder.path + "/" + fileName),
           (try? db.rows("PRAGMA user_version"))?.first?.first?.integer == Int64(schemaVersion) {
            return BinderIndex(db: db, folder: folder)
        }
        if trusted { try trust.forget(found.id) }
        folder.remove(fileName)
        return nil
    }

    /// Builds the whole index anew beside the old one and puts it in place: the old index, whatever it held, is
    /// replaced at once, never mixed with the new.
    public static func rebuild(binder: URL, teka: Teka, reader: DocumentReader, trust: IndexTrust) throws -> BinderIndex {
        guard teka.catalog != nil else { throw Failure("the binder's catalog cannot be read, so its index was not rebuilt") }
        let folder = try SpravaFolder(binder: binder)
        let temporary = try folder.createTemporary()
        var placed = false
        defer { if !placed { folder.remove(temporary) } }
        do {
            let db = try IndexDatabase(path: folder.path + "/" + temporary)
            defer { db.close() }
            try db.transaction {
                for statement in schema { try db.execute(statement) }
                try db.execute("PRAGMA user_version = \(schemaVersion)")
            }
            try BinderIndex(db: db, folder: folder).refresh(teka: teka, reader: reader)
        }
        guard let made = folder.identity(temporary) else { throw Failure("the new index disappeared before it was put in place") }
        if let old = folder.identity(fileName) { try trust.forget(old.id) }
        try trust.record(made.id)
        folder.remove(fileName)
        try folder.rename(temporary, to: fileName)
        placed = true
        guard let index = try open(binder: binder, trust: trust) else { throw Failure("the new index cannot be opened") }
        return index
    }

    /// A catalog entry's fingerprint: its canonical hash, or a hash of its compact text when it holds a number
    /// canonical JSON cannot write.
    static func revision(of value: JSONValue) -> String {
        (try? Canonical.hash(value)) ?? Data(JSONWriter.compact(value).utf8).sha256Hex
    }
}

extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

import BinderFormat
import Foundation
import SpravaKit

extension BinderIndex {
    /// The best passages for `query` by BM25, with what the search covered (docs/conversation.md §9.2), so an empty
    /// result says what was searched and what could not be. The query is words, never FTS5 syntax: any of them
    /// matches. The person's own lines are searched only with `conversation`, which only the binder's own roles
    /// ask for (§9.1). With `teka`, documents the catalog lists and the index has not seen are named.
    public func search(_ query: String, limit: Int = 8, conversation: Bool = false, teka: Teka? = nil,
                       intake: Bool = false) throws -> SearchResult {
        let coverage = try coverage(conversation: conversation, teka: teka, intake: intake)
        guard let match = Self.match(query), limit > 0 else { return SearchResult(hits: [], coverage: coverage) }
        let rows = try db.rows("""
            SELECT \(Self.columns) FROM passages_fts JOIN passages p ON p.id = passages_fts.rowid
            WHERE passages_fts MATCH ? AND (? OR p.kind != 'person-line') AND (? OR p.kind != 'intake')
            ORDER BY bm25(passages_fts), p.id LIMIT ?
            """, .text(match), .integer(conversation ? 1 : 0), .integer(intake ? 1 : 0), .integer(Int64(min(limit, Self.maxSearchLimit))))
        let hits = try rows.compactMap(Self.passage).map { p in Hit(passage: p, original: try p.translationOf.flatMap { try passage(id: $0) }) }
        return SearchResult(hits: hits, coverage: coverage)
    }

    public func passage(id: Int64) throws -> Passage? {
        try db.rows("SELECT \(Self.columns) FROM passages p WHERE p.id = ?", .integer(id)).first.flatMap(Self.passage)
    }

    /// A document's original passages in order, for a reader that translates them.
    public func passages(of document: ItemID) throws -> [Passage] {
        try db.rows("SELECT \(Self.columns) FROM passages p WHERE kind = 'document' AND key = ? AND translation_of IS NULL ORDER BY id",
                    .text(PassageSource.document(document).key)).compactMap(Self.passage)
    }

    public func coverage(conversation: Bool = false, teka: Teka? = nil, intake: Bool = false) throws -> Coverage {
        var c = Coverage()
        c.conversation = conversation
        c.intake = intake
        if intake {
            c.intakeManifestIndexed = try !db.rows("SELECT 1 FROM sources WHERE kind = 'intake-manifest' AND key = ''").isEmpty
        }
        var seen = Set<PassageSource>()
        for row in try db.rows("SELECT kind, key, coverage FROM sources") {
            guard let kind = row[0].text, let key = row[1].text, let source = PassageSource(kind: kind, key: key) else { continue }
            seen.insert(source)
            switch source {
            case .document(let id):
                c.documents.append(row[2].text.flatMap { try? JSONDecoder().decode(DocumentCoverage.self, from: Data($0.utf8)) }
                                   ?? DocumentCoverage(document: id.description, notIndexed: "its coverage cannot be read"))
            case .intake(let path):
                if intake {
                    c.documents.append(row[2].text.flatMap { try? JSONDecoder().decode(DocumentCoverage.self, from: Data($0.utf8)) }
                        ?? DocumentCoverage(document: "intake:\(path)", notIndexed: "its coverage cannot be read"))
                }
            case .openItem: c.openItems += 1
            case .closedItem: c.closedItems += 1
            case .log: c.logEntries += 1
            case .personLine: break
            }
        }
        for translations in [false, true] {
            let languages = try db.rows("SELECT DISTINCT language FROM passages WHERE (kind = 'document' OR (? AND kind = 'intake')) AND translation_of IS \(translations ? "NOT " : "")NULL ORDER BY language", .integer(intake ? 1 : 0))
                .compactMap { $0.first?.text }
            if translations { c.translationLanguages = languages } else { c.languages = languages }
        }
        if let teka, teka.catalog != nil {
            c.notYetIndexed = Self.documents(in: teka).filter { !seen.contains(.document($0.id)) }.map(\.id.description)
            c.catalogChecked = true
        }
        return c
    }

    static let columns = "p.id, p.kind, p.key, p.page, p.span_start, p.span_end, p.revision, p.language, p.text, p.translation_of, p.translator"

    static func passage(_ row: [StateValue]) -> Passage? {
        guard row.count == 11, let id = row[0].integer, let kind = row[1].text, let key = row[2].text,
              let source = PassageSource(kind: kind, key: key), let start = row[4].integer, let end = row[5].integer, start <= end
        else { return nil }
        return Passage(id: id, source: source, page: row[3].integer.map(Int.init), span: Int(start)..<Int(end), revision: row[6].text ?? "",
                       language: row[7].text ?? "und", text: row[8].text ?? "", translationOf: row[9].integer, translator: row[10].text)
    }

    /// The query's words, each quoted, any of them matching: no query text is read as FTS5 syntax. Nil without a word.
    /// Only the first `maxQueryScalars` of the query and its first `maxQueryTerms` words are read, each up to 64 scalars.
    static func match(_ query: String) -> String? {
        var words: [String] = [], word = String.UnicodeScalarView()
        func end() {
            let w = String(word)
            if !w.isEmpty, !words.contains(w) { words.append(w) }
            word = .init()
        }
        let head = String(String.UnicodeScalarView(query.unicodeScalars.prefix(maxQueryScalars)))
        for s in head.precomposedStringWithCanonicalMapping.unicodeScalars where words.count < maxQueryTerms {
            if s.properties.isAlphabetic || s.properties.numericType != nil || s.properties.generalCategory == .nonspacingMark {
                if word.count < 64 { word.append(s) }
            } else { end() }
        }
        if words.count < maxQueryTerms { end() }
        return words.isEmpty ? nil : words.map { "\"\($0)\"" }.joined(separator: " OR ")
    }
}

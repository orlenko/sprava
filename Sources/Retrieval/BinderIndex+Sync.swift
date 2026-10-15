import BinderFormat
import Foundation
import SpravaKit

/// Keeping the index in step with the catalog (docs/conversation.md §17.2, §17.7): a changed source is cut again in one transaction.
extension BinderIndex {
    typealias Cut = (page: Int?, span: Range<Int>, text: String)

    /// Brings the index up to the catalog: changed entries are cut again, changed documents read again, departed sources removed.
    public func refresh(teka: Teka, reader: DocumentReader) throws {
        guard teka.catalog != nil else { throw Failure("the binder's catalog cannot be read, so its index was not refreshed") }
        var current: [PassageSource: (revision: String, text: String)] = [:]
        for item in teka.items {
            guard let id = item.id else { continue }
            current[.openItem(id)] = (Self.revision(of: item.raw), Self.text(item.object, ["title", "waiting_on", "notes", "note"]) + "\n" + item.tags.joined(separator: " "))
        }
        for (i, entry) in teka.log.enumerated() {
            let o = entry.object, revision = Self.revision(of: entry.raw)
            if let id = entry.closedID {
                current[.closedItem(id)] = (revision, Self.text(o, ["title", "note"]) + "\n" + Self.text(o?["final"]?.objectValue, ["waiting_on", "notes", "note"]))
            } else {
                current[.log("#\(i)")] = (revision, Self.text(o, ["action", "title", "note"]))
            }
        }
        let indexed = try indexedRevisions()
        for (source, value) in current where indexed[source] != value.revision {
            try replace(source, revision: value.revision, language: "und", cuts: Self.cut(value.text, page: nil))
        }
        let records = Self.documents(in: teka), listed = Set(records.map { PassageSource.document($0.id) })
        for source in indexed.keys where current[source] == nil && !listed.contains(source) {
            if case .personLine = source { continue }
            try remove(source)
        }
        for record in records { try update(record, reader: reader, indexed: indexed[.document(record.id)]) }
    }

    /// Brings one document up to the catalog: read again when its bytes changed, removed when it left the catalog.
    public func update(document id: ItemID, teka: Teka, reader: DocumentReader) throws {
        guard teka.catalog != nil else { throw Failure("the binder's catalog cannot be read, so the document was not indexed") }
        guard let record = Self.documents(in: teka).first(where: { $0.id == id }) else { return try remove(.document(id)) }
        try update(record, reader: reader, indexed: try indexedRevisions()[.document(id)])
    }

    /// Indexes one of the person's own lines (§3.3) under its id.
    public func index(personLine id: String, text: String) throws {
        try replace(.personLine(id), revision: Data(text.utf8).sha256Hex, language: "und", cuts: Self.cut(text, page: nil))
    }

    /// Keeps a translation beside its original (§9.4): its own passage, linked, removed with the original's source. Returns its id.
    @discardableResult
    public func addTranslation(of original: Int64, text: String, language: String, translator: String) throws -> Int64 {
        try db.transaction {
            guard let row = try db.rows("SELECT kind, key, page, span_start, span_end, revision FROM passages WHERE id = ? AND translation_of IS NULL",
                                        .integer(original)).first else { throw Failure("the original passage is not in the index") }
            try insert(row + [.text(language), .text(String(String.UnicodeScalarView(text.unicodeScalars.prefix(2 * Self.maxPassageScalars)))),
                              .integer(original), .text(translator)])
            return db.lastRowID
        }
    }

    func update(_ record: DocumentRecord, reader: DocumentReader, indexed: String?) throws {
        let source = PassageSource.document(record.id)
        var coverage = DocumentCoverage(document: record.id.description)
        if let why = Self.excluded(record.path) {
            coverage.notIndexed = why
            return try replace(source, revision: "excluded", language: "und", cuts: [], coverage: coverage)
        }
        guard let now = reader.revision(of: record) else {
            coverage.notIndexed = "the file cannot be read now"
            return try replace(source, revision: "unreadable", language: "und", cuts: [], coverage: coverage)
        }
        if now == indexed { return }
        let read = reader.read(record)
        coverage.revision = read.revision
        coverage.language = read.language
        coverage.notIndexed = read.problem
        coverage.notes = read.notes
        var cuts: [Cut] = []
        for (number, page) in read.pages {
            if number == nil { coverage.pagesKnown = false }
            switch page {
            case .read(let text, let from):
                if let number { coverage.pagesRead.append(number); if from == "ocr" { coverage.pagesFromOCR.append(number) } }
                cuts += Self.cut(text, page: number)
            case .failed(let reason): coverage.pagesFailed.append(.init(page: number ?? 1, reason: reason))
            case .illegible: coverage.pagesIllegible.append(number ?? 1)
            }
        }
        // Past a cap the rest is left out, and the coverage says so.
        let others = try db.rows("SELECT coalesce(sum(bytes), 0) FROM passages WHERE kind = 'document' AND key != ?", .text(source.key)).first?.first?.integer ?? 0
        var room = Int64(Self.maxIndexTextBytes) - others, kept = 0
        while kept < min(cuts.count, Self.maxPassagesPerSource), Int64(cuts[kept].text.utf8.count) <= room {
            room -= Int64(cuts[kept].text.utf8.count)
            kept += 1
        }
        if kept < cuts.count, coverage.notIndexed == nil {
            if kept == 0 { coverage.notIndexed = "the index is full" } else { coverage.cut = true }
        }
        try replace(source, revision: read.revision, language: read.language, cuts: Array(cuts.prefix(kept)), coverage: coverage)
    }

    /// `documents[]` records with an id and a path.
    static func documents(in teka: Teka) -> [DocumentRecord] {
        (teka.catalog?["documents"]?.arrayValue ?? []).compactMap { d in
            guard let id = ItemID(d["id"]), let path = d["path"]?.stringValue else { return nil }
            return DocumentRecord(id: id, path: path)
        }
    }

    /// Why a path is never read for the index, even when `documents[]` names it (binder-v0 §3.4, §3.6); nil when it may be.
    static func excluded(_ path: String) -> String? {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map { DocumentPaths.fold(String($0)) }
        if path.hasPrefix("/") || segments.contains(where: { $0.isEmpty || $0 == ".." || $0.hasPrefix("~") }) { return "its path does not stay inside the binder" }
        // A NUL would end the path where the system opens it, after the name these rules looked at.
        if path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) { return "its path holds a control character" }
        if segments.contains(where: { $0.hasPrefix(".") }) || segments[0] == "scripts"
            || (segments.count > 2 && segments[0] == "intake" && segments[1] == "mail" && segments.last == "state.json") {
            return "it is in a place Sprava never reads"
        }
        return DocumentPaths.isKeyFile(segments[segments.count - 1]) ? "it looks like a key or credential file" : nil
    }

    /// Every source's revision, person lines included.
    func indexedRevisions() throws -> [PassageSource: String] {
        var out: [PassageSource: String] = [:]
        for row in try db.rows("SELECT kind, key, revision FROM sources") {
            if let kind = row[0].text, let key = row[1].text, let source = PassageSource(kind: kind, key: key) { out[source] = row[2].text ?? "" }
        }
        return out
    }

    func replace(_ source: PassageSource, revision: String, language: String, cuts: [Cut], coverage: DocumentCoverage? = nil) throws {
        let json = try coverage.map { StateValue.text(String(decoding: try JSONEncoder().encode($0), as: UTF8.self)) } ?? .null
        let kind = StateValue.text(source.kind), key = StateValue.text(source.key)
        try db.transaction {
            try removeRows(source)
            try db.execute("INSERT INTO sources (kind, key, revision, coverage) VALUES (?, ?, ?, ?)", kind, key, .text(revision), json)
            for cut in cuts.prefix(Self.maxPassagesPerSource) {
                try insert([kind, key, cut.page.map { .integer(Int64($0)) } ?? .null, .integer(Int64(cut.span.lowerBound)),
                            .integer(Int64(cut.span.upperBound)), .text(revision), .text(language), .text(cut.text), .null, .null])
            }
        }
    }

    func remove(_ source: PassageSource) throws { try db.transaction { try removeRows(source) } }

    private func removeRows(_ source: PassageSource) throws {
        let kind = StateValue.text(source.kind), key = StateValue.text(source.key)
        try db.execute("DELETE FROM passages_fts WHERE rowid IN (SELECT id FROM passages WHERE kind = ? AND key = ?)", kind, key)
        try db.execute("DELETE FROM passages WHERE kind = ? AND key = ?", kind, key)
        try db.execute("DELETE FROM sources WHERE kind = ? AND key = ?", kind, key)
    }

    /// One passage and its full-text row: kind, key, page, span start, end, revision, language, text, translation_of, translator.
    private func insert(_ values: [StateValue]) throws {
        let bytes = StateValue.integer(Int64(values[7].text?.utf8.count ?? 0))
        _ = try db.rows("""
            INSERT INTO passages (kind, key, page, span_start, span_end, revision, language, text, translation_of, translator, bytes)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, values + [bytes])
        try db.execute("INSERT INTO passages_fts (rowid, text) VALUES (?, ?)", .integer(db.lastRowID), values[7])
    }

    static func text(_ object: JSONObject?, _ fields: [String]) -> String {
        fields.compactMap { object?[$0]?.stringValue }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// Passages of about `passageWords` words cut at white space, each at most `maxPassageScalars`, spans in scalars; at most
    /// one more than `maxPassagesPerSource`, so a caller can tell the text was cut.
    static func cut(_ text: String, page: Int?) -> [Cut] {
        let s = Array(text.unicodeScalars), cap = maxPassageScalars
        func space(_ i: Int) -> Bool { s[i].properties.isWhitespace }
        var out: [Cut] = [], i = 0
        while i < s.count, out.count <= maxPassagesPerSource {
            while i < s.count, space(i) { i += 1 }
            guard i < s.count else { break }
            let start = i
            var words = 0, end = i
            while i < s.count, words < passageWords, i - start < cap {
                while i < s.count, !space(i), i - start < cap { i += 1 }
                words += 1
                end = i
                while i < s.count, space(i), i - start < cap { i += 1 }
            }
            out.append((page, start..<end, String(String.UnicodeScalarView(s[start..<end]))))
        }
        return out
    }
}

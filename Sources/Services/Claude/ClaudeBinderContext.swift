import BinderFormat
import Capture
import Darwin
import Extract
import Foundation
import Retrieval
import SpravaKit

/// The app-consented read/draft pilot's source pack. All binder bytes stay labelled as data;
/// model instructions and request receipts come only from the authenticated app conversation.
struct ClaudeBinderContext: Sendable {
    struct Source: Sendable {
        let id: String
        let path: String
        let page: Int?
        let revision: String
        let text: String
        var json: JSONValue {
            .obj([("id", .str(id)), ("path", .str(path)), ("page", page.map(JSONValue.int) ?? .null),
                  ("revision", .str(revision)), ("text", .str(text))])
        }
    }
    let data: JSONValue
    let sources: [Source]
    static let maximumPackBytes = 256 * 1024

    /// Called only after resolving the current consent generation. Intake consent never implies filed
    /// document consent. The reader and result filter both enforce that distinction on every refresh.
    static func build(folder: URL, support: URL, documents: Bool, intake: Bool, query: String,
                      reader: any DocumentReader, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> Self {
        let teka = Teka.read(folder)
        guard teka.catalog != nil, !Teka.expungePending(in: folder) else { throw Unavailable() }
        let scoped = ScopedReader(base: reader, documents: documents, intake: intake, cancelled: cancelled)
        let trust = try IndexTrust.open(supportDirectory: support)
        let index: BinderIndex
        if let existing = try BinderIndex.open(binder: folder, trust: trust) {
            index = existing; try index.refresh(teka: teka, reader: scoped)
        } else { index = try BinderIndex.rebuild(binder: folder, teka: teka, reader: scoped, trust: trust) }
        guard !cancelled() else { throw Unavailable() }
        let paths = intake ? try intakePaths(folder) : []
        if intake { try index.refreshIntake(paths: paths, reader: scoped) }
        guard !cancelled() else { throw Unavailable() }
        let result = try index.search(searchTerms(query), limit: 50, teka: teka, intake: intake)
        var sources: [Source] = []
        var seen = Set<String>()
        // Intake is exclusively an intake-owner surface, even if a catalog calls it a document.
        // APFS aliases must not change which consent guards content, inventory or coverage.
        let records = (teka.catalog?["documents"]?.arrayValue ?? []).filter { record in
            guard let path = record["path"]?.stringValue else { return false }
            return !Self.isIntakePath(path)
        }
        let documentIDs = Set(records.compactMap { ItemID($0["id"])?.description })
        var guideID: String?
        var guideTruncated = false
        // The visible project guide is ordinary shared document data, always discoverable regardless
        // of the person's query. It never bypasses document consent or grants an operation capability.
        if documents, let record = records.first(where: { $0["path"] == .str("PROJECT.md") }),
           let id = ItemID(record["id"]) {
            let guide = scoped.read(DocumentRecord(id: id, path: "PROJECT.md"))
            let body = guide.pages.compactMap { if case .read(let text, _) = $0.page { return text }; return nil }.joined(separator: "\n")
            if !body.isEmpty {
                guideID = "S1"
                guideTruncated = body.unicodeScalars.count > 8_000
                sources.append(Source(id: "S1", path: "PROJECT.md", page: nil, revision: guide.revision,
                    text: String(String.UnicodeScalarView(body.unicodeScalars.prefix(8_000)))))
            }
        }
        for hit in result.hits {
            let p = hit.original ?? hit.passage
            let path: String
            switch p.source {
            case .document(let id):
                guard documents, let record = records.first(where: { ItemID($0["id"]) == id }),
                      let value = record["path"]?.stringValue else { continue }
                path = value
            case .intake(let value): guard intake else { continue }; path = value
            case .openItem(let id): path = "catalog.json#item:" + id.description
            case .closedItem(let id): path = "catalog.json#closed-item:" + id.description
            case .log: continue
            case .personLine: continue // Imported person lines are never authenticated app history.
            }
            if guideID != nil, path == "PROJECT.md" { continue }
            let key = path + ":" + String(p.id)
            guard seen.insert(key).inserted else { continue }
            sources.append(Source(id: "S\(sources.count + 1)", path: path, page: p.page, revision: p.revision, text: p.text))
            if sources.count == 12 { break }
        }
        // Recent mail remains discoverable when the person asks "the person who emailed earlier"
        // without repeating words in the message. The safe reader still owns all file access.
        if intake {
            let recent = IntakeWatcher.candidates(in: folder).filter { $0.channel == "email" }.sorted { $0.mtime > $1.mtime }
            for candidate in recent.prefix(6) where sources.count < 18 {
                let path = "intake/" + candidate.name
                guard !sources.contains(where: { $0.path == path }), paths.contains(path) else { continue }
                let text = scoped.read(DocumentRecord(id: .string(path), path: path))
                let body = text.pages.compactMap { if case .read(let value, _) = $0.page { return value }; return nil }.joined(separator: "\n")
                if !body.isEmpty {
                    sources.append(Source(id: "S\(sources.count + 1)", path: path, page: nil, revision: text.revision,
                                          text: String(String.UnicodeScalarView(body.unicodeScalars.prefix(12_000)))))
                }
            }
        }
        let itemFields = ["id", "title", "description", "status", "priority", "due", "deadline", "bucket", "sensitivity", "notes", "note", "waiting_on", "contexts", "tags"]
        let allItems = teka.items.prefix(500).map { item in
            JSONValue.obj(itemFields.compactMap { key in item.raw[key].map { (key, bounded($0)) } })
        }
        let allInventory: [JSONValue] = documents ? records.prefix(500).map { record in
            .obj(["id", "title", "path"].compactMap { key in record[key].map { (key, bounded($0)) } })
        } : []
        let gaps = result.coverage.documents.filter { entry in
            (!entry.document.hasPrefix("intake:") && documents && documentIDs.contains(entry.document)) || (entry.document.hasPrefix("intake:") && intake)
        }.filter { !$0.isComplete || !$0.pagesKnown }.prefix(40).map { entry in
            JSONValue.obj([("source", .str(entry.document)), ("incomplete", .bool(true))])
        }
        let items = within(allItems, bytes: 64 * 1024)
        let inventory = within(allInventory, bytes: 16 * 1024)
        let closed = teka.log.filter { $0.closedID != nil }.suffix(50).map { entry in
            JSONValue.obj(["id", "title", "at", "action"].compactMap { key in entry.raw[key].map { (key, bounded($0)) } })
        }
        var sourceBytes = 0
        sources = sources.filter { source in
            let count = JSONWriter.compact(source.json).utf8.count
            guard sourceBytes + count <= 128 * 1024 else { return false }; sourceBytes += count; return true
        }
        let data = JSONValue.obj([
            ("as_of", .str(ISOTime.string(Date()))), ("binder_name", .str(teka.name)),
            ("current_items", .array(items)), ("recent_closed_items", .array(within(closed, bytes: 16 * 1024))), ("items_truncated", .bool(teka.items.count > items.count)),
            ("document_inventory", .array(inventory)), ("document_inventory_truncated", .bool(documents && records.count > inventory.count)), ("filed_documents_allowed", .bool(documents)),
            ("intake_allowed", .bool(intake)), ("search_query", .str(query)),
            ("project_guide_source", guideID.map(JSONValue.str) ?? .null),
            ("project_guide_truncated", .bool(guideTruncated)),
            ("sources", .array(sources.map(\.json))), ("incomplete_sources", .array(gaps)),
            ("search_is_exhaustive", .bool(false))
        ])
        guard JSONWriter.compact(data).utf8.count <= maximumPackBytes else { throw Unavailable() }
        return Self(data: data, sources: sources)
    }

    private static func isIntakePath(_ path: String) -> Bool {
        guard let first = path.split(separator: "/", omittingEmptySubsequences: false).first else { return false }
        return DocumentPaths.fold(String(first)) == "intake"
    }

    /// Conservative lexical expansion only; this never executes a model-selected command or FTS syntax.
    /// "pet regulation" must also find "Pets" and "regulations" in the binder's text.
    static func searchTerms(_ query: String) -> String {
        let stop: Set<String> = ["the", "a", "an", "is", "it", "to", "of", "in", "on", "and", "or", "for", "which", "what", "who", "do", "does", "did", "you", "me", "i", "that", "this", "about", "please", "remember", "talks", "would", "could", "can"]
        let words = query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { !stop.contains($0) }
        var terms: [String] = [], seen = Set<String>()
        for word in words.prefix(12) {
            let variants = word.count >= 3 && word.count <= 40 && word.utf8.allSatisfy({ $0 >= 97 && $0 <= 122 })
                ? [word, word.hasSuffix("s") ? String(word.dropLast()) : word + "s"] : [word]
            for term in variants where seen.insert(term).inserted { terms.append(term) }
        }
        return terms.joined(separator: " ")
    }
    private static func within(_ values: [JSONValue], bytes: Int) -> [JSONValue] {
        var chosen: [JSONValue] = [], used = 0
        for value in values {
            let count = JSONWriter.compact(value).utf8.count
            if used + count > bytes { break }; chosen.append(value); used += count
        }
        return chosen
    }

    struct Unavailable: Error {}
    private static func bounded(_ value: JSONValue) -> JSONValue {
        if let string = value.stringValue { return .str(String(String.UnicodeScalarView(string.unicodeScalars.prefix(2_000)))) }
        if let array = value.arrayValue {
            return .array(array.prefix(12).compactMap(\.stringValue).map { text in
                .str(String(String.UnicodeScalarView(text.unicodeScalars.prefix(200))))
            })
        }
        if value.objectValue != nil { return .null }
        return value
    }

    private struct ScopedReader: DocumentReader {
        let base: any DocumentReader
        let documents: Bool
        let intake: Bool
        let cancelled: @Sendable () -> Bool
        func permits(_ record: DocumentRecord) -> Bool { !cancelled() && (ClaudeBinderContext.isIntakePath(record.path) ? intake : documents) }
        func revision(of document: DocumentRecord) -> String? { permits(document) ? base.revision(of: document) : nil }
        func read(_ document: DocumentRecord) -> DocumentText {
            permits(document) ? base.read(document) : DocumentText(revision: "", language: "und", pages: [], problem: "not shared with Claude")
        }
    }

    /// Check listing failures before the intake owner's convenience API (which returns [] on failure).
    /// A failed listing never becomes an allegedly complete empty manifest.
    private static func intakePaths(_ folder: URL) throws -> [String] {
        func listing(_ url: URL) throws -> [String]? {
            var info = stat()
            if lstat(url.path, &info) != 0 { if errno == ENOENT { return nil }; throw Unavailable() }
            guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw Unavailable() }
            return try FileManager.default.contentsOfDirectory(atPath: url.path)
        }
        _ = try listing(folder.appendingPathComponent("intake"))
        let mail = folder.appendingPathComponent("intake/mail")
        if let entries = try listing(mail) {
            for name in entries where name.hasSuffix(" attachments") {
                _ = try listing(mail.appendingPathComponent(name))
            }
        }
        let candidates = IntakeWatcher.candidates(in: folder)
        let paths = candidates.flatMap { ["intake/" + $0.name] + $0.attachments.map { "intake/" + $0 } }
            .filter { !DocumentPaths.isKeyFile($0) }
        guard paths.count <= BinderIndex.maximumIntakeSources else { throw Unavailable() }
        return paths
    }
}

import BinderFormat
import Foundation

/// Where an indexed passage comes from (docs/conversation.md §9.1): every row carries its source.
public enum PassageSource: Sendable, Hashable {
    case document(ItemID)
    case openItem(ItemID)
    case closedItem(ItemID)
    /// A `processing_log[]` entry that closes nothing, keyed `#<position>`: the log is append-only, and one op may write several.
    case log(String)
    /// One of the person's own lines (§3.3), searched only for the binder's own roles; the transcript reader comes later.
    case personLine(String)

    var kind: String {
        switch self {
        case .document: "document"
        case .openItem: "open-item"
        case .closedItem: "closed-item"
        case .log: "log"
        case .personLine: "person-line"
        }
    }

    /// The key in the index: an id keeps its JSON type, so `7` and `"7"` stay two sources.
    var key: String {
        switch self {
        case .document(.string(let s)), .openItem(.string(let s)), .closedItem(.string(let s)): "s:" + s
        case .document(.integer(let i)), .openItem(.integer(let i)), .closedItem(.integer(let i)): "i:" + String(i)
        case .log(let k), .personLine(let k): k
        }
    }

    init?(kind: String, key: String) {
        let id: ItemID? = key.hasPrefix("s:") ? .string(String(key.dropFirst(2)))
            : key.hasPrefix("i:") ? Int64(key.dropFirst(2)).map(ItemID.integer) : nil
        switch (kind, id) {
        case ("document", let id?): self = .document(id)
        case ("open-item", let id?): self = .openItem(id)
        case ("closed-item", let id?): self = .closedItem(id)
        case ("log", _): self = .log(key)
        case ("person-line", _): self = .personLine(key)
        default: return nil
        }
    }
}

/// One passage of the index: about 300 words of one source, where it sits, and the revision it was cut from.
public struct Passage: Sendable, Equatable {
    public let id: Int64
    public let source: PassageSource
    /// The document's page, from 1; nil for items, log entries and lines, and for a document read as one text.
    public let page: Int?
    /// Where the passage sits in its page's text (or its source's text), in Unicode scalars.
    public let span: Range<Int>
    /// The source's revision when the passage was cut: a document's SHA-256, an entry's canonical hash.
    public let revision: String
    /// A language tag such as `fr`, or `und`.
    public let language: String
    public let text: String
    /// For a translation, the original it translates and what made it (§9.4); a translation is never the record.
    public let translationOf: Int64?
    public let translator: String?

    public var isTranslation: Bool { translationOf != nil }
}

/// What a reader got out of one document, page by page: the input of the index.
public struct DocumentText: Sendable {
    public enum Page: Sendable, Equatable {
        /// Text read from the page, and how (`text-layer`, `ocr`, `parsed`).
        case read(String, from: String)
        case failed(String)
        /// Read, and holds no legible text.
        case illegible
    }

    /// The SHA-256 of the bytes that were read.
    public var revision: String
    public var language: String
    /// Pages in order, from 1; one page numbered nil when the reader cannot tell pages apart.
    public var pages: [(number: Int?, page: Page)]
    /// Why nothing of the document was read.
    public var problem: String?
    /// What else the reader left out, such as a message's attachments.
    public var notes: [String]

    public init(revision: String, language: String, pages: [(number: Int?, page: Page)], problem: String? = nil, notes: [String] = []) {
        self.revision = revision; self.language = language; self.pages = pages; self.problem = problem; self.notes = notes
    }
}

/// One record of `documents[]` as the index reads it.
public struct DocumentRecord: Sendable {
    public let id: ItemID, path: String
    public init(id: ItemID, path: String) { self.id = id; self.path = path }
}

/// Reads a binder's documents for the index, through the sandboxed helper in the runtime.
public protocol DocumentReader: Sendable {
    /// The SHA-256 of the document's bytes now; nil when they cannot be read.
    func revision(of document: DocumentRecord) -> String?
    func read(_ document: DocumentRecord) -> DocumentText
}

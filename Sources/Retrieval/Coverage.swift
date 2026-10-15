import Foundation

/// What the index holds of one document, so a search can say what it did not cover (docs/conversation.md §9.2, §17.6).
public struct DocumentCoverage: Sendable, Equatable, Codable {
    public struct PageProblem: Sendable, Equatable, Codable {
        public let page: Int
        public let reason: String
    }

    /// The document's id, as text.
    public var document: String
    /// The revision indexed; nil when nothing could be read.
    public var revision: String?
    public var language: String?
    public var pagesRead: [Int] = []
    /// Pages whose text came from OCR: their names and numbers may need checking against the page.
    public var pagesFromOCR: [Int] = []
    public var pagesFailed: [PageProblem] = []
    public var pagesIllegible: [Int] = []
    /// False when the reader gave the text as one block, so its passages carry no page number.
    public var pagesKnown = true
    /// Why nothing of the document is in the index.
    public var notIndexed: String?
    /// Passages past the per-document cap or the index's size cap were left out.
    public var cut = false

    public var isComplete: Bool { notIndexed == nil && pagesFailed.isEmpty && pagesIllegible.isEmpty && !cut }
}

/// What a search looked through: the honest negative of §9.2 says this, never "the documents do not say".
public struct Coverage: Sendable, Equatable {
    public var documents: [DocumentCoverage] = []
    /// Documents the catalog lists that the index has not seen yet.
    public var notYetIndexed: [String] = []
    public var openItems = 0, closedItems = 0, logEntries = 0
    /// Languages of the original document passages, and of their translations.
    public var languages: [String] = []
    public var translationLanguages: [String] = []
    /// Whether the person's own lines were searched.
    public var conversation = false
    /// Whether the catalog was compared with the index, so `notYetIndexed` is known.
    public var catalogChecked = false

    /// The documents whose text is not wholly in the index; an empty result names them (§9.2).
    public var gaps: [DocumentCoverage] { documents.filter { !$0.isComplete || !$0.pagesKnown }.sorted { $0.document < $1.document } }

    /// Every listed document is wholly indexed: only then may an empty search say more than "no relevant passage was found" (§17.7).
    public var isExhaustive: Bool { catalogChecked && gaps.isEmpty && notYetIndexed.isEmpty }
}

/// One passage found, and for a translation the original it translates.
public struct Hit: Sendable, Equatable {
    public let passage: Passage
    public let original: Passage?
}

public struct SearchResult: Sendable, Equatable {
    public let hits: [Hit]
    public let coverage: Coverage
}

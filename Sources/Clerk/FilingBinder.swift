import BinderFormat
import Foundation
import SpravaKit

/// A binder the clerk may file into: on the filing list, with the person's one-line description (mvp.md feature 1).
public struct FilingBinder: Sendable, Equatable {
    public var name: String
    public var description: String
    public var folder: URL
    /// Words from the binder's open items, documents and description, for the `index_match` signal.
    public var words: Set<String>
    /// The binder's open items, redacted ones included, for the duplicate check (capture-event-v0 §6.4 step 3).
    public var openItems: [Candidate]

    public struct Candidate: Sendable, Equatable {
        public var id: JSONValue
        public var title: String
        public var due: String?
        public var waitingOn: String?
        public var words: Set<String>
        public var noDeadline = false
        /// The item's `kind`, if any: a redaction needs one (binder-v0 §4.4).
        public var kind: String?
        /// `open`, `waiting` or `blocked`: a wait that starts on an open item is a `set_status`.
        public var status: String?
        /// Whether the item carries `recurrence`. Its completion needs `next_due` (binder-v0 §5.4), and the MVP leaves
        /// recurring items to the hub (mvp.md feature 2), so the clerk never completes one.
        public var recurring = false
        public var key: String { HubLane.idText(id) }

        package init(id: JSONValue, title: String, due: String? = nil, waitingOn: String? = nil, words: Set<String>,
                     noDeadline: Bool = false, kind: String? = nil, status: String? = nil, recurring: Bool = false) {
            self.id = id
            self.title = title
            self.due = due
            self.waitingOn = waitingOn
            self.words = words
            self.noDeadline = noDeadline
            self.kind = kind
            self.status = status
            self.recurring = recurring
        }
    }

    public init(name: String, description: String, folder: URL, words: Set<String> = [], openItems: [Candidate] = []) {
        self.name = name
        self.description = description
        self.folder = folder
        self.words = words
        self.openItems = openItems
    }

    public static func candidates(catalog: JSONObject?) -> [Candidate] {
        (catalog?["open_items"]?.arrayValue ?? []).compactMap { item in
            guard let id = item["id"], let title = item["title"]?.stringValue, item["dismissed"] != .bool(true) else { return nil }
            let waiting = item["waiting_on"]?.stringValue
            return Candidate(id: id, title: title, due: item["due"]?.stringValue, waitingOn: waiting,
                             words: significantWords(title + " " + (waiting ?? "")), noDeadline: item["no_deadline"] == .bool(true),
                             kind: item["kind"]?.stringValue, status: item["status"]?.stringValue,
                             recurring: item["recurrence"].map { !$0.isNull } ?? false)
        }
    }

    static let stop: Set<String> = ["about", "after", "again", "also", "from", "have", "into", "just", "make", "need", "next", "that",
                                    "their", "them", "then", "there", "they", "this", "with", "will", "week", "would", "your", "pour",
                                    "avec", "dans", "faire", "leur", "nous", "votre", "sont", "cette", "call", "send", "check", "pay"]

    /// Words of four letters or more, stop words left out, plurals folded ("repairs" and "repair" match).
    public static func significantWords(_ text: String) -> Set<String> {
        Set(text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init).filter { $0.count >= 4 && !stop.contains($0) }.map { w in
            if w.count > 4, w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
            if w.count > 4, w.hasSuffix("s"), !w.hasSuffix("ss") { return String(w.dropLast()) }
            return w
        })
    }

    /// The binder's searchable words: open item titles and waiting-on names, document titles, its description.
    public static func index(catalog: JSONObject?, description: String) -> Set<String> {
        var text = description
        for item in catalog?["open_items"]?.arrayValue ?? [] {
            text += " " + (item["title"]?.stringValue ?? "") + " " + (item["waiting_on"]?.stringValue ?? "")
        }
        for doc in catalog?["documents"]?.arrayValue ?? [] { text += " " + (doc["title"]?.stringValue ?? "") }
        return significantWords(text)
    }
}

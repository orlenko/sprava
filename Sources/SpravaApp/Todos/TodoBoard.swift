import BinderFormat
import Foundation
import SpravaKit

/// Every open item on the Shelf in one list, for the To-dos page: each binder's buckets (binder-v0 §5.2), merged.
/// Built beside the Shelf's snapshot by its disk worker from the Now pages already prepared there, so the main actor
/// only filters it.
struct TodoBoard: Sendable {
    /// The page's groups: the buckets of binder-v0 §5.2 with Nudge and Waiting shown together, the items to chase first.
    enum Group: String, CaseIterable, Sendable {
        case overdue, today, next7, waiting, later, noDeadline

        init?(_ bucket: Bucket) {
            switch bucket {
            case .overdue: self = .overdue
            case .today: self = .today
            case .next7: self = .next7
            case .nudge, .waiting: self = .waiting
            case .later: self = .later
            case .noDeadline: self = .noDeadline
            case .recentlyClosed: return nil
            }
        }

        var title: String {
            switch self {
            case .overdue: Bucket.overdue.title
            case .today: Bucket.today.title
            case .next7: Bucket.next7.title
            case .waiting: Bucket.waiting.title
            case .later: Bucket.later.title
            case .noDeadline: Bucket.noDeadline.title
            }
        }
    }

    /// One binder as the board reads it.
    struct Source: Sendable {
        let name: String
        let folder: URL
        /// Whether its items may be closed from the page: adopted, writable (as on the binder page).
        let writable: Bool
        let page: NowPage
    }

    struct Entry: Sendable, Identifiable {
        let binder: String
        let folder: URL
        let item: Item
        /// Nudge or Waiting within the Waiting group; the item's own bucket otherwise.
        let bucket: Bucket
        let writable: Bool
        /// Unique on the page: the binder's folder and the item's place in its catalog.
        var id: String { "\(folder.path)\u{0}\(item.index)" }
        /// Done is offered as on the binder page: a writable binder, an item with an id, no recurrence.
        var closable: Bool { writable && item.object?["id"] != nil && !item.hasRecurrence }
    }

    struct Filter: Equatable, Sendable {
        var query = ""
        var highOnly = false
        /// "Where am I": a context such as `@errands`, or nil for everywhere.
        var context: String?
    }

    let today: CalendarDate
    private(set) var groups: [Group: [Entry]] = [:]
    /// The contexts the open items carry, `@anywhere` aside, for the "Where am I" picker.
    private(set) var contexts: [String] = []

    init(_ sources: [Source] = [], today: CalendarDate) {
        self.today = today
        var found = Set<String>()
        for source in sources {
            for (bucket, items) in source.page.items {
                guard let group = Group(bucket) else { continue }
                for item in items {
                    groups[group, default: []].append(Entry(binder: source.name, folder: source.folder, item: item,
                                                            bucket: bucket, writable: source.writable))
                    found.formUnion(item.contexts)
                }
            }
        }
        for (group, list) in groups { groups[group] = list.sorted(by: Self.order(for: group)) }
        found.remove(Self.anywhere)
        contexts = found.sorted(by: Self.textLess)
    }

    static let anywhere = "@anywhere"

    func entries(_ group: Group) -> [Entry] { groups[group] ?? [] }

    func count(_ group: Group) -> Int { groups[group]?.count ?? 0 }

    var openCount: Int { groups.values.reduce(0) { $0 + $1.count } }

    func entries(_ group: Group, _ filter: Filter) -> [Entry] {
        let words = Self.fold(filter.query).split(whereSeparator: \.isWhitespace).map(String.init)
        return entries(group).filter { Self.matches($0, words: words, filter: filter) }
    }

    static func matches(_ entry: Entry, words: [String], filter: Filter) -> Bool {
        let item = entry.item
        if filter.highOnly, item.priority != .high { return false }
        // An item with no context, or `@anywhere`, can be done anywhere (binder-v0 §5.9).
        if let context = filter.context, !item.contexts.isEmpty, !item.contexts.contains(context),
           !item.contexts.contains(anywhere) { return false }
        guard !words.isEmpty else { return true }
        let haystack = fold(([item.title, entry.binder, item.idText] + item.tags.map { "#\($0)" } + item.contexts)
            .joined(separator: "\n"))
        return words.allSatisfy { haystack.contains($0) }
    }

    static func fold(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    static func textLess(_ a: String, _ b: String) -> Bool {
        Array(a.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
            .lexicographicallyPrecedes(b.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
    }

    static func rank(_ item: Item) -> Int {
        switch item.priority {
        case .high?: 0
        case .normal?: 1
        case .low?: 2
        case nil: 3
        }
    }

    /// binder-v0 §5.2's order within a bucket, across binders: by date (oldest overdue first; `follow_up_at` in
    /// Waiting, missing first), then priority, title and id, then the binder's name.
    static func order(for group: Group) -> (Entry, Entry) -> Bool {
        { a, b in
            let (x, y): (CalendarDate?, CalendarDate?) = switch group {
            case .waiting: (a.item.followUpAt, b.item.followUpAt)
            case .noDeadline: (nil, nil)
            default: (a.item.due, b.item.due)
            }
            if x != y {
                guard let x else { return group == .waiting }
                guard let y else { return group != .waiting }
                return x < y
            }
            if rank(a.item) != rank(b.item) { return rank(a.item) < rank(b.item) }
            if a.item.titleSortKey != b.item.titleSortKey { return textLess(a.item.titleSortKey, b.item.titleSortKey) }
            if a.item.idText != b.item.idText { return textLess(a.item.idText, b.item.idText) }
            if a.binder != b.binder { return textLess(a.binder, b.binder) }
            return a.folder.path < b.folder.path
        }
    }
}

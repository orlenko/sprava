import Foundation

/// The one bucket taxonomy (decisions.md F4; teka-v0 §5.2).
public enum Bucket: String, Sendable, CaseIterable {
    case overdue, today, next7, later, noDeadline, nudge, waiting, recentlyClosed

    public var title: String {
        switch self {
        case .overdue: "Overdue"
        case .today: "Today"
        case .next7: "Next 7 days"
        case .later: "Later"
        case .noDeadline: "No deadline"
        case .nudge: "Nudge"
        case .waiting: "Waiting"
        case .recentlyClosed: "Recently closed"
        }
    }
}

/// One line in the Recently closed bucket: a closure entry, or a `done` item still in `open_items[]`.
public struct ClosedEntry: Sendable {
    public let title: String
    public let idText: String
    public let action: String
    /// nil for a `done` item left in `open_items[]` ("done (date unknown)").
    public let closedOn: CalendarDate?
}

/// The Now page of one teka: its items in buckets, computed from plain code and today's date.
public struct NowPage: Sendable {
    public var items: [Bucket: [Item]] = [:]
    public var closed: [ClosedEntry] = []
    public var hiddenCount = 0

    public func count(_ bucket: Bucket) -> Int {
        bucket == .recentlyClosed ? closed.count : items[bucket]?.count ?? 0
    }

    /// Which bucket an open item belongs in, or nil when hidden or done (teka-v0 §5.2 steps 1–5).
    public static func bucket(for item: Item, today: CalendarDate) -> Bucket? {
        if item.declaredStatus == .done { return .recentlyClosed }
        if item.isDismissed { return nil }
        if item.status == .waiting || item.status == .blocked {
            if let follow = item.followUpAt, follow > today { return .waiting }
            return .nudge
        }
        if let due = item.due {
            let delta = today.days(to: due)
            switch delta {
            case ..<0: return .overdue
            case 0: return .today
            case 1...7: return .next7
            default: return .later
            }
        }
        return .noDeadline
    }

    public init(items: [Item], log: [LogEntry], today: CalendarDate, timeZone: TimeZone) {
        var doneItems: [Item] = []
        for item in items {
            switch Self.bucket(for: item, today: today) {
            case nil: hiddenCount += 1
            case .recentlyClosed?: doneItems.append(item)
            case let bucket?: self.items[bucket, default: []].append(item)
            }
        }
        for (bucket, list) in self.items {
            self.items[bucket] = list.sorted(by: Self.order(for: bucket))
        }

        let window = today.adding(days: -6)
        var dated: [ClosedEntry] = []
        for entry in log {
            guard entry.isClosure, let date = entry.closingDate(timeZone: timeZone, today: today),
                  date >= window else { continue }
            dated.append(ClosedEntry(title: entry.title, idText: entry.closedIDText,
                                     action: entry.action ?? "done", closedOn: date))
        }
        dated.sort {
            if $0.closedOn != $1.closedOn { return $0.closedOn! > $1.closedOn! }
            return Self.textLess($0.idText, $1.idText)
        }
        let undated = doneItems
            .sorted {
                $0.titleSortKey != $1.titleSortKey ? Self.textLess($0.titleSortKey, $1.titleSortKey)
                    : Self.textLess($0.idText, $1.idText)
            }
            .map { ClosedEntry(title: $0.title, idText: $0.idText, action: "done", closedOn: nil) }
        closed = dated + undated
    }

    static func textLess(_ a: String, _ b: String) -> Bool {
        let x = Array(a.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
        let y = Array(b.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
        return x.lexicographicallyPrecedes(y)
    }

    static func priorityRank(_ item: Item) -> Int { item.priority?.rank ?? 3 }

    /// Sort orders of teka-v0 §5.2.
    static func order(for bucket: Bucket) -> (Item, Item) -> Bool {
        func tail(_ a: Item, _ b: Item) -> Bool? {
            if priorityRank(a) != priorityRank(b) { return priorityRank(a) < priorityRank(b) }
            if a.titleSortKey != b.titleSortKey { return textLess(a.titleSortKey, b.titleSortKey) }
            if a.idText != b.idText { return textLess(a.idText, b.idText) }
            return nil
        }
        switch bucket {
        case .nudge, .waiting:
            return { a, b in
                switch (a.followUpAt, b.followUpAt) {
                case (nil, .some): return true
                case (.some, nil): return false
                case let (x?, y?) where x != y: return x < y
                default: return tail(a, b) ?? false
                }
            }
        case .noDeadline:
            return { a, b in tail(a, b) ?? false }
        default:
            return { a, b in
                switch (a.due, b.due) {
                case (.some, nil): return true
                case (nil, .some): return false
                case let (x?, y?) where x != y: return x < y
                default: return tail(a, b) ?? false
                }
            }
        }
    }
}

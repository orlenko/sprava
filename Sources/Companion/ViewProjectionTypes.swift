import Foundation
import SpravaKit

public enum CompanionViewBucket: String, CaseIterable, Sendable {
    case overdue, today, next7Days = "next_7_days", later, noDeadline = "no_deadline", nudge, waiting
}
/// Already read under the binder's write lock by a higher adapter. Buckets and recently closed order belong there.
/// `name` is the adapter's resolved meta.name/folder-name fallback. This value carries no paths or file bytes.
public struct CompanionViewReading: Sendable {
    public let name: String
    public let description: JSONValue?
    public let today: String
    public let generatedAt: String
    public let openItems: [JSONValue]
    public let recentlyClosed: [JSONValue]
    public let documents: [JSONValue]
    public let buckets: [CompanionViewBucket: [JSONValue]]
    public init(name: String, description: JSONValue? = nil, today: String, generatedAt: String,
                openItems: [JSONValue], recentlyClosed: [JSONValue] = [], documents: [JSONValue] = [],
                buckets: [CompanionViewBucket: [JSONValue]] = [:]) {
        self.name = name; self.description = description; self.today = today; self.generatedAt = generatedAt
        self.openItems = openItems; self.recentlyClosed = recentlyClosed; self.documents = documents; self.buckets = buckets
    }
}
public struct CompanionItemSnapshot: Sendable {
    public let id: JSONValue
    public let hash: String
    public let changedIn: Int64
}
public struct CompanionViewHistory: Sendable {
    public let binderID: String
    public let version: Int64
    public let items: [CompanionItemSnapshot]
}
public struct CompanionProjectionIssue: Sendable {
    public enum Reason: String, Sendable { case invalidID, duplicateID, invalidRecord, invalidDocument }
    public let reason: Reason
    /// Only a validated item id, never a rejected value or title. Logs use reason counts, not this field.
    public let id: JSONValue?
}
public struct CompanionProjectedView: Sendable {
    /// Ephemeral plaintext; persistence stores only sealed bytes and this record's hashes/high-water marks.
    public let plaintext: Data
    public let history: CompanionViewHistory
    public let notesOmitted: Bool
    public let issues: [CompanionProjectionIssue]
}
public enum CompanionViewProjectionError: Error, Equatable { case invalid, tooLarge }

enum ProjectionID: Hashable {
    case number(Int64), text(Data)
    static func parse(_ value: JSONValue?) -> ProjectionID? {
        if let number = value?.numberValue, let n = number.safeInteger, n != 0, number.text == String(n) { return .number(n) }
        guard let text = value?.stringValue, !text.isEmpty, text.unicodeScalars.prefix(201).count <= 200,
              JSONWriter.compact(.string(text)).utf8.count - 2 <= 800 else { return nil }
        return .text(Data(text.utf8)) // Swift String equality normalizes; protocol ids do not.
    }
}

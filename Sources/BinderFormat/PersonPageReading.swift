import Foundation
import SpravaKit

/// A person's reading belongs to one physical page of one revision of a filed document.
public struct PersonPageReading: Equatable, Sendable {
    public static let catalogField = "person_page_readings"
    public static let maximumTextBytes = 16 * 1024
    public let revision: String
    public let page: Int
    public let text: String
    public var searchable: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public init?(revision: String, page: Int, text: String) {
        guard revision.utf8.count == 64, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              (1...2_000).contains(page), text.utf8.count <= Self.maximumTextBytes else { return nil }
        self.revision = revision; self.page = page; self.text = text
    }

    public var json: JSONValue {
        .obj([("revision", .str(revision)), ("page", .int(page)), ("text", .str(text))])
    }

    /// Refuse malformed or excessive records together: editing one must never erase an unrecognized sibling.
    public static func list(in document: JSONValue) -> [Self]? {
        guard let stored = document[catalogField] else { return [] }
        guard let values = stored.arrayValue, values.count <= 2_000 else { return nil }
        var entries: [Self] = [], seen: [String: Set<Int>] = [:], bytes = 0
        for value in values {
            guard let fields = value.objectValue, fields.entries.count == 3,
                  let revision = value["revision"]?.stringValue, let page = value["page"]?.numberValue?.safeInteger,
                  let text = value["text"]?.stringValue, let entry = Self(revision: revision, page: Int(page), text: text),
                  seen[revision, default: []].insert(entry.page).inserted else { return nil }
            bytes += text.utf8.count
            guard bytes <= 1_048_576 else { return nil }
            entries.append(entry)
        }
        return entries
    }
}

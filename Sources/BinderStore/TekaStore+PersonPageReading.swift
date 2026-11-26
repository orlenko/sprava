import BinderFormat
import CryptoKit
import Foundation
import SpravaKit

extension TekaStore {
    /// Check the document and the last reading under the same writer lock as the catalog change.
    public func savePageReading(_ reading: PersonPageReading, documentID: JSONValue, path: String,
                                expected: String?, now: Date = Date()) throws {
        guard ItemID(documentID) != nil, DocumentPaths.isSafe(path, forFiling: false), !DocumentPaths.isKeyFile(path) else {
            throw Refused(reason: "This document cannot be identified safely.")
        }
        try apply(building: { catalog, _ in
            let matches = (catalog["documents"]?.arrayValue ?? []).filter { $0["id"] == documentID }
            guard matches.count == 1, let document = matches.first, document["path"] == .str(path),
                  case .ok(let bytes) = SafeFile.read(folder.appendingPathComponent(path), under: folder, limit: 200 << 20),
                  SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == reading.revision else {
                throw Refused(reason: "The document changed or cannot be opened. Check the page again.")
            }
            guard var entries = PersonPageReading.list(in: document) else {
                throw Refused(reason: "The saved page readings could not be read safely.")
            }
            let position = entries.firstIndex { $0.revision == reading.revision && $0.page == reading.page }
            let prior = position.map { entries[$0].text }
            if prior == reading.text { return [] }
            guard prior == expected else { throw Refused(reason: "Someone edited this page reading. Reopen the page before saving.") }
            if let position { entries[position] = reading } else { entries.append(reading) }
            let field = PersonPageReading.catalogField
            let set = JSONValue.obj([(field, .array(entries.map(\.json)))])
            guard PersonPageReading.list(in: set) != nil else { throw Refused(reason: "This document has reached its page reading limit.") }
            return [.init(op: "update_document", args: .init([(key: "id", value: documentID), (key: "set", value: set)]),
                          actor: .init([(key: "kind", value: .str("user")), (key: "client", value: .str(client))]))]
        }, now: now)
    }
}

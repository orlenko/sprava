import Foundation
import SpravaKit

/// Model output is display data, never an operation or mail send. Only source ids selected by the
/// runtime may become citation paths. The app separately confirms any editable task suggestion.
enum ClaudeBinderReply {
    static func normalize(_ raw: String, sources: [ClaudeBinderContext.Source]) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```json\n"), text.hasSuffix("```") { text = String(text.dropFirst(8).dropLast(3)) }
        guard let parsed = try? JSONParser.parse(text), parsed.safety.isSafe,
              let object = parsed.value.objectValue, let answer = object["answer"]?.stringValue, !answer.isEmpty else {
            return JSONWriter.compact(.obj([("answer", .str(raw)), ("citations", .array([])), ("task", .null), ("draft", .null)]))
        }
        let ids = object["citations"]?.arrayValue?.compactMap(\.stringValue) ?? []
        var seen = Set<String>()
        let citations = ids.prefix(20).compactMap { id -> JSONValue? in
            guard seen.insert(id).inserted, let source = sources.first(where: { $0.id == id }) else { return nil }
            return .obj([("id", .str(id)), ("path", .str(source.path)), ("page", source.page.map(JSONValue.int) ?? .null), ("revision", .str(source.revision))])
        }
        let task: JSONValue
        if let title = object["task"]?["title"]?.stringValue, valid(title, limit: 512, oneLine: true),
           let details = object["task"]?["details"]?.stringValue, valid(details, limit: 8_192, oneLine: false, empty: true) {
            let due = object["task"]?["due"]?.stringValue.map { String($0.prefix(64)) }
            let priority = object["task"]?["priority"]?.stringValue ?? "normal"
            task = .obj([("title", .str(title)), ("details", .str(details)), ("due", due.map(JSONValue.str) ?? .null),
                         ("priority", .str(["high", "normal", "low"].contains(priority) ? priority : "normal"))])
        } else { task = .null }
        let draft: JSONValue
        if let to = object["draft"]?["to"]?.stringValue, valid(to, limit: 512, oneLine: true),
           let subject = object["draft"]?["subject"]?.stringValue, valid(subject, limit: 1_024, oneLine: true),
           let body = object["draft"]?["body"]?.stringValue, valid(body, limit: 32_768, oneLine: false) {
            // Only the first source From header can corroborate the proposed recipient, never an
            // arbitrary address elsewhere in a quoted body. This still does not prove sender identity.
            let grounded = sources.contains { source in
                guard let from = source.text.split(separator: "\n").first(where: { $0.lowercased().hasPrefix("from:") }) else { return false }
                return from.range(of: to, options: [.caseInsensitive]) != nil
            }
            draft = .obj([("to", .str(to)), ("subject", .str(subject)), ("body", .str(body)), ("recipient_in_sources", .bool(grounded))])
        } else { draft = .null }
        return JSONWriter.compact(.obj([("answer", .str(answer)), ("citations", .array(citations)), ("task", task), ("draft", draft)]))
    }
    private static func valid(_ text: String, limit: Int, oneLine: Bool, empty: Bool = false) -> Bool {
        guard text.utf8.count <= limit, empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return !text.unicodeScalars.contains {
            CharacterSet.controlCharacters.contains($0) && (oneLine || !["\n", "\t"].contains(String($0)))
        }
    }
}

import BinderFormat
import Foundation
import SpravaKit

/// What a turn is doing, in a few words the person can read while it runs. It lives in memory for the turn only: never
/// logged, never saved and never sent to the model. A tool's input comes from the model and may repeat what a document
/// says, so what is taken from it is made one short line, and it is only ever displayed as text.
package struct ClaudeTurnActivity: Sendable, Equatable {
    package private(set) var doing: String?
    package private(set) var steps = 0

    package init() {}

    mutating func saw(_ blocks: [JSONValue]) {
        for block in blocks {
            if block["type"] == .str("tool_use"), let name = block["name"]?.stringValue {
                steps += 1
                doing = Self.words(tool: name, input: block["input"])
            } else if block["type"] == .str("text") {
                doing = "Writing"
            } else if block["type"] == .str("thinking") || block["type"] == .str("redacted_thinking") {
                doing = "Thinking"
            }
        }
    }

    mutating func toolFinished() { doing = "Thinking" }

    static func words(tool: String, input: JSONValue?) -> String {
        let file = (input?["file_path"]?.stringValue).map { (($0 as NSString).lastPathComponent) }.flatMap { $0.isEmpty ? nil : short(DocumentPaths.safeName($0), 60) }
        switch tool {
        case "Read": return file.map { "Reading \u{201C}\($0)\u{201D}" } ?? "Reading a file"
        case "Write", "Edit": return file.map { "Changing \u{201C}\($0)\u{201D}" } ?? "Changing a file"
        case "Glob": return "Looking through the folders"
        case "Grep": return "Searching the binder"
        case "Bash": return input?["description"]?.stringValue.flatMap { let said = short($0, 90); return said.isEmpty ? nil : said } ?? "Running a command"
        case _ where tool.hasSuffix("search_binder"): return "Searching the documents"
        case _ where tool.hasSuffix("update_notes"): return "Updating the notes"
        case _ where tool.contains(ClaudeAppTools.server): return "Updating the to-dos"
        default: return "Working"
        }
    }

    /// One line: no control or direction character, runs of space closed up, cut at a character's edge.
    private static func short(_ text: String, _ limit: Int) -> String {
        var scalars = String.UnicodeScalarView()
        for s in text.unicodeScalars {
            let c = s.properties.generalCategory
            scalars.append(c == .control || c == .format || c == .lineSeparator || c == .paragraphSeparator ? " " : s)
        }
        let line = String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return line.count > limit ? String(line.prefix(limit)) + "\u{2026}" : line
    }
}

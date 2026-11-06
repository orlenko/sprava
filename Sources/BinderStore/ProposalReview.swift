import BinderFormat
import Foundation
import SpravaKit

extension Proposal {
    /// Set on an item read from text where the clerk hit its limit: there may be more than it listed. The clerk sits
    /// above this target and writes the same words as `Clerk.cappedFlag`; `CappedFlagTests` holds the two together.
    public static let cappedFlag = "the clerk may have missed items here"

    /// Reasons for a careful reading that say nothing about the list being incomplete. Any other reason, known or new,
    /// counts as "the clerk may have missed something", the safe reading of a reason this code has not met.
    private static let quietReasons: Set<String> = ["it sets rules or obligations", "it is long",
                                                    "the clerk is not sure what it is", "a reply may be needed"]

    /// What a review card shows the person, as facts for the app to lay out: the document, what approving does, and
    /// only the warnings that can change the decision. `describe` gives one op's plain line; `changed` names what
    /// changed in the binder since the card was made. Everything else stays in the card's `lines` and `notes`.
    public func review(describe: (JSONObject) -> String, changed: [String] = []) -> JSONObject {
        let provenance = raw["provenance"]
        let intake = provenance?["intake"]
        let reading = provenance?["reading"]
        let held = intake?["held"]?.stringValue

        var files: [JSONValue] = []
        var todos: [JSONValue] = []
        var changes: [JSONValue] = []
        var heading: String?
        var date: String?
        for (index, op) in ops.enumerated() {
            let args = op["args"]
            if op["op"] == .str("file_document"), let from = args?["from"]?.stringValue {
                let document = args?["document"]
                if files.isEmpty {
                    heading = document?["title"]?.stringValue
                    date = document?["date"]?.stringValue
                }
                files.append(.obj([("path", .string(from)), ("name", .string((from as NSString).lastPathComponent)),
                                   ("kind", document?["kind"] ?? .str("document"))]))
            } else if op["op"] == .str("add_item"), let item = args?["item"] {
                todos.append(.obj([("index", .int(index)), ("title", item["title"] ?? .str("")), ("due", item["due"] ?? .str("")),
                                   ("priority", item["priority"] ?? .str("normal")), ("notes", Self.strings(Self.itemNotes(op)))]))
            } else {
                changes.append(.obj([("index", .int(index)), ("line", .string(describe(op))), ("notes", Self.strings(Self.itemNotes(op)))]))
            }
        }

        var out = JSONObject()
        let manual = ops.isEmpty || provenance?["manual_repair"] == .bool(true)
        out.set("kind", .string(manual ? "manual" : files.isEmpty ? "change" : "filing"))
        if let heading { out.set("heading", .string(heading)) }
        if let date { out.set("date", .string(date)) }
        if let sender = intake?["obtained"]?["from"]?.stringValue { out.set("sender", .string(sender)) }
        out.set("from_intake", .bool(intake != nil))
        // A file that was held was not read, so nothing may look like a reading of it.
        if held == nil {
            if let summary = reading?["summary"]?.stringValue {
                out.set("summary", .string(summary))
                // Who wrote the summary: the clerk, unless an engine read the document in its place (decisions.md D40).
                if let by = Self.reader(of: reading) { out.set("summary_by", .string(by)) }
            }
            else if let begins = intake?["preview"]?.stringValue { out.set("begins", .string(begins)) }
        }
        out.set("files", .array(files))
        out.set("todos", .array(todos))
        out.set("changes", .array(changes))
        out.set("warnings", Self.strings(warnings(changed: changed)))
        return out
    }

    /// What the person should know before deciding, each said once and in the order it matters.
    func warnings(changed: [String]) -> [String] {
        let provenance = raw["provenance"]
        let intake = provenance?["intake"]
        let reading = provenance?["reading"]
        func quoted(_ key: String) -> String? {
            let list = provenance?[key]?.arrayValue?.compactMap(\.stringValue) ?? []
            return list.isEmpty ? nil : list.map { "\u{201C}\($0)\u{201D}" }.joined(separator: ", ")
        }
        var out: [String] = []
        if !changed.isEmpty { out.append("The binder changed since this card was made: " + changed.joined(separator: ", ")) }
        if let held = intake?["held"]?.stringValue { out.append("Sprava did not read this file: \(held). You can file it as it is, or take it out of intake.") }
        let reasons = provenance?["escalate"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let capped = ops.contains { $0["card"]?["flags"]?.arrayValue?.contains(.string(Self.cappedFlag)) == true }
        let unread = (reading?["unread_windows"]?.numberValue?.safeInteger ?? 0) > 0
        let dropped = (provenance?["dropped_items"]?.numberValue?.safeInteger ?? 0) > 0
        if capped || unread || dropped || reasons.contains(where: { !Self.quietReasons.contains($0) }) {
            out.append("The clerk may have missed things in this. Read it before relying on this list.")
        }
        if reading?["reply_needed"] == .bool(true) || reasons.contains("a reply may be needed") { out.append("A reply may be needed.") }
        if let left = quoted("left_out") { out.append("Not added, type them by hand: \(left)") }
        if let remains = provenance?["remains"]?.stringValue { out.append("Still kept elsewhere: \(remains)") }
        if intake?["text_from"] == .str("ocr") { out.append("Read from a scan: check names and numbers against the file.") }
        if intake?["mismatch"] == .bool(true) { out.append("Its name says one kind of file and its contents another.") }
        out += intake?["notes"]?.arrayValue?.compactMap(\.stringValue) ?? []
        if let already = quoted("already_in_binder") { out.append("Already in the binder, so not added: \(already)") }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// One op's own notes, beside its line: its flags without the capped one, which the card says once, its guess,
    /// a possible duplicate, and time words that did not become a date. Why it chose the binder stays in the details.
    static func itemNotes(_ op: JSONObject) -> [String] {
        guard let card = op["card"]?.objectValue else { return [] }
        var out = (card["flags"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter { $0 != cappedFlag }
        if let guess = card["guess"]?.stringValue { out.append("the clerk's guess: \(guess) (not sure)") }
        if let related = card["related"]?.stringValue { out.append("possibly related to \u{201C}\(related)\u{201D}") }
        if let when = card["when_text"]?.stringValue { out.append("\u{201C}\(when)\u{201D} was not turned into a date; type one") }
        return out
    }

    private static func strings(_ list: [String]) -> JSONValue { .array(list.map(JSONValue.string)) }
}

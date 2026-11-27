import BinderFormat
import Foundation
import SpravaKit

/// A suggestion for Sprava itself as a card proposes it (decisions.md D47): what a binder could not do, or keeps doing
/// by hand, with the script that does it now when there is one. On the draft card's pattern: the text rides in the
/// card's provenance, and the card's one op is a log entry in the binder it came from that holds none of the text.
/// The person's approval carries the text to the Improvements binder as a to-do; the session that wrote the card
/// never reaches that binder.
public struct SuggestionCard: Sendable, Equatable {
    public struct Script: Sendable, Equatable {
        /// The script's path in the binder, as the card names it.
        public var path: String
        /// Its text as it was when the card was made.
        public var text: String
        public init(path: String, text: String) { self.path = path; self.text = text }
    }

    public var title: String
    public var attempted: String
    public var obstacle: String
    public var script: Script?

    public struct Refused: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static let maxTitle = 200, maxPart = 4_000
    /// The largest script a card carries, in bytes, and the longest text a suggestion is sent with, in characters.
    public static let maxScript = 32 * 1024, maxNote = 48_000

    public init(title: String, attempted: String, obstacle: String, script: Script? = nil) {
        self.title = title; self.attempted = attempted; self.obstacle = obstacle; self.script = script
    }

    /// The card's fields, when this proposal is exactly the card `proposal` makes from them.
    public init?(_ proposal: Proposal) {
        guard let s = proposal.raw["provenance"]?["suggestion"], let title = s["title"]?.stringValue,
              let attempted = s["attempted"]?.stringValue, let obstacle = s["obstacle"]?.stringValue else { return nil }
        var script: Script?
        if let found = s["script"] {
            guard let path = found["path"]?.stringValue, let text = found["text"]?.stringValue else { return nil }
            script = Script(path: path, text: text)
        }
        self.init(title: title, attempted: attempted, obstacle: obstacle, script: script)
        guard proposal.ops == [Self.logOp], proposal.raw["title"]?.stringValue == Self.cardTitle else { return nil }
    }

    static let cardTitle = "A suggestion for Sprava"

    static var logOp: JSONObject {
        let entry = JSONObject([(key: "action", value: .str("Sent a suggestion to Improvements"))])
        return JSONObject([(key: "op", value: .str("add_log_entry")), (key: "args", value: .obj([("entry", .object(entry))]))])
    }

    /// Text a person can read whole: no control characters but line breaks and tabs, nothing that reorders or hides text.
    private static func isPlain(_ text: String) -> Bool {
        !text.unicodeScalars.contains { scalar in
            if scalar == "\n" || scalar == "\t" { return false }
            return CharacterSet.controlCharacters.contains(scalar) || (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value)
        }
    }

    /// The extensions a script outside `scripts/` is known by.
    static let scriptExtensions: Set<String> = ["py", "sh", "zsh", "bash", "rb", "js", "mjs", "ts", "pl", "swift", "applescript", "sql", "awk", "jq", "lua", "php", "r"]

    /// Whether `path` names a file a card may carry as a script: a path inside the binder with no hidden or dotted
    /// segment (so never `.sprava`, `..` or a dot file), not under `intake/`, where files arrive from outside, never a
    /// key or credential file, and either under `scripts/` or named as a script. A document's text is not a script's:
    /// the card would carry it to another binder.
    public static func isScriptPath(_ path: String) -> Bool {
        guard !path.isEmpty, path.unicodeScalars.count <= 1_024, !path.hasPrefix("/") else { return false }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.allSatisfy({ segment in
            !segment.isEmpty && !segment.hasPrefix(".") && !segment.hasPrefix("~") && !segment.contains("\\")
                && !segment.unicodeScalars.contains { $0.properties.generalCategory == .control || $0.properties.generalCategory == .format }
        }) else { return false }
        let first = segments[0].lowercased()
        guard first != "intake", !DocumentPaths.isKeyFile(path) else { return false }
        return (first == "scripts" && segments.count > 1) || scriptExtensions.contains((path as NSString).pathExtension.lowercased())
    }

    /// Why a title cannot be a suggestion's, in plain words; nil when it can: one line of plain text.
    public static func problem(title: String) -> String? {
        let text = title.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "A suggestion needs a title." }
        if text.count > maxTitle || text.contains(where: \.isNewline) || !isPlain(text) || text.contains("\t") {
            return "A suggestion's title is one line of plain text, at most \(maxTitle) characters."
        }
        return nil
    }

    /// Why a text cannot be sent as a suggestion, in plain words; nil when it can. For the card's own text and for the
    /// person's edit of it.
    public static func problem(note: String) -> String? {
        if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "A suggestion needs some text." }
        if note.count > maxNote { return "A suggestion is at most \(maxNote) characters." }
        if !isPlain(note) { return "A suggestion is plain text." }
        return nil
    }

    /// The fields as a card may carry them.
    public func checked() throws -> SuggestionCard {
        if let problem = Self.problem(title: title) { throw Refused(description: problem) }
        var out = self
        out.title = title.trimmingCharacters(in: .whitespaces)
        out.attempted = attempted.trimmingCharacters(in: .whitespacesAndNewlines)
        out.obstacle = obstacle.trimmingCharacters(in: .whitespacesAndNewlines)
        for part in [out.attempted, out.obstacle] {
            guard !part.isEmpty, part.count <= Self.maxPart, Self.isPlain(part) else {
                throw Refused(description: "Say what was attempted, and what stood in the way or keeps being repeated, each in plain text of at most \(Self.maxPart) characters.")
            }
        }
        if let script {
            guard Self.isScriptPath(script.path) else {
                throw Refused(description: "The script is not one a card may carry: a script inside the binder, under scripts/ or named as one, that is no key or credential file.")
            }
            guard script.text.utf8.count <= Self.maxScript, Self.isPlain(script.text) else {
                throw Refused(description: "The script is over \(Self.maxScript / 1024) KiB or is not plain text.")
            }
        }
        if let problem = Self.problem(note: out.note) { throw Refused(description: problem) }
        return out
    }

    /// The whole text as the card shows it and, unless the person edits it, as the to-do in Improvements holds it.
    public var note: String {
        var text = "What was attempted:\n\(attempted)\n\nWhat stood in the way, or keeps being repeated:\n\(obstacle)\n"
        if let script { text += "\nThe script \(script.path), as it was when this was suggested:\n\n\(script.text)" }
        if !text.hasSuffix("\n") { text += "\n" }
        return text
    }

    /// Whether a text holds what looks like a key or a password. Until secrets for scripts are built
    /// (docs/conversation.md §18.3.2) a script may carry one inline, and a suggestion is exported as plain text, so the
    /// card warns. It errs towards warning: the person reads the text either way.
    public static func looksLikeItHoldsAKey(_ text: String) -> Bool {
        let patterns = [
            #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#,
            #"\b(sk|pk|rk)[-_][A-Za-z0-9_\-]{20,}"#,
            #"\bAKIA[0-9A-Z]{16}\b"#,
            #"\bgh[pousr]_[A-Za-z0-9]{30,}"#,
            #"\bgithub_pat_[A-Za-z0-9_]{30,}"#,
            #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#,
            #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\."#,
            #"(?i)\bbearer\s+[A-Za-z0-9_\-.=]{20,}"#,
            #"(?i)(api[_-]?key|secret|token|passw(or)?d|credential)[A-Za-z0-9_]*["']?\s*[:=]\s*["']?[A-Za-z0-9_\-/+=.]{12,}"#,
        ]
        let range = NSRange(text.startIndex..., in: text)
        return patterns.contains { pattern in
            (try? NSRegularExpression(pattern: pattern))?.firstMatch(in: text, range: range) != nil
        }
    }

    /// The card; the caller writes it to the binder's cards and records it as one Sprava wrote.
    public func proposal(actor: JSONObject, now: Date = Date()) throws -> Proposal {
        let card = try checked()
        var fields = JSONObject([(key: "title", value: .string(card.title)), (key: "attempted", value: .string(card.attempted)),
                                 (key: "obstacle", value: .string(card.obstacle))])
        if let script = card.script { fields.set("script", .obj([("path", .string(script.path)), ("text", .string(script.text))])) }
        return Proposal.make(title: Self.cardTitle, actor: actor, ops: [Self.logOp], provenance: JSONObject([(key: "suggestion", value: .object(fields))]), now: now)
    }
}

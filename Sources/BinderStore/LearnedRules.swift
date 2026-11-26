import BinderFormat
import Foundation
import SpravaKit

/// Rules a binder learns from its work (decisions.md D46; docs/binder-instructions.md §4.4): each one a dated line the
/// person accepted, under a `## Learned rules` heading in their part of `AGENTS.md`, where they can edit or remove it.
/// The text logic only; `BinderInstructions.save` writes.
public enum LearnedRules {
    public static let heading = "## Learned rules"
    /// The longest rule, in characters.
    public static let maxRule = 500
    public static let maxReason = 1_000

    /// What a rule is about; the card says so.
    public enum About: String, CaseIterable, Sendable { case filing, drafting, routine }

    /// Why a text cannot be a rule, in plain words; nil when it can. A rule is one line, with nothing a program reads
    /// from `AGENTS.md`: Sprava's marker lines and lifeproj's addendum marker are HTML comments, so a rule holds none.
    public static func problem(_ rule: String) -> String? {
        let text = rule.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return "A rule needs some text." }
        if rule != text { return "A rule has no space before or after it." }
        if text.count > maxRule { return "A rule is at most \(maxRule) characters." }
        if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) || isDirectional($0) }) {
            return "A rule is one line of plain text."
        }
        if text.contains("<!--") || text.contains("-->") { return "A rule holds no comment markers (<!-- or -->)." }
        return nil
    }

    /// Characters that reorder or hide text, so a rule reads as it is written.
    private static func isDirectional(_ scalar: Unicode.Scalar) -> Bool {
        (0x202A...0x202E).contains(scalar.value) || (0x2066...0x2069).contains(scalar.value) || [0x200E, 0x200F, 0x061C, 0xFEFF].contains(scalar.value)
    }

    /// The line a rule is written as.
    public static func line(_ rule: String, on day: CalendarDate) -> String { "- \(day): \(rule)" }

    /// The person's part with the rule added as the last line under the heading, which is added at the end when it is
    /// not there. A part that already holds this rule under the heading, on any date, comes back as it is, so an
    /// accept that is tried again adds nothing twice. Lines keep their bytes; a heading inside a fenced block is text,
    /// and a block left open runs to the end, as it does when the text is shown.
    public static func adding(_ rule: String, on day: CalendarDate, to text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        // The text's last line break leaves an empty last element; it is put back at the end.
        let endsWithBreak = lines.last == "" && lines.count > 1
        if endsWithBreak { lines.removeLast() }
        if text.isEmpty { lines = [] }
        func bare(_ line: String) -> String { line.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r")) }
        // A fenced block opens with three or more of one mark and closes with a line of at least as many of the same
        // mark and nothing else, so a fence of the other mark, or a shorter one, inside it is text.
        var fence: (mark: Character, count: Int)?, start: Int?, end: Int?
        for (n, line) in lines.enumerated() {
            let b = bare(line)
            if let mark = b.first, mark == "`" || mark == "~" {
                let count = b.prefix(while: { $0 == mark }).count
                if let open = fence {
                    if mark == open.mark, count >= open.count, count == b.count { fence = nil }
                    continue
                }
                if count >= 3 { fence = (mark, count); continue }
            }
            guard fence == nil else { continue }
            if start == nil, b == heading { start = n; continue }
            // The section ends at the next heading of its level or above.
            if start != nil, end == nil, b.hasPrefix("# ") || b.hasPrefix("## ") || b == "#" || b == "##" { end = n }
        }
        let new = line(rule, on: day)
        guard let start else {
            while let last = lines.last, bare(last).isEmpty { lines.removeLast() }
            if !lines.isEmpty { lines.append("") }
            return (lines + [heading, "", new]).joined(separator: "\n") + "\n"
        }
        let stop = end ?? lines.count
        let suffix = ": " + rule
        if lines[(start + 1)..<stop].contains(where: { line in
            let b = bare(line)
            return b.hasPrefix("- ") && b.hasSuffix(suffix) && CalendarDate.strict(String(b.dropFirst(2).dropLast(suffix.count))) != nil
        }) { return text }
        // After the section's last line with text, or right under the heading after one empty line.
        var at = stop
        while at > start + 1, bare(lines[at - 1]).isEmpty { at -= 1 }
        var added = at == start + 1 ? ["", new] : [new]
        // An empty line between the rule and a heading that follows.
        if at < lines.count || end != nil { if at == lines.count || !bare(lines[at]).isEmpty { added.append("") } }
        lines.insert(contentsOf: added, at: at)
        return lines.joined(separator: "\n") + (endsWithBreak || end == nil ? "\n" : "")
    }
}

/// A rule as a card proposes it (decisions.md D46), on the draft card's pattern: the rule rides in the card's
/// provenance, and the card's one op is a log entry that says a rule was accepted and what it is about, never its text.
/// Nothing is written to `AGENTS.md` until the person accepts the card.
public struct RuleCard: Sendable, Equatable {
    public var rule: String
    public var reason: String
    public var about: LearnedRules.About

    public struct Refused: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public init(rule: String, reason: String, about: LearnedRules.About) {
        self.rule = rule; self.reason = reason; self.about = about
    }

    /// The card's fields, when this proposal is exactly the card `proposal` makes from them: nothing else rides along.
    public init?(_ proposal: Proposal) {
        guard let r = proposal.raw["provenance"]?["rule"], let rule = r["text"]?.stringValue, let reason = r["reason"]?.stringValue,
              let about = r["about"]?.stringValue.flatMap(LearnedRules.About.init(rawValue:)) else { return nil }
        self.init(rule: rule, reason: reason, about: about)
        guard proposal.ops == [Self.logOp(about: about)], proposal.raw["title"]?.stringValue == Self.title(about: about) else { return nil }
    }

    static func title(about: LearnedRules.About) -> String { "A rule for \(about.rawValue)" }

    static func logOp(about: LearnedRules.About) -> JSONObject {
        let entry = JSONObject([(key: "action", value: .string("Accepted a rule for \(about.rawValue)"))])
        return JSONObject([(key: "op", value: .str("add_log_entry")), (key: "args", value: .obj([("entry", .object(entry))]))])
    }

    /// The fields as a card may carry them: a rule `LearnedRules` takes, and a reason of one paragraph.
    public func checked() throws -> RuleCard {
        if let problem = LearnedRules.problem(rule) { throw Refused(description: problem) }
        let why = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !why.isEmpty, why.count <= LearnedRules.maxReason,
              !why.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }) else {
            throw Refused(description: "A rule's reason is plain text of at most \(LearnedRules.maxReason) characters.")
        }
        return RuleCard(rule: rule, reason: why, about: about)
    }

    /// The card; the caller writes it to the binder's cards and records it as one Sprava wrote.
    public func proposal(actor: JSONObject, now: Date = Date()) throws -> Proposal {
        let card = try checked()
        let rule = JSONObject([(key: "text", value: .string(card.rule)), (key: "reason", value: .string(card.reason)),
                               (key: "about", value: .string(card.about.rawValue))])
        return Proposal.make(title: Self.title(about: card.about), actor: actor, ops: [Self.logOp(about: card.about)],
                             provenance: JSONObject([(key: "rule", value: .object(rule))]), now: now)
    }
}

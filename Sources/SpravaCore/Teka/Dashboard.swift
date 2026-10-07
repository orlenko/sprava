import CryptoKit
import Foundation

/// The rendered `DASHBOARD.md` (binder-v0 §7.1): the same inputs give the same bytes; the Notes section is kept
/// byte for byte; a marker line hashes everything above Notes so an edit outside Notes is noticed.
public enum Dashboard {
    public static let notesLine = "## Notes"

    /// Every catalog string is escaped: newlines and tabs to spaces, control and bidirectional characters removed,
    /// Markdown punctuation backslashed, so no raw HTML or remote image ever comes from the catalog.
    public static func escape(_ s: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D, 0x09: out.append(" ")
            case 0x00...0x1F, 0x7F...0x9F, 0x202A...0x202E, 0x2066...0x2069: continue
            default:
                if "\\`*_[]()<>!#|".unicodeScalars.contains(scalar) { out.append("\\") }
                out.append(scalar)
            }
        }
        return String(out)
    }

    /// An id as a CommonMark code span: a fence one backtick longer than the longest run inside.
    public static func codeSpan(_ id: String) -> String {
        var longest = 0, run = 0
        for c in id { if c == "`" { run += 1; longest = max(longest, run) } else { run = 0 } }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = id.hasPrefix("`") || id.hasSuffix("`") ? " " : ""
        return fence + pad + id + pad + fence
    }

    static func relative(_ date: CalendarDate, today: CalendarDate) -> String {
        let n = today.days(to: date)
        switch n {
        case 0: return "today"
        case 1: return "tomorrow"
        case -1: return "yesterday"
        case 2...: return "in \(n) days"
        default: return "\(-n) days ago"
        }
    }

    static func tail(_ item: Item) -> String {
        var s = item.priority?.rawValue ?? (item.object?["priority"]?.stringValue.map(escape) ?? "normal")
        if !item.contexts.isEmpty { s += " · " + item.contexts.map(escape).joined(separator: " ") }
        if !item.tags.isEmpty { s += " · " + item.tags.map(escape).joined(separator: " ") }
        return s
    }

    static func line(_ item: Item, bucket: Bucket, today: CalendarDate) -> String {
        let head = "- \(codeSpan(item.idText)) \(escape(item.title))"
        switch bucket {
        case .noDeadline:
            return "\(head) · no deadline · \(tail(item))"
        case .nudge, .waiting:
            let follow = item.followUpAt.map { "\($0) (\(relative($0, today: today)))" } ?? "not set"
            let due = item.due?.description ?? "none"
            return "\(head) · waiting on \(escape(item.waitingOn ?? "")) · follow up \(follow) · due \(due) · \(tail(item))"
        default:
            let due = item.due.map { "\($0) (\(relative($0, today: today)))" } ?? "none"
            return "\(head) · due \(due) · \(tail(item))"
        }
    }

    /// Renders the file. `notes` is the Notes section as found (from its `## Notes` line on), or nil for a new one.
    public static func render(catalog: JSONObject, folderName: String, today: CalendarDate, timeZone: TimeZone,
                              hasManual: Bool, notes: String?, impl: String) -> String {
        let teka = Teka(folder: URL(fileURLWithPath: "/"), states: [:], level: nil, catalog: catalog, safety: .init(), findings: [],
                        isAdopted: true, modified: nil)
        let page = teka.nowPage(today: today, timeZone: timeZone)
        let name = catalog["meta"]?["name"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } ?? folderName
        let items = teka.items
        let open = items.filter { $0.declaredStatus != .done && !$0.isDismissed }.count
        let hidden = items.filter(\.isDismissed).count
        let documents = catalog["documents"]?.arrayValue?.count ?? 0
        let closed7 = page.closed.filter { $0.closedOn != nil }.count

        var body = "# \(escape(name)): dashboard\n\n"
        body += "_Current truth as of \(today), regenerated from `catalog.json` by \(escape(impl)). Edit only the Notes section; the rest is overwritten._\n\n"
        body += "## At a glance\n\n"
        body += "- \(open) open items: \(page.count(.overdue)) overdue, \(page.count(.today)) due today, "
            + "\(page.count(.nudge) + page.count(.waiting)) waiting or blocked (\(page.count(.nudge)) to chase), \(hidden) hidden\n"
        body += "- \(documents) documents on file, \(closed7) closed in the last 7 days\n"
        if let chapters = catalog["meta"]?["active_chapters"]?.arrayValue?.compactMap(\.stringValue), !chapters.isEmpty {
            body += "- Active chapters: " + chapters.map(escape).joined(separator: ", ") + "\n"
        }
        for bucket in Bucket.allCases {
            body += "\n## \(bucket.title)\n\n"
            if bucket == .recentlyClosed {
                if page.closed.isEmpty { body += "_None._\n" }
                for entry in page.closed {
                    let title = entry.title.isEmpty ? "(no title)" : escape(entry.title)
                    let when = entry.closedOn.map { "\(escape(entry.action)) \($0)" } ?? "done (date unknown)"
                    body += "- \(codeSpan(entry.idText)) \(title) · \(when)\n"
                }
                continue
            }
            let list = page.items[bucket] ?? []
            if list.isEmpty { body += "_None._\n" }
            for item in list { body += line(item, bucket: bucket, today: today) + "\n" }
        }
        body += "\n## Where things live\n\n"
        let modules = catalog["meta"]?["modules"]?.arrayValue?.compactMap(\.stringValue) ?? []
        body += "- Modules: " + (modules.isEmpty ? "none" : modules.map(escape).joined(separator: ", ")) + "\n"
        if hasManual { body += "- Manual: `CLAUDE.md`\n" }
        body += "\n"
        let notesPart = notes ?? "\(notesLine)\n\n"
        let hash = SHA256.hash(data: Data(body.utf8)).map { String(format: "%02x", $0) }.joined()
        return "<!-- teka-dashboard v0 sha256:\(hash) -->\n" + body + notesPart
    }

    /// Splits a file at its first `## Notes` line: (above, notes from that line on).
    public static func split(_ text: String) -> (String, String?) {
        var offset = text.startIndex
        while offset < text.endIndex {
            let end = text[offset...].firstIndex(of: "\n") ?? text.endIndex
            if text[offset..<end] == notesLine { return (String(text[..<offset]), String(text[offset...])) }
            offset = end < text.endIndex ? text.index(after: end) : end
        }
        return (text, nil)
    }

    /// Whether a rendered file was edited outside its Notes section (or is not a rendered file at all).
    public static func editedOutsideNotes(_ text: String) -> Bool {
        guard let m = text.firstMatch(of: /^<!-- teka-dashboard v0 sha256:([0-9a-f]{64}) -->\n/) else { return true }
        let rest = String(text[m.range.upperBound...])
        let (above, _) = split(rest)
        let hash = SHA256.hash(data: Data(above.utf8)).map { String(format: "%02x", $0) }.joined()
        return hash != String(m.output.1)
    }

    /// The switch (binder-v0 §7.1): the old text moves into Notes with every heading demoted one level.
    public static func notesFromOld(_ old: String) -> String {
        let demoted = old.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            // `#` becomes `##` and so on; `######` stays as it is.
            let hashes = line.prefix { $0 == "#" }.count
            if (1...5).contains(hashes), line.dropFirst(hashes).first == " " { return "#" + String(line) }
            return String(line)
        }.joined(separator: "\n")
        return "\(notesLine)\n\n" + demoted + (demoted.hasSuffix("\n") ? "" : "\n")
    }
}

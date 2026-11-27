import BinderFormat
import Foundation
import SpravaKit

/// Document records at adoption (binder-v0 §4.3, §9.4 step 4, §9.5). lifeproj defines no fields for them, so an old
/// binder holds hand-written records: a date in another form, or no title. Each one fails the v0 rules, and one is
/// enough to keep the stamp from being offered. What code can settle without losing a value it settles; the rest goes
/// to the person on one card.
extension Adoption {
    /// The lossless fixes for one document record, as one `update_document`; nil when it needs none, or when no op can
    /// name it. Every value replaced or removed goes through `keepAside`, so it stays in the record under
    /// `legacy_<field>`:
    /// - a `date` that is null or empty is removed, since both mean absent;
    /// - a `date` in another form that names one day (compact, an ISO week date, or a date followed by a time) is
    ///   rewritten `YYYY-MM-DD`;
    /// - any other `date` (a month, a year, words) is kept aside and removed: v0 cannot read it, and `date` is optional;
    /// - a title of several lines becomes one line;
    /// - a record with no title is titled by its file's name, without the extension.
    static func documentFix(_ o: JSONObject, actor: JSONObject) -> TekaStore.OpBody? {
        guard let id = o["id"], ItemRules.isTruthy(id) else { return nil }
        var taken = o
        var set = JSONObject()
        var unset: [String] = []
        func replace(_ key: String, with value: JSONValue?) throws {
            if let aside = try keepAside(key, in: &taken, becoming: value) { set.set(aside.key, aside.value) }
            if let value { set.set(key, value) } else { unset.append(key) }
        }
        do {
            if let date = o["date"], date.stringValue.flatMap(CalendarDate.strict) == nil {
                try replace("date", with: date.stringValue.flatMap(oneDay).map { .string($0.description) })
            }
            let title = o["title"]
            let text = title?.stringValue
            if !ItemRules.isTruthy(title) || text == nil || text!.contains(where: \.isNewline) {
                let found = text.map(oneLine) ?? ""
                let name = found.isEmpty ? o["path"]?.stringValue.map(fileTitle) ?? "" : found
                // A missing or empty title holds nothing to keep; any other value is kept aside first.
                if title == nil || title == .null || title == .str("") {
                    if !name.isEmpty { set.set("title", .string(name)) }
                } else if !name.isEmpty {
                    try replace("title", with: .string(name))
                }
            }
        } catch {
            return nil
        }
        guard !set.entries.isEmpty || !unset.isEmpty else { return nil }
        var args = JSONObject()
        args.set("id", id)
        if !set.entries.isEmpty { args.set("set", .object(set)) }
        if !unset.isEmpty { args.set("unset", .array(unset.map(JSONValue.string))) }
        return .init(op: "update_document", args: args, actor: actor)
    }

    /// The fixes of every document record that needs one and that an op can name: a record whose id another record
    /// holds gets none, since the op would change whichever comes first. Each op the guard takes costs it one reading
    /// of the whole catalog and one hash of it (every op line carries the hash of the catalog it leaves), so the fixes
    /// stop where their number times the catalog's size reaches `maxDocumentFixWork`. The records past that are left as
    /// found and go on the card.
    static func documentFixes(_ catalog: JSONObject, actor: JSONObject, work: Int = maxDocumentFixWork) -> [TekaStore.OpBody] {
        let documents = catalog["documents"]?.arrayValue ?? []
        let holders = TransactionGuard.idCounts(documents)
        let most = work / max(JSONWriter.compact(.object(catalog)).utf8.count, 1)
        var fixes: [TekaStore.OpBody] = []
        for document in documents where fixes.count < most {
            guard case .object(let o) = document, let id = o["id"], holders[id] == 1, let fix = documentFix(o, actor: actor) else { continue }
            fixes.append(fix)
        }
        return fixes
    }

    /// The day a date in another form names: every form `CalendarDate.lenient` reads, and a date followed by a time
    /// (`2026-05-01T09:30:00Z`, `2026-05-01 09:30`). The time starts with an hour and a minute and holds nothing but
    /// what a time and its zone are written with, so a span (`2026-05-01 to 2026-05-09`) is never read as its first
    /// day. nil for a span, a month, a year or words, which name no one day.
    static func oneDay(_ text: String) -> CalendarDate? {
        if let date = CalendarDate.lenient(text) { return date }
        let bytes = Array(text.utf8)
        guard bytes.count >= 16, bytes.count <= 40, bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " ") else { return nil }
        let time = bytes[11...]
        func digit(_ b: UInt8) -> Bool { b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9") }
        guard digit(bytes[11]), digit(bytes[12]), bytes[13] == UInt8(ascii: ":"), digit(bytes[14]), digit(bytes[15]),
              time.allSatisfy({ digit($0) || ":.+-Z".utf8.contains($0) }) else { return nil }
        return CalendarDate.strict(String(decoding: bytes[..<10], as: UTF8.self))
    }

    /// Text as one line: each run of line breaks becomes one space, and the ends are trimmed.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// A title from a record's path: the file's name without its extension, on one line.
    static func fileTitle(_ path: String) -> String {
        let name = oneLine((path as NSString).lastPathComponent)
        let stem = (name as NSString).deletingPathExtension
        return stem.isEmpty ? name : stem
    }

    /// One card for the document records that still break a v0 rule after the fixes: a record with no id or with an id
    /// another record holds (no op can name either), one with no path, one that is not a record at all. The card names
    /// each by its place in the list, counted from 1, with the fields to fix; it has no op, since the person makes
    /// these changes by hand. Past `listed` places it gives the count of the rest, so the card stays readable.
    static func documentCard(_ documents: [JSONValue], actor: JSONObject, now: Date, listed: Int = 20) -> Proposal? {
        var fields: [Int: [String]] = [:]
        for finding in ItemRules.check(documents: documents) {
            guard let index = documentIndex(finding.location) else { continue }
            let field = finding.field ?? "the whole record"
            if fields[index]?.contains(field) != true { fields[index, default: []].append(field) }
        }
        let holders = TransactionGuard.idCounts(documents)
        for (index, document) in documents.enumerated() {
            if let id = document["id"], (holders[id] ?? 0) > 1, fields[index]?.contains("id") != true { fields[index, default: []].append("id") }
        }
        guard !fields.isEmpty else { return nil }
        let places = fields.keys.sorted()
        let shown = places.prefix(listed).map { "\($0 + 1) (\(fields[$0]!.joined(separator: ", ")))" }.joined(separator: ", ")
        let rest = places.count > listed ? " and \(places.count - listed) more" : ""
        return Proposal.make(title: "Fix the document records at these places in the list, by hand, then reject this card: " + shown + rest,
                             actor: actor, ops: [],
                             provenance: JSONObject([(key: "adoption", value: .str("documents")), (key: "manual_repair", value: .bool(true)),
                                                     (key: "positions", value: .array(places.prefix(listed).map { .int($0) })),
                                                     (key: "count", value: .int(places.count))]), now: now)
    }

    /// The index in `documents` a finding's location names, written `documents[<digits>]`.
    static func documentIndex(_ location: String) -> Int? {
        guard location.hasPrefix("documents["), location.hasSuffix("]") else { return nil }
        return Int(location.dropFirst("documents[".count).dropLast())
    }
}

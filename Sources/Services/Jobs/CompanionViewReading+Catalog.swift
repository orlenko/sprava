import BinderFormat
import Companion
import Foundation
import SpravaKit

extension CompanionViewReading {
    /// companion-v0 §8.5 from a settled catalog read under the binder's write lock: open items whole, today's buckets
    /// (binder-v0 §5.2), the Recently closed window and the documents. Projection to the wire is Companion's.
    static func of(catalog: JSONObject, folder: URL, today: CalendarDate, generatedAt: String,
                   timeZone: TimeZone = .current) -> CompanionViewReading {
        let open = catalog["open_items"]?.arrayValue ?? []
        let log = catalog["processing_log"]?.arrayValue ?? []
        let page = NowPage(items: open.enumerated().map { Item(raw: $1, index: $0) }, log: [], today: today, timeZone: timeZone)
        let pairs: [(Bucket, CompanionViewBucket)] = [(.overdue, .overdue), (.today, .today), (.next7, .next7Days),
            (.later, .later), (.noDeadline, .noDeadline), (.nudge, .nudge), (.waiting, .waiting)]
        var buckets: [CompanionViewBucket: [JSONValue]] = [:]
        for (bucket, wire) in pairs { buckets[wire] = (page.items[bucket] ?? []).compactMap { $0.raw["id"] } }
        var name = folder.lastPathComponent
        if case .string(let n)? = catalog["meta"]?["name"], !n.isEmpty { name = n }
        return CompanionViewReading(name: name, description: catalog["meta"]?["description"], today: today.description,
            generatedAt: generatedAt, openItems: open, recentlyClosed: recentlyClosed(log, today: today, timeZone: timeZone),
            documents: catalog["documents"]?.arrayValue ?? [], buckets: buckets)
    }

    /// binder-v0 §5.2: closure entries of the last 7 days, newest first, then by id text.
    static func recentlyClosed(_ log: [JSONValue], today: CalendarDate, timeZone: TimeZone) -> [JSONValue] {
        let window = today.adding(days: -6)
        let dated: [(JSONValue, CalendarDate, [UInt32])] = log.compactMap { entry in
            guard let id = entry["id"], let day = closingDate(entry, today: today, timeZone: timeZone), day >= window else { return nil }
            let text = id.stringValue ?? ((try? Canonical.serialize(id)) ?? "")
            return (entry, day, text.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value))
        }
        return dated.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2.lexicographicallyPrecedes($1.2) }.map(\.0)
    }

    private static func closingDate(_ entry: JSONValue, today: CalendarDate, timeZone: TimeZone) -> CalendarDate? {
        var date: CalendarDate?
        if let text = entry["closed_at"]?.stringValue {
            if let instant = Timestamp.parse(text) { date = CalendarDate(instant, in: timeZone) } else { date = CalendarDate.strict(text) }
        }
        if date == nil, let text = entry["at"]?.stringValue, let instant = Timestamp.parse(text) { date = CalendarDate(instant, in: timeZone) }
        return date.map { min($0, today) }
    }
}

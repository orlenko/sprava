import Foundation
import SpravaKit

/// companion-v0 §§8.5, 9.7: pure projection and whole-record fingerprints; no binder access or persistence.
public enum CompanionViewProjection {
    public static func project(binderID: String, version: Int64, reading: CompanionViewReading,
                               previous: CompanionViewHistory? = nil) throws -> CompanionProjectedView {
        guard CompanionWire.isID(binderID), version >= 1, version <= JSONNumber.maxSafeInteger,
              !reading.name.isEmpty, CalendarDate.strict(reading.today) != nil, CompanionOwnerRelay.time(reading.generatedAt),
              previous == nil || (previous!.binderID == binderID && previous!.version >= 1 && previous!.version < version) else {
            throw CompanionViewProjectionError.invalid
        }
        // Bound work before recursive canonicalization; large notes still get the protocol's omission fallback.
        let groups = [reading.openItems, reading.recentlyClosed, reading.documents] + Array(reading.buckets.values)
        guard groups.reduce(0, { $0 + $1.count }) <= 200000 else { throw CompanionViewProjectionError.tooLarge }
        try budget(groups.flatMap { $0 } + [reading.description ?? .null])
        var prior: [ProjectionID: CompanionItemSnapshot] = [:]
        for item in previous?.items ?? [] {
            guard let id = ProjectionID.parse(item.id), item.changedIn >= 1, item.changedIn <= previous!.version,
                  prior.updateValue(item, forKey: id) == nil else { throw CompanionViewProjectionError.invalid }
        }
        let closures = reading.recentlyClosed.filter { ["done", "dropped"].contains($0["action"]?.stringValue ?? "") }
        var counts: [ProjectionID: Int] = [:]
        for row in reading.openItems + closures {
            if let id = ProjectionID.parse(row["id"]) { counts[id, default: 0] += 1 }
        }
        var issues: [CompanionProjectionIssue] = [], duplicates = Set<ProjectionID>()
        func admitted(_ row: JSONValue) -> ProjectionID? {
            guard let id = ProjectionID.parse(row["id"]) else {
                issues.append(CompanionProjectionIssue(reason: .invalidID, id: nil)); return nil
            }
            if counts[id, default: 0] > 1 {
                if duplicates.insert(id).inserted { issues.append(CompanionProjectionIssue(reason: .duplicateID, id: row["id"])) }
                return nil
            }
            guard safeRecord(row) else {
                issues.append(CompanionProjectionIssue(reason: .invalidRecord, id: row["id"])); return nil
            }
            return id
        }
        var items: [JSONValue] = [], closed: [JSONValue] = [], undatedDone: [JSONValue] = []
        var fingerprints: [CompanionItemSnapshot] = [], openIDs = Set<ProjectionID>()
        for row in reading.openItems {
            guard let id = admitted(row), let rawID = row["id"] else { continue }
            let hash: String
            do { hash = try Canonical.hash(row) } catch {
                issues.append(CompanionProjectionIssue(reason: .invalidRecord, id: rawID)); continue
            }
            let changed = prior[id].flatMap { $0.hash == hash ? $0.changedIn : nil } ?? version
            fingerprints.append(CompanionItemSnapshot(id: rawID, hash: hash, changedIn: changed))
            if row["dismissed"] == .bool(true) { continue }
            guard let title = row["title"]?.stringValue else {
                issues.append(CompanionProjectionIssue(reason: .invalidRecord, id: rawID)); continue
            }
            let status = row["status"]?.stringValue ?? "open"
            if status == "done" {
                undatedDone.append(object([("id", rawID), ("title", .string(title)), ("closed_at", .null), ("how", .string("done"))])); continue
            }
            openIDs.insert(id)
            items.append(object([("id", rawID), ("changed_in", number(changed)), ("title", .string(title)),
                ("status", .string(["open", "waiting", "blocked"].contains(status) ? status : "open")),
                ("priority", optionalString(row["priority"])), ("due", date(row["due"])),
                ("waiting_on", optionalString(row["waiting_on"])), ("follow_up_at", date(row["follow_up_at"])),
                ("notes", optionalString(row["notes"])), ("tags", strings(row["tags"])), ("contexts", strings(row["contexts"]))]))
        }
        for row in closures {
            guard admitted(row) != nil, let id = row["id"] else { continue }
            closed.append(object([("id", id), ("title", .string(row["title"]?.stringValue ?? "")),
                ("closed_at", closedDate(row)), ("how", .string(row["action"]!.stringValue!))]))
        }
        closed += undatedDone
        let buckets = object(CompanionViewBucket.allCases.map { bucket in
            (bucket.rawValue, .array((reading.buckets[bucket] ?? []).filter { value in
                ProjectionID.parse(value).map { openIDs.contains($0) } ?? false
            }))
        })
        let documents = reading.documents.compactMap { row -> JSONValue? in
            guard let title = row["title"]?.stringValue, safeRecord(row) else {
                issues.append(CompanionProjectionIssue(reason: .invalidDocument, id: nil)); return nil
            }
            return object([("title", .string(title)), ("date", date(row["date"]))])
        }
        func payload(_ open: [JSONValue], omitted: Bool) -> Data {
            Data(JSONWriter.compact(object([("version", number(version)), ("generated_at", .string(reading.generatedAt)),
                ("today", .string(reading.today)), ("binder", object([("name", .string(CompanionProfile.phoneName(reading.name))),
                    ("description", optionalString(reading.description))])), ("notes_omitted", .bool(omitted)),
                ("buckets", buckets), ("items", .array(open)), ("closed", .array(closed)), ("documents", .array(documents))])).utf8)
        }
        var bytes = payload(items, omitted: false), omitted = false
        if bytes.count > 778240 {
            omitted = true
            items = items.map { value in
                var o = value.objectValue!
                o.entries = o.entries.map { ($0.key, $0.key == "notes" ? .null : $0.value) }
                return .object(o)
            }
            bytes = payload(items, omitted: true)
        }
        guard bytes.count <= 778240 else { throw CompanionViewProjectionError.tooLarge }
        return CompanionProjectedView(plaintext: bytes, history: CompanionViewHistory(binderID: binderID, version: version,
            items: fingerprints), notesOmitted: omitted, issues: issues)
    }
    private static func object(_ fields: [(key: String, value: JSONValue)]) -> JSONValue { .object(JSONObject(fields)) }
    private static func number(_ value: Int64) -> JSONValue { .number(JSONNumber(text: String(value))) }
    private static func optionalString(_ value: JSONValue?) -> JSONValue { value?.stringValue.map(JSONValue.string) ?? .null }
    private static func strings(_ value: JSONValue?) -> JSONValue { .array(value?.arrayValue?.compactMap { $0.stringValue.map(JSONValue.string) } ?? []) }
    private static func date(_ value: JSONValue?) -> JSONValue {
        guard let text = value?.stringValue, text.utf8.count <= 32, let day = CalendarDate.lenient(text) else { return .null }
        return .string(day.description)
    }
    private static func closedDate(_ row: JSONValue) -> JSONValue {
        if let text = row["closed_at"]?.stringValue, text.utf8.count <= 64 {
            if let date = Timestamp.parse(text) { return .string(date.ISO8601Format()) }
            if CalendarDate.strict(text) != nil { return .string(text) }
        }
        if let text = row["at"]?.stringValue, text.utf8.count <= 64, let date = Timestamp.parse(text) { return .string(date.ISO8601Format()) }
        return .null
    }
    private static func safeRecord(_ root: JSONValue) -> Bool {
        var pending = [root]
        while let value = pending.popLast() {
            switch value {
            case .object(let o):
                var keys = Set<[UInt16]>()
                for field in o.entries {
                    if !keys.insert(Array(field.key.utf16)).inserted { return false }
                    pending.append(field.value)
                }
            case .array(let values): pending += values
            case .number(let n): if n.doubleValue?.isFinite != true { return false }
            default: break
            }
        }
        return true
    }
    private static func budget(_ roots: [JSONValue]) throws {
        var pending = roots.map { ($0, 0) }, nodes = 0, textBytes = 0
        while let (value, depth) = pending.popLast() {
            nodes += 1
            guard nodes <= 200000, depth <= 64 else { throw CompanionViewProjectionError.tooLarge }
            switch value {
            case .object(let o):
                guard nodes + pending.count + o.entries.count <= 200000 else { throw CompanionViewProjectionError.tooLarge }
                for field in o.entries { textBytes += field.key.utf8.count; pending.append((field.value, depth + 1)) }
            case .array(let values):
                guard nodes + pending.count + values.count <= 200000 else { throw CompanionViewProjectionError.tooLarge }
                pending += values.map { ($0, depth + 1) }
            case .string(let text): textBytes += text.utf8.count
            case .number(let n): textBytes += n.text.utf8.count
            default: break
            }
            guard textBytes <= 33554432 else { throw CompanionViewProjectionError.tooLarge }
        }
    }
}

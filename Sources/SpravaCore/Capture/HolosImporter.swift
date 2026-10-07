import CryptoKit
import Foundation

/// The developer-only holos importer (capture-event-v0 §7.8; decisions.md P7): turns the output of
/// `voiceislocal history list --json` into dictation capture events (§7.1) in the importer's own device folder.
/// It has no cursor: it reads everything each run and skips what it already wrote, by ref plus revision.
/// Nothing it produces has been checked against real holos output.
public struct HolosImporter: Sendable {
    public let root: URL
    public let support: URL

    public init(root: URL, support: URL) {
        self.root = root
        self.support = support
    }

    var stateURL: URL { support.appendingPathComponent("capture/holos-importer.json") }

    struct State: Codable {
        var deviceID: String
        var written: [String: String] = [:]   // ref|revision -> event id
    }

    func loadState() -> State {
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(State.self, from: data) { return s }
        return State(deviceID: UUID().uuidString.lowercased())
    }

    public struct Result: Equatable, Sendable {
        public var written = 0
        public var skipped = 0
        public var unreadable = 0
        public var stoppedForGood = false
    }

    /// §7.1: the revision is the SHA-256 of the record's canonical form without `audio`, written as lowercase hex.
    public static func revision(_ record: JSONObject) throws -> String {
        var r = record
        r.remove("audio")
        let digest = SHA256.hash(data: Data(try Canonical.serialize(.object(r)).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// §7.1: holos's locale normalized to the schema's pattern (`fr_CA` → `fr-CA`, keywords and extensions cut).
    public static func locale(_ raw: String?) -> String {
        guard var s = raw, !s.isEmpty else { return "und" }
        if let at = s.firstIndex(of: "@") { s = String(s[..<at]) }
        s = s.replacingOccurrences(of: "_", with: "-")
        var kept: [Substring] = []
        for part in s.split(separator: "-", omittingEmptySubsequences: false) {
            if part.count == 1 { break }
            kept.append(part)
        }
        let text = kept.joined(separator: "-")
        return text.wholeMatch(of: /[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*/) != nil ? text : "und"
    }

    static func looksLikeBundleID(_ s: String) -> Bool { s.wholeMatch(of: /[A-Za-z0-9-]+(\.[A-Za-z0-9-]+){2,}/) != nil }

    /// Imports a `history list --json` array. Stops for good once a holos device folder other than the
    /// importer's own is registered in the capture root (§7.8).
    public func importHistory(_ data: Data, inbox: CaptureInbox, timeZone: TimeZone = .current, now: Date = Date()) throws -> Result {
        var result = Result()
        var state = loadState()
        if inbox.producers().contains(where: { $0.value == "holos" && $0.key != state.deviceID }) {
            result.stoppedForGood = true
            return result
        }
        guard case .array(let records) = try JSONParser.parse(data).value else { throw Commands.Failure(message: "expected a JSON array") }
        try inbox.registerProducer(folder: state.deviceID, app: "holos")
        let folder = root.appendingPathComponent(state.deviceID, isDirectory: true)
        try AtomicFile.makePrivateFolder(folder)
        var hlc: HLC?
        for value in records.reversed() {   // oldest first, so the clock and the ids follow the dictations
            guard case .object(let record) = value, let ref = record["id"]?.stringValue,
                  let dateText = record["date"]?.stringValue, let date = Timestamp.parse(dateText),
                  let text = record["text"]?.stringValue else {
                result.unreadable += 1
                continue
            }
            let revision = try Self.revision(record)
            let key = ref + "|" + revision
            if state.written[key] != nil { result.skipped += 1; continue }

            let next = HLC.next(after: hlc, node: state.deviceID.replacingOccurrences(of: "-", with: ""), now: now)
            hlc = next
            let id = UUIDv7.make(now: now)
            var event = JSONObject()
            event.set("format", .str("sprava-capture-event"))
            event.set("format_version", .str("0"))
            event.set("id", .string(id))
            event.set("hlc", .obj([("wall_ms", .number(JSONNumber(text: String(next.wall_ms)))), ("counter", .int(next.counter)),
                                   ("node", .string(next.node))]))
            event.set("device", .obj([("id", .string(state.deviceID))]))
            event.set("source", .obj([("app", .str("holos")), ("kind", .str("dictation")), ("ref", .string(ref)),
                                      ("revision", .string(revision)), ("processing", .str("on-device"))]))
            let second = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
            event.set("captured_at", .string(Self.secondTime(second, timeZone)))
            if let seconds = record["seconds"]?.numberValue?.doubleValue, seconds >= 0 {
                event.set("ended_at", .string(Self.secondTime(second.addingTimeInterval(seconds.rounded(.down)), timeZone)))
            }
            let language = record["language"]?.stringValue
            let locale = Self.locale(language)
            event.set("locale", .string(locale))
            event.set("text", .string(text))
            if let heard = record["heard"]?.stringValue, heard != text { event.set("alt_text", .string(heard)) }
            var context = JSONObject()
            if let app = record["app"]?.stringValue, !app.isEmpty, !Self.looksLikeBundleID(app) { context.set("app", .string(app)) }
            if record["terminal"] == .bool(true) { context.set("terminal", .bool(true)) }
            if !context.entries.isEmpty { event.set("app_context", .object(context)) }
            event.set("sensitivity", .str("unmarked"))
            var holos = JSONObject()
            if let v = record["schemaVersion"] { holos.set("schemaVersion", v) }
            holos.set("date", .string(dateText))
            if let language, language != locale { holos.set("language", .string(language)) }
            if let v = record["unwritten"], v.stringValue != nil { holos.set("unwritten", v) }
            if let v = record["fixes"] { holos.set("fixes", v) }
            if let outcome = record["outcome"]?.objectValue {
                var o = JSONObject()
                if let k = outcome["kind"] { o.set("kind", k) }
                if let p = outcome["partial"] { o.set("partial", p) }
                holos.set("outcome", .object(o))
            }
            for k in ["seconds", "words"] { if let v = record[k] { holos.set(k, v) } }
            event.set("extensions", .obj([("holos", .object(holos))]))
            try CaptureProducer.publish(Data(JSONWriter.pretty(.object(event)).utf8), as: folder.appendingPathComponent("\(id).json"))
            state.written[key] = id
            result.written += 1
        }
        try AtomicFile.makePrivateFolder(stateURL.deletingLastPathComponent())
        try AtomicFile.write(try JSONEncoder().encode(state), to: stateURL)
        return result
    }

    /// Second precision with the offset in force at that instant, `+00:00` never `Z`.
    static func secondTime(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        var s = f.string(from: date)
        if s.hasSuffix("Z") { s = String(s.dropLast()) + "+00:00" }
        return s
    }
}

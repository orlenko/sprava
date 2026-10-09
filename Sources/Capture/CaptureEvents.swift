import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// A hybrid logical clock (capture-event-v0 §4.2): logical time `l` follows the wall clock in milliseconds, a
/// counter breaks ties, `node` is the device id without hyphens. State is persisted before a stamp is used.
public struct HLC: Codable, Sendable, Equatable {
    public var wall_ms: Int64
    public var counter: Int
    public var node: String

    public static func next(after previous: HLC?, node: String, now: Date) -> HLC {
        let pt = Int64(now.timeIntervalSince1970 * 1000)
        guard let p = previous, p.node == node else { return HLC(wall_ms: pt, counter: 0, node: node) }
        if pt > p.wall_ms { return HLC(wall_ms: pt, counter: 0, node: node) }
        // A counter that would pass 65535 moves the clock on by a millisecond instead; it never waits (§4.2).
        if p.counter >= 65_535 { return HLC(wall_ms: p.wall_ms + 1, counter: 0, node: node) }
        return HLC(wall_ms: p.wall_ms, counter: p.counter + 1, node: node)
    }

    /// Orders stamps of one node: wall time, then the counter.
    func precedes(_ other: HLC) -> Bool { (wall_ms, counter) < (other.wall_ms, other.counter) }
}

/// Flushes an open file to stable storage by SpravaKit's rule (`AtomicFile`): `F_FULLFSYNC`, or `fsync` only on a
/// volume without it (ENOTSUP, EINVAL, ENOTTY); any other failure is reported, and an interrupted call is retried.
struct DiskFlush: Sendable {
    var fullSync: @Sendable (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) }
    var sync: @Sendable (Int32) -> Int32 = { fsync($0) }

    func callAsFunction(_ fd: Int32, step: String) throws {
        while fullSync(fd) < 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == ENOTSUP || code == EINVAL || code == ENOTTY else { throw AtomicFile.Failure(step: step, code: code) }
            while sync(fd) < 0 {
                let code = errno
                if code != EINTR { throw AtomicFile.Failure(step: step, code: code) }
            }
            return
        }
    }
}

/// Sprava as a producer of capture events: notes typed in the app (capture-event-v0 §8.1), written into
/// Sprava's own device folder under the capture root, by the writing order of §5.2.
public struct CaptureProducer: Sendable {
    public let root: URL
    public let deviceID: String
    let stateURL: URL

    public init(root: URL, deviceID: String, support: URL) {
        self.root = root
        self.deviceID = deviceID
        stateURL = support.appendingPathComponent("capture/producer-hlc.json")
    }

    public var folder: URL { root.appendingPathComponent(deviceID, isDirectory: true) }

    /// A note ready to publish: its event, bytes and digest, so the app can send its notice first.
    public struct PreparedNote: Sendable {
        public let event: JSONObject
        public let bytes: Data
        public let digest: String
        public var id: String { event["id"]?.stringValue ?? "" }
    }

    /// Builds one typed note (capture-event-v0 §8.1). `binderHint` is the binder the person typed in, if any.
    public func prepareNote(_ text: String, binderHint: String? = nil, startedAt: Date, savedAt: Date = Date(),
                            locale: String = Locale.current.identifier(.bcp47)) throws -> PreparedNote {
        try AtomicFile.makePrivateFolder(folder)
        // A clock state that exists but cannot be read is never written over (capture-event-v0 §5.3); a missing or
        // rolled-back one is raised to the highest stamp already published from this folder (§4.2).
        let node = deviceID.replacingOccurrences(of: "-", with: "")
        let stored = try StateFile.read(HLC.self, from: stateURL)
        guard stored.map({ (0...65_535).contains($0.counter) }) ?? true else { throw StateFile.Unreadable(path: stateURL.path) }
        let previous = [stored, publishedStamp(node: node)].compactMap { $0 }.filter { $0.node == node }
            .max { $0.precedes($1) }
        let hlc = HLC.next(after: previous, node: node, now: savedAt)
        try AtomicFile.makePrivateFolder(stateURL.deletingLastPathComponent())
        try AtomicFile.write(try JSONEncoder().encode(hlc), to: stateURL)

        let id = UUIDv7.make(now: savedAt)
        var event = JSONObject()
        event.set("format", .str("sprava-capture-event"))
        event.set("format_version", .str("0"))
        event.set("id", .string(id))
        event.set("hlc", .obj([("wall_ms", .number(JSONNumber(text: String(hlc.wall_ms)))), ("counter", .int(hlc.counter)),
                               ("node", .string(hlc.node))]))
        event.set("device", .obj([("id", .string(deviceID))]))
        let digest = SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        event.set("source", .obj([("app", .str("sprava")), ("kind", .str("text")), ("ref", .string(UUIDv7.make(now: startedAt))),
                                  ("revision", .string("sha256:" + digest)), ("processing", .str("on-device"))]))
        event.set("captured_at", .string(Self.offsetTime(startedAt)))
        event.set("ended_at", .string(Self.offsetTime(savedAt)))
        event.set("locale", .string(locale.isEmpty ? "und" : locale))
        event.set("text", .string(text))
        event.set("sensitivity", .str("unmarked"))
        if let binderHint { event.set("binder_hint", .string(binderHint)) }
        let bytes = Data(JSONWriter.pretty(.object(event)).utf8)
        return PreparedNote(event: event, bytes: bytes, digest: "sha256:" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
    }

    /// The highest stamp among the events already in this device's folder, or nil when there is none.
    func publishedStamp(node: String) -> HLC? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return nil }
        var best: HLC?
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            guard case .ok(let data) = SafeFile.read(folder.appendingPathComponent(name)),
                  let stamp = (try? JSONParser.parse(data).value)?["hlc"], stamp["node"]?.stringValue == node,
                  let wall = stamp["wall_ms"]?.numberValue?.safeInteger, let counter = stamp["counter"]?.numberValue?.safeInteger,
                  (0...65_535).contains(counter) else { continue }
            let found = HLC(wall_ms: wall, counter: Int(counter), node: node)
            if best.map({ $0.precedes(found) }) ?? true { best = found }
        }
        return best
    }

    /// Publishes a prepared note into Sprava's own device folder.
    public func publish(_ note: PreparedNote) throws {
        try Self.publish(note.bytes, as: folder.appendingPathComponent("\(note.id).json"))
    }

    /// Writes one typed note at once (the CLI and tests). Returns the event and the SHA-256 of its bytes.
    @discardableResult
    public func writeNote(_ text: String, binderHint: String? = nil, startedAt: Date, savedAt: Date = Date(),
                          locale: String = Locale.current.identifier(.bcp47)) throws -> (event: JSONObject, digest: String) {
        let note = try prepareNote(text, binderHint: binderHint, startedAt: startedAt, savedAt: savedAt, locale: locale)
        try publish(note)
        return (note.event, note.digest)
    }

    /// ISO 8601 with the numeric offset in force at that instant; `+00:00`, never `Z` (capture-event-v0 §4.3).
    public static func offsetTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var s = f.string(from: date)
        if s.hasSuffix("Z") { s = String(s.dropLast()) + "+00:00" }
        return s
    }

    /// Writes to `.<name>.tmp`, flushes, then publishes with an exclusive rename that fails if the name exists.
    package static func publish(_ data: Data, as url: URL) throws {
        try publish(data, as: url, flush: DiskFlush())
    }

    static func publish(_ data: Data, as url: URL, flush: DiskFlush) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent("." + url.lastPathComponent + ".tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "create event", code: errno) }
        var ok = false
        defer { if !ok { unlink(temp.path) } }
        try data.withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let n = write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; close(fd); throw AtomicFile.Failure(step: "write event", code: errno) }
                off += n
            }
        }
        do { try flush(fd, step: "flush event") } catch { close(fd); throw error }
        close(fd)
        guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
            throw AtomicFile.Failure(step: "publish event", code: errno)
        }
        ok = true
        let dir = open(url.deletingLastPathComponent().path, O_RDONLY | O_CLOEXEC)
        if dir >= 0 { fsync(dir); close(dir) }
    }
}

/// One capture event, read and checked (capture-event-v0 §5.3).
public struct CaptureEvent: Sendable {
    public let raw: JSONObject
    public let url: URL
    /// `sha256:<hex>` of the file's bytes, matched against the app's notices.
    public let digest: String

    /// An event held in memory, for the clerk's developer runs and tests; files are read with `check`.
    public init(raw: JSONObject, url: URL, digest: String) {
        self.raw = raw
        self.url = url
        self.digest = digest
    }

    public var id: String { raw["id"]?.stringValue ?? "" }
    public var text: String { raw["text"]?.stringValue ?? "" }
    public var binderHint: String? { raw["binder_hint"]?.stringValue }
    public var isPrivate: Bool { raw["sensitivity"]?.stringValue != "unmarked" }   // unknown values read as private
    public var retracted: Bool { raw["retracted"] == .bool(true) }
    public var supersedes: String? { raw["supersedes"]?.stringValue }
    public var app: String { raw["source"]?["app"]?.stringValue ?? "" }
    public var capturedAt: Date? { Timestamp.parse(raw["captured_at"]?.stringValue ?? "") }
    /// When the capture ended: `ended_at`, else `captured_at` (capture-event-v0 §4.3).
    public var endedAt: Date? {
        if let e = Timestamp.parse(raw["ended_at"]?.stringValue ?? ""), let c = capturedAt, e >= c { return e }
        return capturedAt
    }
    /// The cross-device dedupe key (capture-event-v0 §5.4).
    public var dedupeKey: String {
        let s = raw["source"]
        return [s?["app"]?.stringValue, s?["ref"]?.stringValue, s?["revision"]?.stringValue].map { $0 ?? "" }.joined(separator: "|")
    }

    public enum Check: Equatable {
        case complete(CaptureEvent.Kind)
        case pending
        case deferred
        case quarantined(String)
    }

    public enum Kind: Equatable { case capture, derived }

    /// Lowercase hyphenated UUID text, the only event file stem the reader accepts.
    static func isUUIDText(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        guard bytes.count == 36 else { return false }
        for (i, b) in bytes.enumerated() {
            if [8, 13, 18, 23].contains(i) { if b != UInt8(ascii: "-") { return false }; continue }
            guard (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x66) else { return false }
        }
        return true
    }

    /// Checks 1 to 4 of capture-event-v0 §5.3 for a file named `<uuid>.json` in `deviceFolder`.
    public static func check(_ url: URL, deviceFolder: URL) -> (Check, CaptureEvent?) {
        let name = url.lastPathComponent
        let stem = String(name.dropLast(5))
        guard name.hasSuffix(".json"), !name.hasPrefix("."), isUUIDText(stem) else {
            return (.quarantined("not an event file name"), nil)
        }
        let data: Data
        switch SafeFile.read(url) {
        case .ok(let d): data = d
        case .refused(let why): return (.quarantined(why), nil)
        case .missing, .unreadable: return (.pending, nil)
        }
        guard let parsed = try? JSONParser.parse(data), case .object(let o) = parsed.value else {
            return (.pending, nil)   // may be partly written by a sync client
        }
        let format = o["format"]?.stringValue
        guard format == "sprava-capture-event" || format == "sprava-derived-event" else { return (.quarantined("unknown format"), nil) }
        guard o["format_version"]?.stringValue == "0" else { return (.deferred, nil) }
        guard parsed.safety.isSafe else { return (.quarantined("unsafe JSON"), nil) }
        guard o["id"]?.stringValue == stem else { return (.quarantined("id differs from the file name"), nil) }
        guard o["device"]?["id"]?.stringValue == deviceFolder.lastPathComponent else { return (.quarantined("device id differs from the folder"), nil) }
        guard o["hlc"]?["node"]?.stringValue == deviceFolder.lastPathComponent.replacingOccurrences(of: "-", with: "") else {
            return (.quarantined("hlc.node differs from the device id"), nil)
        }
        // The whole stamp, as the reader schema has it: a malformed one would sort as stale and be dropped unseen.
        guard let wall = o["hlc"]?["wall_ms"]?.numberValue?.safeInteger, (1_000_000_000_000...9_999_999_999_999).contains(wall),
              let counter = o["hlc"]?["counter"]?.numberValue?.safeInteger, (0...65_535).contains(counter) else {
            return (.quarantined("hlc is not a valid clock stamp"), nil)
        }
        if o["supersedes"]?.stringValue == stem { return (.quarantined("supersedes itself"), nil) }
        let kind: Kind = format == "sprava-derived-event" ? .derived : .capture
        if kind == .capture {
            for key in ["source", "captured_at", "locale", "text", "sensitivity"] where o[key] == nil {
                return (.quarantined("missing \(key)"), nil)
            }
            guard Timestamp.parse(o["captured_at"]?.stringValue ?? "") != nil else { return (.quarantined("captured_at is not a real instant"), nil) }
            guard o["source"]?["ref"]?.stringValue != nil, o["source"]?["revision"]?.stringValue != nil, o["source"]?["app"]?.stringValue != nil else {
                return (.quarantined("source needs app, ref and revision as text"), nil)
            }
            // Types, not only presence: a field of the wrong type is a malformed event, never an empty one.
            for key in ["captured_at", "locale", "text", "sensitivity"] where o[key]?.stringValue == nil {
                return (.quarantined("\(key) is not text"), nil)
            }
            for key in ["ended_at", "binder_hint", "supersedes", "title"] where o[key] != nil && o[key]?.stringValue == nil {
                return (.quarantined("\(key) is not text"), nil)
            }
            if let r = o["retracted"], r != .bool(true), r != .bool(false) { return (.quarantined("retracted is not true or false"), nil) }
        }
        for media in o["media"]?.arrayValue ?? [] {
            guard let path = media["path"]?.stringValue else { continue }
            guard path.hasPrefix("\(stem)."), !path.hasSuffix(".tmp"), !path.contains("/") else {
                return (.quarantined("media path does not belong to the event"), nil)
            }
            // A copied media entry names its size (the reader schema); until the file has it, it is still arriving.
            guard let expected = media["bytes"]?.numberValue?.safeInteger, expected >= 0 else {
                return (.quarantined("media bytes missing or not an integer"), nil)
            }
            var st = stat()
            guard lstat(deviceFolder.appendingPathComponent(path).path, &st) == 0 else { return (.pending, nil) }
            guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return (.quarantined("media is not a plain file of this user"), nil) }
            if Int(expected) != Int(st.st_size) { return (.pending, nil) }
        }
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (.complete(kind), CaptureEvent(raw: o, url: url, digest: digest))
    }
}

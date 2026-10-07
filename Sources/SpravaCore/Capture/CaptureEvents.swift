import CryptoKit
import Darwin
import Foundation

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
        return HLC(wall_ms: p.wall_ms, counter: p.counter + 1, node: node)
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
        let previous = (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(HLC.self, from: $0) }
        let hlc = HLC.next(after: previous, node: deviceID.replacingOccurrences(of: "-", with: ""), now: savedAt)
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
    static func publish(_ data: Data, as url: URL) throws {
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
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
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
        case .missing: return (.pending, nil)
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
        if o["supersedes"]?.stringValue == stem { return (.quarantined("supersedes itself"), nil) }
        let kind: Kind = format == "sprava-derived-event" ? .derived : .capture
        if kind == .capture {
            for key in ["source", "captured_at", "locale", "text", "sensitivity"] where o[key] == nil {
                return (.quarantined("missing \(key)"), nil)
            }
            guard Timestamp.parse(o["captured_at"]?.stringValue ?? "") != nil else { return (.quarantined("captured_at is not a real instant"), nil) }
            guard o["source"]?["ref"] != nil, o["source"]?["revision"] != nil, o["source"]?["app"] != nil else {
                return (.quarantined("source needs app, ref and revision"), nil)
            }
        }
        for media in o["media"]?.arrayValue ?? [] {
            guard let path = media["path"]?.stringValue else { continue }
            guard path.hasPrefix("\(stem)."), !path.hasSuffix(".tmp"), !path.contains("/") else {
                return (.quarantined("media path does not belong to the event"), nil)
            }
            var st = stat()
            guard lstat(deviceFolder.appendingPathComponent(path).path, &st) == 0 else { return (.pending, nil) }
            guard st.st_mode & S_IFMT == S_IFREG, st.st_uid == getuid() else { return (.quarantined("media is not a plain file of this user"), nil) }
            let size: Int? = Int(st.st_size)
            if size == nil || (media["bytes"]?.numberValue?.safeInteger.map { Int($0) != size } ?? false) { return (.pending, nil) }
        }
        let digest = "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return (.complete(kind), CaptureEvent(raw: o, url: url, digest: digest))
    }
}

/// Reads files in the capture folder without following symbolic links, accepting only regular files owned by
/// this user (architecture 8, step 1).
public enum SafeFile {
    public enum Outcome { case ok(Data), refused(String), missing }

    public static func read(_ url: URL, limit: Int = 16 * 1024 * 1024) -> Outcome {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return errno == ELOOP ? .refused("a symbolic link") : .missing }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .missing }
        guard st.st_mode & S_IFMT == S_IFREG else { return .refused("not a plain file") }
        guard st.st_uid == getuid() else { return .refused("owned by another user") }
        guard st.st_size <= limit else { return .refused("larger than \(limit) bytes") }
        var data = Data(count: Int(st.st_size))
        var off = 0
        let ok = data.withUnsafeMutableBytes { b -> Bool in
            while off < b.count {
                let n = Darwin.read(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { break }
                off += n
            }
            return true
        }
        guard ok else { return .missing }
        return .ok(data.prefix(off))
    }

    /// A folder the watcher may read: a real folder (not a link), owned by this user, not writable by others.
    public static func isTrustedFolder(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid() && st.st_mode & 0o022 == 0
    }
}

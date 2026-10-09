import BinderStore
import Foundation
import SpravaKit

/// The consumer side of the capture folder (capture-event-v0 §5.3; architecture 8): a durable journal of what was
/// seen, and a code-built Tier 0 card for every capture (architecture 5.2), filed into the binder the person named
/// or kept unfiled with the binder "not sure". No model is involved here; the clerk improves cards later.
/// The inbox never writes inside the capture folder.
public struct CaptureInbox: Sendable {
    public let root: URL
    public let support: URL

    public init(root: URL, support: URL) {
        self.root = root
        self.support = support
    }

    /// The capture root: `SPRAVA_CAPTURE_ROOT` for development, else `Captures` in Sprava's own folder, on the
    /// Mac's own disk (capture-event-v0 §5.1).
    public static func defaultRoot(support: URL) -> URL {
        if let env = ProcessInfo.processInfo.environment["SPRAVA_CAPTURE_ROOT"], env.hasPrefix("/") {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return support.appendingPathComponent("Captures", isDirectory: true)
    }

    package var dir: URL { support.appendingPathComponent("capture", isDirectory: true) }
    package var journalURL: URL { dir.appendingPathComponent("journal.ndjson") }
    package var stateURL: URL { dir.appendingPathComponent("state.json") }
    package var noticesURL: URL { dir.appendingPathComponent("app-notices.ndjson") }
    package var producersURL: URL { dir.appendingPathComponent("producers.json") }
    var quarantineDir: URL { dir.appendingPathComponent("quarantine", isDirectory: true) }
    package var unfiledDigestsURL: URL { dir.appendingPathComponent("unfiled-digests.json") }
    public var unfiledDir: URL { support.appendingPathComponent("unfiled", isDirectory: true) }

    /// The file of an unfiled card, or nil for an id Sprava never makes, so no id reaches outside the folder.
    func unfiledFile(_ id: String) -> URL? {
        ProposalStore.isValidID(id) ? unfiledDir.appendingPathComponent("\(id).json") : nil
    }

    // MARK: - Producers and notices (architecture 8)

    /// Device folder name -> the `source.app` expected there.
    public func producers() -> [String: String] { (try? readProducers()) ?? [:] }

    /// The registry, or a throw when `producers.json` exists but cannot be read; writers use this.
    func readProducers() throws -> [String: String] {
        try StateFile.read([String: String].self, from: producersURL) ?? [:]
    }

    public func registerProducer(folder: String, app: String) throws {
        var p = try readProducers()
        guard p[folder] != app else { return }
        p[folder] = app
        try AtomicFile.makePrivateFolder(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(p), to: producersURL)
    }

    /// Records that the app wrote this event, so its binder hint can be trusted. Throws when the line is not on
    /// disk, so the app knows the binder the person chose would be lost (architecture 8).
    public func recordNotice(event: String, digest: String, now: Date = Date()) throws {
        guard CaptureEvent.isUUIDText(event), digest.hasPrefix("sha256:") else { throw Commands.Failure(message: "bad notice") }
        try AtomicFile.makePrivateFolder(dir)
        try Self.appendDurably(JSONWriter.compact(.obj([("at", .string(ISOTime.string(now))), ("event", .string(event)),
                                                        ("sha256", .string(digest))])), to: noticesURL)
    }

    /// Appends one whole line and flushes it, or throws.
    static func appendDurably(_ line: String, to url: URL, flush: DiskFlush = DiskFlush()) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open \(url.lastPathComponent)", code: errno) }
        defer { close(fd) }
        try Data((line + "\n").utf8).withUnsafeBytes { b in
            var off = 0
            while off < b.count {
                let n = write(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; throw AtomicFile.Failure(step: "write \(url.lastPathComponent)", code: errno) }
                off += n
            }
        }
        try flush(fd, step: "fsync \(url.lastPathComponent)")
        // The folder too, so the journal's name survives a power loss the first time it is made.
        try flush.folder(url.deletingLastPathComponent(), step: "flush \(url.lastPathComponent)'s folder")
    }

    /// The app's notices by event id. A journal that is there but cannot be read throws: read as empty, every note of
    /// the app's would be taken in unverified and the binder the person chose lost for good.
    func notices() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: noticesURL.path) else { return [:] }
        guard let text = try? String(contentsOf: noticesURL, encoding: .utf8) else { throw StateFile.Unreadable(path: noticesURL.path) }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let v = try? JSONParser.parse(String(line)).value, let e = v["event"]?.stringValue, let d = v["sha256"]?.stringValue else { continue }
            out[e] = d
        }
        return out
    }

    // MARK: - Journal and quarantine

    /// One journal line: event ids, stages, counts and codes, never text or titles.
    func journal(_ fields: [(String, JSONValue)]) {
        try? AtomicFile.makePrivateFolder(dir)
        AtomicFile.appendLine(JSONWriter.compact(.obj([("at", .string(ISOTime.string(Date())))] + fields)), to: journalURL)
    }

    /// Keeps a copy of a malformed file with the reason, for the Health page. The original is never touched. False when
    /// the reason could not be kept (the copy is kept when the file can be read).
    @discardableResult
    func quarantine(_ file: URL, device: String, reason: String) -> Bool {
        let folder = quarantineDir.appendingPathComponent(device, isDirectory: true)
        guard (try? AtomicFile.makePrivateFolder(folder)) != nil else { return false }
        if case .ok(let data) = SafeFile.read(file), (try? AtomicFile.write(data, to: folder.appendingPathComponent(file.lastPathComponent))) == nil {
            return false
        }
        return (try? AtomicFile.write(Data((reason + "\n").utf8), to: folder.appendingPathComponent(file.lastPathComponent + ".why"))) != nil
    }

    public struct SweepResult: Equatable, Sendable {
        public var ingested = 0
        public var filed = 0
        public var unfiled = 0
        public var pending = 0
        public var quarantined = 0
        public var duplicates = 0
        public var refusedFolders = 0
        /// Seconds from each new capture's end to its card, for the one-minute measure (decisions.md M3).
        public var latencies: [Double] = []
        /// A state file that exists but cannot be read: nothing was swept, and nothing was written over it.
        public var unreadable: String?
        /// A state file that could not be written: the sweep stopped there, and made no card the cursor would not
        /// hold; what it had not recorded is done again by the next sweep.
        public var unsaved: String?
    }

    /// Counts for the Health page: unfiled cards, quarantined files, and the age of the oldest unfiled card.
    public func health(now: Date = Date()) -> (unfiled: Int, quarantined: Int, oldestUnfiledSeconds: Int?) {
        let cards = unfiled()
        let oldest = cards.compactMap { Timestamp.parse($0.raw["created_at"]?.stringValue ?? "") }.min()
        let quarantined = (FileManager.default.enumerator(atPath: quarantineDir.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".why") }.count
        return (cards.count, quarantined, oldest.map { Int(now.timeIntervalSince($0)) })
    }
}

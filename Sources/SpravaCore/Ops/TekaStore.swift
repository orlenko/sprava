import CryptoKit
import Darwin
import Foundation

/// UUID version 7: time-ordered, as the op log and capture events use (teka-v0 §6.2). Ids made by one process
/// are strictly increasing even within one millisecond: the 12 `rand_a` bits carry a counter (RFC 9562 §6.2,
/// method 1), so files named by these ids list in creation order.
public enum UUIDv7 {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastMS: UInt64 = 0
    nonisolated(unsafe) private static var counter: UInt64 = 0

    public static func make(now: Date = Date()) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &bytes)
        var ms = UInt64(max(0, now.timeIntervalSince1970) * 1000)
        lock.lock()
        if ms <= lastMS {
            ms = lastMS
            counter += 1
            if counter > 0xFFF { ms += 1; counter = 0 }
        } else {
            counter = 0
        }
        lastMS = ms
        let seq = counter
        lock.unlock()
        for i in 0..<6 { bytes[i] = UInt8((ms >> (8 * (5 - UInt64(i)))) & 0xFF) }
        bytes[6] = 0x70 | UInt8((seq >> 8) & 0x0F)
        bytes[7] = UInt8(seq & 0xFF)
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let parts = [hex.prefix(8), hex.dropFirst(8).prefix(4), hex.dropFirst(12).prefix(4),
                     hex.dropFirst(16).prefix(4), hex.dropFirst(20)]
        return parts.joined(separator: "-")
    }
}

/// The one writer of a teka (teka-v0 §4.9, §6.7, §6.9). Every change runs under the teka's `flock` lock:
/// absorb outside edits, guard the ops, write the catalog to a temporary file, append the op lines, rename the
/// catalog into place, update the snapshot. It never writes outside `catalog.json`, `.teka.lock` and `.sprava/`.
public final class TekaStore {
    public let folder: URL
    public let client: String

    public struct Busy: Error, CustomStringConvertible {
        public var description: String { "another program holds the binder lock" }
    }

    public struct Refused: Error, CustomStringConvertible {
        public let reason: String
        public var description: String { reason }
    }

    public init(folder: URL, client: String = "sprava/0.1") {
        self.folder = folder
        self.client = client
    }

    var catalogURL: URL { folder.appendingPathComponent("catalog.json") }
    var spravaDir: URL { folder.appendingPathComponent(".sprava", isDirectory: true) }
    var opLogURL: URL { spravaDir.appendingPathComponent("ops.ndjson") }
    var snapshotURL: URL { spravaDir.appendingPathComponent("snapshot.json") }

    // MARK: - The lock

    /// Takes the binder lock without waiting forever: retries for at most `timeout` seconds, then reports the
    /// binder busy (architecture 2.3).
    func withLock<T>(timeout: TimeInterval = 10, _ body: () throws -> T) throws -> T {
        let lockURL = folder.appendingPathComponent(".teka.lock")
        if let attrs = try? FileManager.default.attributesOfItem(atPath: lockURL.path),
           attrs[.type] as? FileAttributeType != .typeRegular {
            throw Refused(reason: ".teka.lock is not a regular file")
        }
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open .teka.lock", code: errno) }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(timeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK, Date() < deadline else { throw Busy() }
            usleep(100_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: - Reading

    public struct State {
        public var catalog: JSONObject
        public var hash: String
        public var opLog: [JSONObject]
    }

    func readCatalog() throws -> (JSONObject, String, Data) {
        let data = try Data(contentsOf: catalogURL)
        let (value, safety) = try JSONParser.parse(data)
        guard case .object(let catalog) = value else { throw Refused(reason: "catalog.json is not a JSON object") }
        guard safety.isSafe else { throw Refused(reason: "catalog.json holds unsafe JSON; a repair must be approved first") }
        return (catalog, try Canonical.hash(value), data)
    }

    /// The op log's complete lines. A torn last line, and a trailing batch shorter than its `batch_size`, never
    /// took effect and are left out (teka-v0 §6.9).
    public func readOpLog() throws -> (ops: [JSONObject], torn: Bool) {
        guard let data = try? Data(contentsOf: opLogURL) else { return ([], false) }
        var text = String(decoding: data, as: UTF8.self)
        var torn = false
        if !text.isEmpty, !text.hasSuffix("\n") {
            torn = true
            text = String(text[..<(text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex)])
        }
        var ops = try text.split(separator: "\n").map { line -> JSONObject in
            guard case .object(let o) = try JSONParser.parse(String(line)).value else { throw Refused(reason: "op log line is not an object") }
            return o
        }
        if let last = ops.last, case .string(let batch)? = last["batch"],
           let size = last["batch_size"]?.numberValue?.safeInteger {
            let count = ops.reversed().prefix { $0["batch"]?.stringValue == batch }.count
            if count < size {
                ops.removeLast(count)
                torn = true
            }
        }
        return (ops, torn)
    }

    func snapshotHash() -> String? {
        guard let data = try? Data(contentsOf: snapshotURL), let value = try? JSONParser.parse(data).value else { return nil }
        return try? Canonical.hash(value)
    }

    // MARK: - Applying

    /// One op body to apply: the op type and args, plus envelope fields such as `proposal`, `approved_by`,
    /// `compensates` and `note`.
    public struct OpBody {
        public var op: String
        public var args: JSONObject
        public var actor: JSONObject
        public var extra: [(String, JSONValue)]

        public init(op: String, args: JSONObject, actor: JSONObject, extra: [(String, JSONValue)] = []) {
            self.op = op
            self.args = args
            self.actor = actor
            self.extra = extra
        }
    }

    /// Applies a batch under the lock. Outside edits are absorbed first. Returns the applied op lines.
    @discardableResult
    public func apply(_ bodies: [OpBody], batch: String? = nil, now: Date = Date()) throws -> [JSONObject] {
        try withLock {
            var (catalog, hash, _) = try readCatalog()
            var log = try readOpLog().ops
            guard !log.isEmpty else { throw Refused(reason: "this binder has not been adopted") }
            if let absorbed = try absorbOutsideEdits(catalog: catalog, hash: hash, log: log, now: now) {
                log.append(contentsOf: absorbed)
            }
            (catalog, hash, _) = try readCatalog()

            let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
            var lines: [JSONObject] = []
            for (seq, body) in bodies.enumerated() {
                var line = JSONObject()
                line.set("id", .string(UUIDv7.make(now: now)))
                line.set("at", .string(at))
                var actor = body.actor
                if actor["client"] == nil { actor.set("client", .string(client)) }
                line.set("actor", .object(actor))
                for (k, v) in body.extra where k != "note" { line.set(k, v) }
                if let batch, bodies.count > 1 || body.extra.contains(where: { $0.0 == "proposal" }) {
                    line.set("batch", .string(batch))
                    line.set("seq", .int(seq))
                    line.set("batch_size", .int(bodies.count))
                }
                line.set("before_hash", .null)
                line.set("after_hash", .null)
                line.set("op", .string(body.op))
                line.set("args", .object(body.args))
                if let note = body.extra.first(where: { $0.0 == "note" })?.1 { line.set("note", note) }
                lines.append(line)
            }
            let knownIDs = Set(log.compactMap { $0["args"]?["item"]?["id"] })
            let (result, hashes) = try TransactionGuard.check(lines, on: catalog, knownIDs: knownIDs)
            var previous = hash
            for i in lines.indices {
                lines[i].set("before_hash", .string(previous))
                lines[i].set("after_hash", .string(hashes[i]))
                previous = hashes[i]
            }
            try write(catalog: result, appending: lines, expectedHash: hash)
            return lines
        }
    }

    /// Steps 4 to 7 of the write protocol and steps 3 to 6 of teka-v0 §6.9.
    func write(catalog: JSONObject, appending lines: [JSONObject], expectedHash: String) throws {
        let text = JSONWriter.pretty(.object(catalog))
        let temp = folder.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "create temp catalog", code: errno) }
        var renamed = false
        defer { if !renamed { unlink(temp.path) } }
        try writeAll(fd, Data(text.utf8))
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
        close(fd)

        // Step 5: someone changed the file without the lock; start over.
        let (_, nowHash, _) = try readCatalog()
        guard nowHash == expectedHash else { throw Refused(reason: "catalog.json changed while the change was being written; try again") }

        try appendLines(lines)
        guard rename(temp.path, catalogURL.path) == 0 else { throw AtomicFile.Failure(step: "rename catalog", code: errno) }
        renamed = true
        let dirfd = open(folder.path, O_RDONLY | O_CLOEXEC)
        if dirfd >= 0 { fsync(dirfd); close(dirfd) }
        try AtomicFile.write(Data(text.utf8), to: snapshotURL)
    }

    func appendLines(_ lines: [JSONObject]) throws {
        try AtomicFile.makePrivateFolder(spravaDir)
        // A torn tail is copied aside and cut before the next append (teka-v0 §6.9).
        if let data = try? Data(contentsOf: opLogURL), !data.isEmpty, data.last != 0x0A {
            let tornDir = spravaDir.appendingPathComponent("torn", isDirectory: true)
            try AtomicFile.makePrivateFolder(tornDir)
            let cut = data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            let stamp = ISOTime.string(Date(), timeZone: TimeZone(identifier: "UTC")!).replacingOccurrences(of: ":", with: "")
            try AtomicFile.write(data[cut...], to: tornDir.appendingPathComponent("\(stamp).ndjson"))
            let fd = open(opLogURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
            if fd >= 0 { ftruncate(fd, off_t(cut)); close(fd) }
        }
        let fd = open(opLogURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "open op log", code: errno) }
        defer { close(fd) }
        let text = lines.map { JSONWriter.compact(.object($0)) + "\n" }.joined()
        try writeAll(fd, Data(text.utf8))
        if fcntl(fd, F_FULLFSYNC) != 0 { fsync(fd) }
    }

    func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFile.Failure(step: "write", code: errno)
                }
                offset += n
            }
        }
    }

    // MARK: - Outside edits (teka-v0 §6.7)

    public enum Absorbed: Equatable {
        case none
        case snapshotRewritten
        case rolledForward(Int)
        case externalEdit(revertedLastBatch: Bool)
    }

    public private(set) var lastAbsorbed: Absorbed = .none

    /// Compares the catalog's hash `H` with the op log's head `a`, the trailing write's start `b` and the
    /// snapshot `S`, and records what happened outside. Returns the op lines it appended.
    func absorbOutsideEdits(catalog: JSONObject, hash H: String, log: [JSONObject], now: Date) throws -> [JSONObject]? {
        lastAbsorbed = .none
        guard let last = log.last, case .string(let a)? = last["after_hash"] else { return nil }
        let trailing = trailingWrite(log)
        let b = trailing.first?["before_hash"]?.stringValue
        let S = snapshotHash()

        if H == a {
            if S != a {
                try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: snapshotURL)
                lastAbsorbed = .snapshotRewritten
            }
            return nil
        }
        if H == b, S == b {
            // A write was logged but never renamed into place: roll it forward. Ops are pure, so the result
            // has the same hash. (A logged file move is the capture increment's concern; none exist yet.)
            var state = catalog
            for op in trailing { state = try OpApplier.apply(op, to: state) }
            guard try Canonical.hash(.object(state)) == a else { throw Refused(reason: "roll-forward did not reach the logged hash") }
            try write(catalog: state, appending: [], expectedHash: H)
            lastAbsorbed = .rolledForward(trailing.count)
            return nil
        }

        // Someone else edited the file (or reverted our last write). The expected state is the snapshot when it
        // matches the head; otherwise a replay of the log.
        var expected: JSONObject
        if S == a, let data = try? Data(contentsOf: snapshotURL), case .object(let snap) = try JSONParser.parse(data).value {
            expected = snap
        } else {
            expected = try Replay.run(log)
        }
        let expectedHash = try Canonical.hash(.object(expected))
        let patch = JSONPatch.diff(from: .object(expected), to: .object(catalog))
        let reverted = H == b && S == a
        var args = JSONObject()
        args.set("patch", .array(patch))
        args.set("detected_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        if reverted { args.set("hint", .string("the catalog was put back as it was before the last change")) }
        else if let hint = Self.hint(for: patch) { args.set("hint", .string(hint)) }
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
        line.set("actor", .obj([("kind", .str("external")), ("client", .string(client)), ("origin", .str("unknown"))]))
        line.set("before_hash", .string(expectedHash))
        line.set("after_hash", .string(H))
        line.set("op", .str("external_edit"))
        line.set("args", .object(args))
        try appendLines([line])
        try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: snapshotURL)
        let before = log.count > trailing.count ? try? Replay.run(Array(log.dropLast(trailing.count))) : nil
        lastAbsorbed = .externalEdit(revertedLastBatch: reverted
            || Self.undoes(found: catalog, expected: expected, beforeTrailing: before, trailing: trailing))
        return [line]
    }

    /// The last complete batch, or the last single op.
    func trailingWrite(_ log: [JSONObject]) -> [JSONObject] {
        guard let last = log.last else { return [] }
        guard case .string(let batch)? = last["batch"] else { return [last] }
        return Array(log.reversed().prefix { $0["batch"]?.stringValue == batch }.reversed())
    }

    /// A likely editor named from the patch, e.g. a closure entry lifeproj's drain wrote.
    static func hint(for patch: [JSONValue]) -> String? {
        for step in patch where step["value"]?["via"]?.stringValue == "lifeproj drain" {
            return "a processing_log entry written by lifeproj drain"
        }
        return nil
    }

    /// Whether the outside edit put back, on every path the last batch changed, the value from before it
    /// (teka-v0 §6.7 step 6): another program overwrote the person's change.
    static func undoes(found: JSONObject, expected: JSONObject, beforeTrailing: JSONObject?, trailing: [JSONObject]) -> Bool {
        guard let before = beforeTrailing, !trailing.isEmpty,
              trailing.allSatisfy({ ["user", "clerk", "brain"].contains($0["actor"]?["kind"]?.stringValue ?? "") }) else {
            return false
        }
        let changed = JSONPatch.diff(from: .object(before), to: .object(expected)).compactMap { $0["path"]?.stringValue }
        guard !changed.isEmpty else { return false }
        return changed.allSatisfy { path in
            JSONPatch.value(at: path, in: .object(found)) == JSONPatch.value(at: path, in: .object(before))
        }
    }

    // MARK: - Adoption (teka-v0 §9.4 step 1)

    /// Adopts the folder in place: saves byte copies of `catalog.json` and `DASHBOARD.md` under
    /// `.sprava/adopted/`, writes the owner record, and starts the op log with an `import_snapshot`. Nothing
    /// else in the folder changes.
    public func adopt(survey: JSONObject, owner: JSONObject, now: Date = Date()) throws {
        try withLock {
            guard (try readOpLog().ops).isEmpty else { throw Refused(reason: "already adopted") }
            let (catalog, hash, bytes) = try readCatalog()
            let adopted = spravaDir.appendingPathComponent("adopted", isDirectory: true)
            try AtomicFile.makePrivateFolder(adopted)
            try AtomicFile.write(bytes, to: adopted.appendingPathComponent("catalog.json"))
            let dashboard = folder.appendingPathComponent("DASHBOARD.md")
            if let attrs = try? FileManager.default.attributesOfItem(atPath: dashboard.path),
               attrs[.type] as? FileAttributeType == .typeRegular {
                try AtomicFile.write(try Data(contentsOf: dashboard), to: adopted.appendingPathComponent("DASHBOARD.md"))
            }
            try AtomicFile.write(Data(JSONWriter.pretty(.object(owner)).utf8), to: spravaDir.appendingPathComponent("owner.json"))
            var args = JSONObject()
            args.set("catalog", .object(catalog))
            args.set("survey", .object(survey))
            var line = JSONObject()
            line.set("id", .string(UUIDv7.make(now: now)))
            line.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
            line.set("actor", .obj([("kind", .str("import")), ("client", .string(client))]))
            line.set("before_hash", .string(hash))
            line.set("after_hash", .string(hash))
            line.set("op", .str("import_snapshot"))
            line.set("args", .object(args))
            try appendLines([line])
            try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: snapshotURL)
        }
    }
}

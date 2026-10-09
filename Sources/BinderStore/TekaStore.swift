import BinderFormat
import Darwin
import Foundation
import SpravaKit

/// The one writer of a binder (binder-v0 §4.9, §6.7, §6.9). Every change runs under the binder's `flock` lock:
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

        package init(reason: String) { self.reason = reason }
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
    package func withLock<T>(timeout: TimeInterval = 10, _ body: () throws -> T) throws -> T {
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
        try checkContainment()
        return try body()
    }

    /// `catalog.json` must be a regular file and `.sprava` a real folder, never links, so no write lands outside
    /// the binder (binder-v0 §3.6).
    func checkContainment() throws {
        var st = stat()
        if lstat(catalogURL.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG {
            throw Refused(reason: "catalog.json is not a regular file; a repair must be approved first")
        }
        if lstat(spravaDir.path, &st) == 0, st.st_mode & S_IFMT != S_IFDIR {
            throw Refused(reason: ".sprava is not a regular folder; a repair must be approved first")
        }
        for name in ["torn", "proposals", "adopted"] {
            let url = spravaDir.appendingPathComponent(name)
            if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFDIR { throw Refused(reason: ".sprava/\(name) is not a regular folder") }
        }
        for name in ["ops.ndjson", "snapshot.json", "owner.json", "cursors.json", "slice-key"] {
            let url = spravaDir.appendingPathComponent(name)
            if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG { throw Refused(reason: ".sprava/\(name) is not a regular file") }
        }
    }

    // MARK: - Reading

    public struct State {
        public var catalog: JSONObject
        public var hash: String
        public var opLog: [JSONObject]
    }

    /// The largest `catalog.json` the writer reads, the reader's limit (BinderFormat's `Teka`): a larger or sparse
    /// file is refused before it is loaded, never read whole into memory.
    static let maxCatalogBytes = 64 << 20

    func readCatalog() throws -> (JSONObject, String, Data) {
        let data: Data
        switch SafeFile.read(catalogURL, limit: Self.maxCatalogBytes) {
        case .ok(let d): data = d
        case .missing: throw CocoaError(.fileReadNoSuchFile)
        case .refused(let why), .unreadable(let why): throw Refused(reason: "catalog.json cannot be read (\(why)); it was left as it is")
        }
        let (value, safety) = try JSONParser.parse(data)
        guard case .object(let catalog) = value else { throw Refused(reason: "catalog.json is not a JSON object") }
        guard safety.isSafe else { throw Refused(reason: "catalog.json holds unsafe JSON; a repair must be approved first") }
        return (catalog, try Canonical.hash(value), data)
    }

    /// The op log's complete lines. A torn last line, and a trailing batch shorter than its `batch_size`, never
    /// took effect and are left out (binder-v0 §6.9). Only a missing log is empty; one that exists but cannot be
    /// read throws, so nothing mistakes the binder for one never adopted.
    public func readOpLog() throws -> (ops: [JSONObject], torn: Bool) {
        let data: Data
        do {
            data = try Data(contentsOf: opLogURL)
        } catch {
            var st = stat()
            if lstat(opLogURL.path, &st) != 0, errno == ENOENT { return ([], false) }
            throw Refused(reason: ".sprava/ops.ndjson cannot be read; it was left as it is")
        }
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
    public func apply(_ bodies: [OpBody], batch: String? = nil, now: Date = Date(),
                      underLock after: (() throws -> Void)? = nil) throws -> [JSONObject] {
        try apply(building: { _, _ in bodies }, batch: batch, now: now, underLock: after)
    }

    /// Applies a batch built from the catalog and the op log as read under the lock, after outside edits were
    /// absorbed, so a check such as a card's `expect` or an undo's earlier values sees exactly what the batch is
    /// applied to (architecture 4.2 step 4). `build` runs again on each pass.
    @discardableResult
    func apply(building build: (_ catalog: JSONObject, _ log: [JSONObject]) throws -> [OpBody], batch: String? = nil,
               now: Date = Date(), underLock after: (() throws -> Void)? = nil) throws -> [JSONObject] {
        testHookBeforeLock?()
        return try withLock {
            // An editor that skips the lock can change the file at any moment: each pass absorbs what it finds,
            // and a change seen while writing starts the pass again (binder-v0 §4.9 step 5).
            var attempt = 0
            while true {
                attempt += 1
                do {
                    let lines = try applyOnce(build, batch: batch, now: now)
                    try after?()
                    return lines
                } catch is ChangedWhileWriting where attempt < 5 {
                    usleep(50_000)
                }
            }
        }
    }

    /// Absorbs what happened outside and finishes or aborts a write cut short, writing nothing else.
    public func settle(now: Date = Date()) throws {
        try withLock {
            let (catalog, hash, _) = try readCatalog()
            let log = try readOpLog().ops
            guard !log.isEmpty else { return }
            try Self.refuseUnknownLevel(catalog)
            try Self.refuseUnknownOps(log)
            _ = try absorbOutsideEdits(catalog: catalog, hash: hash, log: log, now: now)
        }
    }

    /// An unknown level writes nothing, not even the record of an outside edit or the snapshot (binder-v0 §9.6).
    static func refuseUnknownLevel(_ catalog: JSONObject) throws {
        if case .unknown(let why) = CatalogLevel.classify(catalog) {
            throw Refused(reason: "this catalog's level is unknown (\(why)); Sprava writes nothing to it")
        }
    }

    /// An op type this version does not know means a newer writer wrote the log: nothing is appended after it, not
    /// even the record of an outside edit (binder-v0 §1.4).
    static func refuseUnknownOps(_ log: [JSONObject]) throws {
        if let line = log.first(where: { !OpApplier.opTypes.contains($0["op"]?.stringValue ?? "") }) {
            let type = line["op"]?.stringValue.map { String($0.prefix(40)) } ?? "none"
            throw Refused(reason: "the op log holds an op this version does not know (\(type)); a newer Sprava wrote it, and this one writes nothing to the binder")
        }
    }

    struct ChangedWhileWriting: Error, CustomStringConvertible {
        var description: String { "catalog.json keeps changing while the change is written; try again" }
    }

    /// Whether every op is the repair of a broken stamp: a `migrate` that only writes `meta.format_version` or
    /// `meta.schema_version` (binder-v0 §9.6).
    static func isStampRepair(_ bodies: [OpBody]) -> Bool {
        !bodies.isEmpty && bodies.allSatisfy { body in
            let patch = body.args["patch"]?.arrayValue ?? []
            return body.op == "migrate" && !patch.isEmpty
                && patch.allSatisfy { ["/meta/format_version", "/meta/schema_version"].contains($0["path"]?.stringValue ?? "") }
        }
    }

    func applyOnce(_ build: (JSONObject, [JSONObject]) throws -> [OpBody], batch: String?, now: Date) throws -> [JSONObject] {
        var (catalog, hash, _) = try readCatalog()
        var log = try readOpLog().ops
        guard !log.isEmpty else { throw Refused(reason: "this binder has not been adopted") }
        try Self.refuseUnknownLevel(catalog)
        try Self.refuseUnknownOps(log)
        if let absorbed = try absorbOutsideEdits(catalog: catalog, hash: hash, log: log, now: now) {
            log.append(contentsOf: absorbed)
        }
        if case .rolledForward = lastAbsorbed {
            (catalog, hash, _) = try readCatalog()
        }
        // The chain must hold before anything is appended: the head of the log is the catalog found.
        guard log.last?["after_hash"]?.stringValue == hash else { throw ChangedWhileWriting() }
        let bodies = try build(catalog, log)
        // A broken stamp blocks every write until the person approves its repair (binder-v0 §9.6).
        if CatalogLevel.classify(catalog) == .brokenStamp, !Self.isStampRepair(bodies) {
            throw Refused(reason: "the catalog's stamp is broken (meta.format_version); nothing is written until its repair is approved")
        }

        let at = ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)
        // Every write of several ops is one batch, so recovery sees all of it as the trailing write (binder-v0 §6.9).
        let batch = batch ?? (bodies.count > 1 ? UUIDv7.make(now: now) : nil)
        var lines: [JSONObject] = []
        for (seq, var body) in bodies.enumerated() {
            // An applied op carries every value its effect needs (binder-v0 §6.3): a closure's time and source are
            // written into the op, not only into the log entry.
            if ["complete", "drop"].contains(body.op) {
                if body.args["next_due"] == nil, body.args["closed_at"] == nil { body.args.set("closed_at", .string(at)) }
                if body.args["source"] == nil, let kind = body.actor["kind"] { body.args.set("source", kind) }
            }
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
        let knownIDs = Set(IDMint.usedIDs(opLog: log))
        let (result, hashes) = try TransactionGuard.check(lines, on: catalog, knownIDs: knownIDs)
        // Nothing is written that would then block every write: a level this version does not know, or a stamp left
        // broken, as a stamp repair to the wrong version would leave it (binder-v0 §1.4, §9.6).
        switch CatalogLevel.classify(result) {
        case .unknown(let why): throw Refused(reason: "the change would leave the catalog at a level Sprava does not know (\(why)); nothing was written")
        case .brokenStamp: throw Refused(reason: "the change would leave the catalog's stamp (meta.format_version) broken; nothing was written")
        default: break
        }
        var previous = hash
        for i in lines.indices {
            lines[i].set("before_hash", .string(previous))
            lines[i].set("after_hash", .string(hashes[i]))
            previous = hashes[i]
        }
        let moves = try prepareMoves(lines)
        try write(catalog: result, appending: lines, expectedHash: hash, moves: moves)
        return lines
    }

    /// What the last pass found outside (binder-v0 §6.7).
    public internal(set) var lastAbsorbed: Absorbed = .none

    /// Proposal ids this store wrote itself, for the caller to trust. A store lives for one command.
    public internal(set) var createdProposals: [String] = []

    /// Tests only: runs after a batch's op lines are flushed and before the catalog is checked again.
    package var testHookAfterAppend: (() throws -> Void)?
    /// Tests only: runs after a batch's files are moved and before the catalog is checked again.
    package var testHookAfterMoves: (() throws -> Void)?
    /// Tests only: runs right before a batch takes the lock, where another program's edit could land.
    package var testHookBeforeLock: (() -> Void)?
    /// Tests only: makes the flush of the named step fail, as a failing disk would.
    package var testHookFlushFails: ((String) -> Bool)?
    /// Tests only: stands in for `fcntl(F_FULLFSYNC)`, returning -1 with `errno` set as a disk or a volume would.
    package var testHookFullSync: ((Int32) -> Int32)?

    // MARK: - Adoption (binder-v0 §9.4 step 1)

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

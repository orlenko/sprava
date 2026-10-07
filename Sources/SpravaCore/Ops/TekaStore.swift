import CryptoKit
import Darwin
import Foundation

/// UUID version 7: time-ordered, as the op log and capture events use (binder-v0 §6.2). Ids made by one process
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

    func readCatalog() throws -> (JSONObject, String, Data) {
        let data = try Data(contentsOf: catalogURL)
        let (value, safety) = try JSONParser.parse(data)
        guard case .object(let catalog) = value else { throw Refused(reason: "catalog.json is not a JSON object") }
        guard safety.isSafe else { throw Refused(reason: "catalog.json holds unsafe JSON; a repair must be approved first") }
        return (catalog, try Canonical.hash(value), data)
    }

    /// The op log's complete lines. A torn last line, and a trailing batch shorter than its `batch_size`, never
    /// took effect and are left out (binder-v0 §6.9).
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
    public func apply(_ bodies: [OpBody], batch: String? = nil, now: Date = Date(),
                      underLock after: (() throws -> Void)? = nil) throws -> [JSONObject] {
        try withLock {
            // An editor that skips the lock can change the file at any moment: each pass absorbs what it finds,
            // and a change seen while writing starts the pass again (binder-v0 §4.9 step 5).
            var attempt = 0
            while true {
                attempt += 1
                do {
                    let lines = try applyOnce(bodies, batch: batch, now: now)
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
            _ = try absorbOutsideEdits(catalog: catalog, hash: hash, log: log, now: now)
        }
    }

    struct ChangedWhileWriting: Error, CustomStringConvertible {
        var description: String { "catalog.json keeps changing while the change is written; try again" }
    }

    func applyOnce(_ bodies: [OpBody], batch: String?, now: Date) throws -> [JSONObject] {
        var (catalog, hash, _) = try readCatalog()
        var log = try readOpLog().ops
        guard !log.isEmpty else { throw Refused(reason: "this binder has not been adopted") }
        if let absorbed = try absorbOutsideEdits(catalog: catalog, hash: hash, log: log, now: now) {
            log.append(contentsOf: absorbed)
        }
        if case .rolledForward = lastAbsorbed {
            (catalog, hash, _) = try readCatalog()
        }
        // The chain must hold before anything is appended: the head of the log is the catalog found.
        guard log.last?["after_hash"]?.stringValue == hash else { throw ChangedWhileWriting() }

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
        let moves = try prepareMoves(lines)
        try write(catalog: result, appending: lines, expectedHash: hash, moves: moves)
        return lines
    }

    /// The files a batch files (binder-v0 §4.3, §6.9 step 4). A move out of `intake/` needs the source to be a plain
    /// file with the recorded digest, so a file that changed or is gone since the card was made is refused; the
    /// destination must be free and lie inside the binder. A filing without `from` needs the file in place.
    func prepareMoves(_ lines: [JSONObject]) throws -> [(from: String, to: String, sha: String)] {
        var moves: [(String, String, String)] = []
        var claimed = Set<String>()
        for line in lines where line["op"] == .str("file_document") {
            let args = line["args"]?.objectValue ?? JSONObject()
            guard let path = args["document"]?["path"]?.stringValue, let sha = args["document"]?["sha256"]?.stringValue else { continue }
            guard claimed.insert(DocumentPaths.fold(path)).inserted else { throw Refused(reason: "two documents would be filed at \(path)") }
            if let from = args["from"]?.stringValue {
                guard DocumentPaths.plainFile(from, in: folder),
                      DocumentPaths.sha256(of: folder.appendingPathComponent(from)) == sha else {
                    throw Refused(reason: "the file in intake/ changed or is gone since the card was made")
                }
                guard DocumentPaths.isFreeDestination(path, in: folder) else {
                    throw Refused(reason: "a file already exists at \(path), or the way there is not a plain folder")
                }
                moves.append((from, path, sha))
            } else {
                guard DocumentPaths.plainFile(path, in: folder), DocumentPaths.sha256(of: folder.appendingPathComponent(path)) == sha else {
                    throw Refused(reason: "the document is not at \(path) with the recorded digest")
                }
            }
        }
        return moves
    }

    /// Step 4: each move is a rename that never replaces a file.
    func performMoves(_ moves: [(from: String, to: String, sha: String)]) throws {
        for move in moves {
            // Checked again right before the rename: the source is still a plain file, the way there has no link.
            guard DocumentPaths.plainFile(move.from, in: folder), DocumentPaths.isFreeDestination(move.to, in: folder),
                  DocumentPaths.sha256(of: folder.appendingPathComponent(move.from)) == move.sha else {
                throw Refused(reason: "the file in intake/ or its destination changed while it was being filed")
            }
            try DocumentPaths.makeParents(move.to, in: folder)
            let source = folder.appendingPathComponent(move.from).path
            let target = folder.appendingPathComponent(move.to).path
            guard renamex_np(source, target, UInt32(RENAME_EXCL)) == 0 else {
                throw AtomicFile.Failure(step: "move \(move.from)", code: errno)
            }
        }
        if !moves.isEmpty {
            for dir in Set(moves.flatMap { [($0.from as NSString).deletingLastPathComponent, ($0.to as NSString).deletingLastPathComponent] }) {
                let fd = open(folder.appendingPathComponent(dir).path, O_RDONLY | O_CLOEXEC)
                if fd >= 0 { fsync(fd); close(fd) }
            }
        }
    }

    /// Steps 4 to 7 of the write protocol and steps 3 to 6 of binder-v0 §6.9.
    func write(catalog: JSONObject, appending lines: [JSONObject], expectedHash: String,
               moves: [(from: String, to: String, sha: String)] = []) throws {
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
        guard nowHash == expectedHash else { throw ChangedWhileWriting() }

        try appendLines(lines)
        // A crash or failure from here on is rolled forward on the next read (binder-v0 §6.7 step 3, §6.9).
        try performMoves(moves)
        guard rename(temp.path, catalogURL.path) == 0 else { throw AtomicFile.Failure(step: "rename catalog", code: errno) }
        renamed = true
        let dirfd = open(folder.path, O_RDONLY | O_CLOEXEC)
        if dirfd >= 0 { fsync(dirfd); close(dirfd) }
        try AtomicFile.write(Data(text.utf8), to: snapshotURL)
    }

    func appendLines(_ lines: [JSONObject]) throws {
        try AtomicFile.makePrivateFolder(spravaDir)
        // A torn tail, or a trailing batch shorter than its size, is copied aside and cut before the next append
        // (binder-v0 §6.9).
        if let data = try? Data(contentsOf: opLogURL), let cut = Self.validLength(of: data), cut < data.count {
            let tornDir = spravaDir.appendingPathComponent("torn", isDirectory: true)
            try AtomicFile.makePrivateFolder(tornDir)
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

    /// The byte length of the op log's part that took effect: complete lines, minus a trailing batch with fewer
    /// lines than its `batch_size`.
    static func validLength(of data: Data) -> Int? {
        guard !data.isEmpty else { return nil }
        var end = data.last == 0x0A ? data.count : (data.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0)
        // Walk back over the last complete lines while they belong to one batch.
        var starts: [Int] = []
        var i = end
        var batch: String?
        var size: Int64?
        while i > 0 {
            let lineEnd = i - 1   // the newline
            let lineStart = data[..<lineEnd].lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
            guard let v = try? JSONParser.parse(data[lineStart..<lineEnd]).value, case .string(let b)? = v["batch"] else { break }
            if batch == nil {
                batch = b
                size = v["batch_size"]?.numberValue?.safeInteger
            } else if b != batch { break }
            starts.append(lineStart)
            i = lineStart
        }
        if let size, let first = starts.last, Int64(starts.count) < size { end = first }
        return end
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

    // MARK: - Outside edits (binder-v0 §6.7)

    public enum Absorbed: Equatable {
        case none
        case snapshotRewritten
        case rolledForward(Int)
        case aborted(Int)
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
        if H == b, S == b, let b {
            // A write was logged but never renamed into place: roll it forward. Ops are pure, so the result
            // has the same hash. A logged move is finished when the file is still in intake/ and the destination
            // is free, or taken as done when the destination holds the recorded digest; otherwise the write is
            // aborted (binder-v0 §6.9).
            var state = catalog
            for op in trailing { state = try OpApplier.apply(op, to: state) }
            guard try Canonical.hash(.object(state)) == a else { throw Refused(reason: "roll-forward did not reach the logged hash") }
            var moves: [(from: String, to: String, sha: String)] = []
            var possible = true
            for op in trailing where op["op"] == .str("file_document") {
                let args = op["args"]?.objectValue ?? JSONObject()
                guard let to = args["document"]?["path"]?.stringValue, let sha = args["document"]?["sha256"]?.stringValue else { continue }
                let placed = DocumentPaths.plainFile(to, in: folder) && DocumentPaths.sha256(of: folder.appendingPathComponent(to)) == sha
                if let from = args["from"]?.stringValue, !placed {
                    if DocumentPaths.plainFile(from, in: folder), DocumentPaths.sha256(of: folder.appendingPathComponent(from)) == sha,
                       DocumentPaths.isFreeDestination(to, in: folder) {
                        moves.append((from, to, sha))
                    } else {
                        possible = false
                    }
                } else if !placed {
                    possible = false
                }
            }
            guard possible else {
                var abort = JSONObject()
                abort.set("id", .string(UUIDv7.make(now: now)))
                abort.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
                abort.set("actor", .obj([("kind", .str("import")), ("client", .string(client))]))
                abort.set("before_hash", .string(b))
                abort.set("after_hash", .string(b))
                abort.set("op", .str("abort"))
                abort.set("args", .obj([("ops", .array(trailing.compactMap { $0["id"] })),
                                        ("reason", .str("a filed file is missing from both intake/ and its destination"))]))
                try appendLines([abort])
                lastAbsorbed = .aborted(trailing.count)
                return [abort]
            }
            try write(catalog: state, appending: [], expectedHash: H, moves: moves)
            lastAbsorbed = .rolledForward(trailing.count)
            return nil
        }

        // Someone else edited the file (or reverted our last write). When the snapshot shows the trailing write
        // never reached the disk (S = b), an abort names its ops first and the snapshot is the expected state;
        // when it matches the head (S = a), the snapshot is the expected state; otherwise replay decides.
        var appended: [JSONObject] = []
        var expected: JSONObject
        let utc = TimeZone(identifier: "UTC")!
        let snapshot: JSONObject? = (try? Data(contentsOf: snapshotURL)).flatMap { try? JSONParser.parse($0).value.objectValue } ?? nil
        var effectiveLog = log
        if S == b, S != a, let snap = snapshot, let b {
            var abort = JSONObject()
            abort.set("id", .string(UUIDv7.make(now: now)))
            abort.set("at", .string(ISOTime.string(now, timeZone: utc)))
            abort.set("actor", .obj([("kind", .str("import")), ("client", .string(client))]))
            abort.set("before_hash", .string(b))
            abort.set("after_hash", .string(b))
            abort.set("op", .str("abort"))
            abort.set("args", .obj([("ops", .array(trailing.compactMap { $0["id"] })),
                                    ("reason", .str("the catalog was edited outside before this write reached the disk"))]))
            appended.append(abort)
            effectiveLog.append(abort)
            expected = snap
        } else if S == a, let snap = snapshot {
            expected = snap
        } else {
            expected = try Replay.run(log)
        }
        let expectedHash = try Canonical.hash(.object(expected))
        let patch = JSONPatch.diff(from: .object(expected), to: .object(catalog))
        let ambiguous = H == b && S == nil
        let reverted = H == b && S == a
        let lostOps: [JSONObject]
        if appended.isEmpty, reverted || ambiguous {
            lostOps = trailing
        } else if appended.isEmpty, log.count > trailing.count,
                  Self.undoes(found: catalog, expected: expected, beforeTrailing: try? Replay.run(Array(log.dropLast(trailing.count))),
                              trailing: trailing) {
            lostOps = trailing
        } else {
            lostOps = []
        }
        var args = JSONObject()
        args.set("patch", .array(patch))
        args.set("detected_at", .string(ISOTime.string(now, timeZone: utc)))
        if reverted { args.set("hint", .str("the catalog was put back as it was before the last change")) }
        else if !lostOps.isEmpty { args.set("hint", .str("a change of yours was overwritten by another program")) }
        else if let hint = Self.hint(for: patch) { args.set("hint", .string(hint)) }
        var line = JSONObject()
        line.set("id", .string(UUIDv7.make(now: now)))
        line.set("at", .string(ISOTime.string(now, timeZone: utc)))
        line.set("actor", .obj([("kind", .str("external")), ("client", .string(client)), ("origin", .str("unknown"))]))
        line.set("before_hash", .string(expectedHash))
        line.set("after_hash", .string(H))
        line.set("op", .str("external_edit"))
        line.set("args", .object(args))
        appended.append(line)
        try appendLines(appended)
        try AtomicFile.write(Data(JSONWriter.pretty(.object(catalog)).utf8), to: snapshotURL)
        lastAbsorbed = .externalEdit(revertedLastBatch: !lostOps.isEmpty)
        // The loss is never absorbed silently (binder-v0 §6.7 step 6): a card offers the lost ops again, as the
        // person's own new ops.
        if !lostOps.isEmpty, let card = Self.reapplyCard(lostOps, client: client, now: now) {
            try ProposalStore.save(card, in: folder)
            createdProposals.append(card.id)
        }
        return appended
    }

    /// Proposal ids this store wrote itself, for the caller to trust. A store lives for one command.
    public private(set) var createdProposals: [String] = []

    /// "Apply again" for ops another program overwrote: the same ops as new ops by the user. An added item gets a
    /// placeholder, because its old id was used once and is never reused.
    static func reapplyCard(_ ops: [JSONObject], client: String, now: Date) -> Proposal? {
        var n = 0
        let bodies: [JSONObject] = ops.compactMap { op in
            guard let type = op["op"]?.stringValue, ["add_item", "update_item", "set_status", "complete", "drop"].contains(type),
                  var args = op["args"]?.objectValue else { return nil }
            if type == "add_item", var item = args["item"]?.objectValue {
                n += 1
                item.set("id", .string("$new:\(n)"))
                args.set("item", .object(item))
            }
            return JSONObject([(key: "op", value: .string(type)), (key: "args", value: .object(args))])
        }
        guard !bodies.isEmpty else { return nil }
        let actor = JSONObject([(key: "kind", value: .str("user")), (key: "client", value: .string(client))])
        return Proposal.make(title: "A change of yours was overwritten by another program. Apply it again?", actor: actor,
                             ops: bodies, provenance: JSONObject([(key: "overwritten_ops", value: .array(ops.compactMap { $0["id"] }))]),
                             now: now)
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
    /// (binder-v0 §6.7 step 6): another program overwrote the person's change.
    static func undoes(found: JSONObject, expected: JSONObject, beforeTrailing: JSONObject?, trailing: [JSONObject]) -> Bool {
        guard let before = beforeTrailing, !trailing.isEmpty,
              trailing.allSatisfy({ ["user", "clerk", "brain"].contains($0["actor"]?["kind"]?.stringValue ?? "") }) else {
            return false
        }
        // Records are compared by id, so an unrelated edit elsewhere in the same array does not hide the loss.
        func record(_ catalog: JSONObject, _ id: JSONValue) -> JSONValue? {
            for key in ["open_items", "documents"] {
                if let r = catalog[key]?.arrayValue?.first(where: { $0["id"] == id }) { return r }
            }
            return nil
        }
        var checked = false
        for op in trailing {
            let args = op["args"]?.objectValue ?? JSONObject()
            let ids = [args["id"], args["item"]?["id"], args["document"]?["id"]].compactMap { $0 }
            if ids.isEmpty {
                // An op without a record id (set_meta and the like): its changed paths must be back as before.
                let changed = JSONPatch.diff(from: .object(before), to: .object(expected)).compactMap { $0["path"]?.stringValue }
                guard !changed.isEmpty, changed.allSatisfy({ JSONPatch.value(at: $0, in: .object(found)) == JSONPatch.value(at: $0, in: .object(before)) })
                else { return false }
                checked = true
                continue
            }
            for id in ids {
                guard record(found, id) == record(before, id) else { return false }
                checked = true
            }
            if let opID = op["id"], found["processing_log"]?.arrayValue?.contains(where: { $0["op_id"] == opID }) == true { return false }
        }
        return checked
    }

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

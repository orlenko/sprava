import BinderFormat
import BinderStore
import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// Draining the hub's outbox into the binder, with the safer acknowledgement of binder-v0 §8.3.
extension HubLane {
    public struct DrainResult: Equatable {
        public var applied = 0
        public var acknowledged = 0
        public var skipped = 0
        public var waitingForYou = 0
        /// Cards Sprava wrote while absorbing an outside edit, for the caller to trust.
        public var createdProposals: [String] = []

        package init(applied: Int = 0, acknowledged: Int = 0, skipped: Int = 0, waitingForYou: Int = 0, createdProposals: [String] = []) {
            self.applied = applied
            self.acknowledged = acknowledged
            self.skipped = skipped
            self.waitingForYou = waitingForYou
            self.createdProposals = createdProposals
        }
    }

    /// Drains the outbox under the binder's name and, until each one's `until` date, the outboxes under its former
    /// names, where the hub may still write after a rename (binder-v0 §8.3).
    public static func drain(_ folder: URL, root: URL = spoolRoot(), now: Date = Date(), client: String = "sprava/0.1") throws -> DrainResult {
        var result = DrainResult()
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0 else { return result }
        let teka = Teka.read(folder)
        guard teka.isAdopted, teka.catalog != nil, !teka.federationBlocked else { return result }
        let outboxDir = root.appendingPathComponent("outbox", isDirectory: true)
        var info = stat()
        guard lstat(outboxDir.path, &info) == 0 else { return result }
        try checkFolder(outboxDir, create: false)
        // A former name without a readable `until` counts as unexpired, as in `collidingFolders`, which keeps every
        // such name from another binder.
        let today = CalendarDate.today(now: now)
        var outboxNames = [teka.name]
        for former in teka.catalog?["meta"]?["former_names"]?.arrayValue ?? [] {
            guard let name = former["name"]?.stringValue, isSafeSegment(name) else { continue }
            if let until = former["until"]?.stringValue.flatMap({ CalendarDate.strict(String($0.prefix(10))) }), until < today { continue }
            guard !outboxNames.contains(where: { foldedName($0) == foldedName(name) }) else { continue }
            outboxNames.append(name)
        }
        for name in outboxNames {
            let one = try drainOutbox(folder, file: try spoolFile(outboxDir, name, ".intake.json"),
                                      names: name == teka.name ? [name] : [teka.name, name], now: now, client: client)
            result.applied += one.applied
            result.acknowledged += one.acknowledged
            result.skipped += one.skipped
            result.waitingForYou += one.waitingForYou
            result.createdProposals += one.createdProposals
        }
        return result
    }

    /// Drains one outbox file. `names` are the binder names its completion ids may be prefixed or aliased with: the
    /// current one, and in a former name's outbox that name too (binder-v0 §8.3).
    static func drainOutbox(_ folder: URL, file: URL, names: [String], now: Date, client: String) throws -> DrainResult {
        var result = DrainResult()
        guard let data = try readOutbox(file) else { return result }
        guard case .object(let outbox) = try JSONParser.parse(data).value else { throw TekaStore.Refused(reason: "outbox is not a JSON object") }
        let completions = (outbox["completions"]?.arrayValue ?? []).compactMap(\.objectValue)
        guard !completions.isEmpty else { return result }

        // Read again for each outbox: the one before may have closed items.
        let teka = Teka.read(folder)
        guard teka.isAdopted, let catalog = teka.catalog, !teka.federationBlocked else { return result }
        // Only a publish, under the binder lock, makes the key; with none there are no aliases to resolve yet.
        let key = try existingSliceKey(folder)
        let cursors = try readCursors(folder)
        let items = (catalog["open_items"]?.arrayValue ?? []).compactMap(\.objectValue)
        let log = catalog["processing_log"]?.arrayValue ?? []

        // Open items, then the ids already closed: an id is never reused, so a completion for a closed one is
        // acknowledged, as lifeproj does by id, for example after an earlier drain whose acknowledgement was lost.
        let candidates: [(id: JSONValue, item: JSONObject?)] = items.compactMap { it in it["id"].map { ($0, it) } }
            + log.compactMap { e in
                guard let id = e["id"], ["done", "dropped"].contains(e["action"]?.stringValue ?? "") else { return nil }
                return (id, nil)
            }
        /// Resolves a completion id in the order of binder-v0 §8.3, each rule across every item before the next: the
        /// raw id, `<binder>-<raw>`, an alias, then the id last published. The first match wins, so `demo-demo-a`
        /// reaches the item `demo-demo-a`, never `demo-a` by the looser prefix rule.
        func resolve(_ cid: String) -> (id: JSONValue, item: JSONObject?)? {
            let rules: [(JSONValue) -> Bool] = [
                { idText($0) == cid },
                { id in names.contains { "\($0)-\(idText(id))" == cid } },
                { id in key.map { key in names.contains { alias(id, teka: $0, key: key) == cid } } ?? false },
                { cursors.published[(try? Canonical.serialize($0)) ?? ""] == cid },
            ]
            for rule in rules {
                if let found = candidates.first(where: { rule($0.id) }) { return found }
            }
            return nil
        }

        let actor = JSONObject([(key: "kind", value: .str("external")), (key: "client", value: .string(client)),
                                (key: "origin", value: .str("spool-outbox"))])
        var bodies: [TekaStore.OpBody] = []
        var toAck: [(String, JSONValue?)] = []
        var trial = catalog
        for c in completions {
            guard case .string(let cid)? = c["id"], let action = c["action"]?.stringValue, ["done", "dropped"].contains(action) else {
                result.skipped += 1
                continue
            }
            guard let found = resolve(cid) else {
                result.skipped += 1
                continue
            }
            guard let item = found.item else {
                toAck.append((cid, c["at"]))
                continue
            }
            if item["recurrence"] != nil {
                // The MVP leaves recurring items to the hub; the completion waits (mvp.md feature 2).
                result.waitingForYou += 1
                continue
            }
            var args = JSONObject()
            args.set("id", found.id)
            let atValue: JSONValue = c["at"].flatMap { $0.stringValue != nil ? $0 : nil } ?? .null
            args.set("closed_at", atValue)
            args.set("source", c["source"].flatMap { $0.stringValue != nil ? $0 : nil } ?? .str("osavul"))
            let op = action == "done" ? "complete" : "drop"
            // Each completion is checked on its own; one bad completion never blocks the others.
            var line = JSONObject()
            line.set("id", .string(UUIDv7.make(now: now)))
            line.set("at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!)))
            line.set("actor", .object(actor))
            line.set("op", .string(op))
            line.set("args", .object(args))
            if let next = try? TransactionGuard.check([line], on: trial) {
                trial = next.catalog
                bodies.append(.init(op: op, args: args, actor: actor))
                toAck.append((cid, c["at"]))
            } else {
                result.skipped += 1
            }
        }
        // The binder lock is held from the write through the acknowledgement (binder-v0 §4.9).
        let store = TekaStore(folder: folder, client: client)
        if !bodies.isEmpty {
            var acknowledged = 0
            try store.apply(bodies, batch: UUIDv7.make(now: now), now: now) {
                acknowledged = try acknowledge(file: file, applied: toAck)
            }
            result.applied = bodies.count
            result.acknowledged = acknowledged
            result.createdProposals = store.createdProposals
        } else if !toAck.isEmpty {
            result.acknowledged = try store.withLock { try acknowledge(file: file, applied: toAck) }
        }
        return result
    }

    /// An outbox file's bytes, nil when there is none. Only a regular file of this user, at most 16 MB, is read,
    /// opened without following a link and without waiting, so a FIFO or a link there can neither stall the hub pass
    /// nor redirect it. Any other outbox that cannot be read is a failure, so the breaker sees it.
    static func readOutbox(_ file: URL) throws -> Data? {
        var info = stat()
        if lstat(file.path, &info) != 0 {
            guard errno == ENOENT else { throw TekaStore.Refused(reason: "the outbox cannot be read") }
            return nil
        }
        switch SafeFile.read(file) {
        case .ok(let data): return data
        case .refused(let why): throw TekaStore.Refused(reason: "the outbox cannot be read: it is \(why)")
        case .missing, .unreadable: throw TekaStore.Refused(reason: "the outbox cannot be read")
        }
    }

    /// Steps 1 to 4 of binder-v0 §8.3: re-read, remove only what was applied (by id and at), write and flush the
    /// replacement, and rename it only when the file did not change since the re-read; delete the file only when
    /// nothing else is in it. An outbox whose `completions` or `items` is not a list is left as it is for repair,
    /// never read as empty. `beforeRename` is for tests: it runs where a write by the hub could land.
    static func acknowledge(file: URL, applied: [(String, JSONValue?)], beforeRename: (() -> Void)? = nil) throws -> Int {
        for _ in 0..<5 {
            guard let data = try readOutbox(file) else { return 0 }
            guard case .object(var fresh) = try JSONParser.parse(data).value else {
                throw TekaStore.Refused(reason: "the outbox is not a JSON object; it was left as it is")
            }
            let before = SHA256.hash(data: data)
            func list(_ key: String) throws -> [JSONValue] {
                switch fresh[key] {
                case nil: return []
                case .array(let a)?: return a
                default: throw TekaStore.Refused(reason: "the outbox's \(key) is not a list; it was left as it is")
                }
            }
            let completions = try list("completions")
            let items = try list("items")
            var removed = 0
            let kept = completions.filter { c in
                let match = applied.contains { $0.0 == c["id"]?.stringValue && $0.1 == c["at"] }
                if match { removed += 1 }
                return !match
            }
            fresh.set("completions", .array(kept))
            let onlyKnown = Set(fresh.keys).isSubset(of: ["teka", "generated", "completions", "items", "format_version"])
            let empty = kept.isEmpty && items.isEmpty && onlyKnown
            func unchanged() -> Bool {
                beforeRename?()
                return (try? readOutbox(file)).flatMap { $0 }.map { SHA256.hash(data: $0) == before } ?? false
            }
            if empty {
                guard unchanged() else { continue }
                try FileManager.default.removeItem(at: file)
                return removed
            }
            if try replace(file, with: Data(JSONWriter.pretty(.object(fresh)).utf8), if: unchanged) { return removed }
        }
        throw TekaStore.Refused(reason: "the outbox kept changing; acknowledgement retried later")
    }

    /// The flushing system calls `replace` makes, replaceable in tests to make them fail.
    struct Flush {
        var fullSync: (Int32) -> Int32 = { fcntl($0, F_FULLFSYNC) }
        var sync: (Int32) -> Int32 = { fsync($0) }
        var openFolder: (String) -> Int32 = { open($0, O_RDONLY | O_CLOEXEC) }
    }

    /// `AtomicFile.write` with one more check between the flush and the rename: when `stillCurrent` says the file
    /// changed meanwhile, the temporary file goes, nothing is replaced, and the result is false. The slow part, the
    /// write and its `F_FULLFSYNC`, so comes before the last look at the file, not after it. Every flush is checked
    /// as `AtomicFile` checks it: a failed `F_FULLFSYNC` fails the write unless the volume lacks it, and so does a
    /// folder that cannot be opened or flushed after the rename (binder-v0 §4.9).
    static func replace(_ url: URL, with data: Data, if stillCurrent: () -> Bool, flush: Flush = Flush()) throws -> Bool {
        let folder = url.deletingLastPathComponent()
        let temp = folder.appendingPathComponent(".\(UUID().uuidString.lowercased()).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw AtomicFile.Failure(step: "create temp", code: errno) }
        var renamed = false
        defer {
            if !renamed { unlink(temp.path) }
        }
        do {
            defer { close(fd) }
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
            try flushToDisk(fd, step: "fsync", flush: flush)
        }
        guard stillCurrent() else { return false }
        guard rename(temp.path, url.path) == 0 else { throw AtomicFile.Failure(step: "rename", code: errno) }
        renamed = true
        var dirfd: Int32 = -1
        try retrying("open folder") {
            dirfd = flush.openFolder(folder.path)
            return dirfd
        }
        defer { close(dirfd) }
        try flushToDisk(dirfd, step: "fsync folder", flush: flush)
        return true
    }

    /// `F_FULLFSYNC`, or `fsync` when the volume does not support it; any other failure is reported.
    private static func flushToDisk(_ fd: Int32, step: String, flush: Flush) throws {
        while flush.fullSync(fd) < 0 {
            let code = errno
            if code == EINTR { continue }
            guard code == ENOTSUP || code == EINVAL || code == ENOTTY else { throw AtomicFile.Failure(step: step, code: code) }
            try retrying(step) { flush.sync(fd) }
            return
        }
    }

    /// Runs a call that returns -1 and sets `errno` on failure, again while it is interrupted.
    private static func retrying(_ step: String, _ call: () -> Int32) throws {
        while call() < 0 {
            let code = errno
            if code != EINTR { throw AtomicFile.Failure(step: step, code: code) }
        }
    }
}

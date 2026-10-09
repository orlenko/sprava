import BinderFormat
import BinderStore
import Clerk
import CryptoKit
import Foundation
import Shelf
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
    }

    func notices() -> [String: String] {
        guard let text = try? String(contentsOf: noticesURL, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard let v = try? JSONParser.parse(String(line)).value, let e = v["event"]?.stringValue, let d = v["sha256"]?.stringValue else { continue }
            out[e] = d
        }
        return out
    }

    // MARK: - State and journal

    /// The cursor (capture-event-v0 §5.3): what happened to each event id, the dedupe keys, and the names examined.
    package struct State: Codable {
        package var ingested: [String: String] = [:]          // id -> stage
        package var dedupe: [String: String] = [:]            // app|ref|revision -> id
        var apps: [String: String] = [:]              // id -> source.app, for supersede chains
        package var cards: [String: String] = [:]             // id -> the proposal id of its card
        package var paths: [String: String]? = [:]            // id -> device/name, for the clerk
        var cardBinder: [String: String]? = [:]       // id -> folder path of a filed Tier 0 card
        var hints: [String: String]? = [:]            // id -> the binder name a verified hint named
        package var clerk: [String: String]? = [:]            // id -> pending, retry, done, kept, acted, poison, failed, retracted, superseded
        package var attempts: [String: Int]? = [:]
        var chains: [String: [String]]? = [:]         // app|ref -> event ids, oldest first (capture-event-v0 §3.2)
        var texts: [String: String]? = [:]            // id -> SHA-256 of its text, to see a change that is not one
        var clocks: [String: String]? = [:]           // id -> its HLC as sortable text, to find a chain's current event
        package var raises: [String: [String]]? = [:]         // id -> a chain whose raise to private failed, retried each sweep
        var privates: [String]? = []                  // ids raised to private, or private by their chain (capture-event-v0 §3.3)
        package var examined: [String: Examined] = [:]        // device/name -> last seen
        package struct Examined: Codable, Equatable {
            var size: Int
            var mtime: Double
            var outcome: String
        }

        package init() {}
    }

    /// The cursor, for readers: empty when it cannot be read.
    package func loadState() -> State { (try? readState()) ?? State() }

    /// The cursor, for writers: a fresh one only when `state.json` does not exist. One that cannot be read throws,
    /// so it is never rebuilt over and no capture gets a second card (capture-event-v0 §5.3).
    package func readState() throws -> State {
        try StateFile.read(State.self, from: stateURL) ?? State()
    }

    package func save(_ s: State) throws {
        try AtomicFile.makePrivateFolder(dir)
        try AtomicFile.write(try JSONEncoder().encode(s), to: stateURL)
    }

    /// One journal line: event ids, stages, counts and codes, never text or titles.
    func journal(_ fields: [(String, JSONValue)]) {
        try? AtomicFile.makePrivateFolder(dir)
        AtomicFile.appendLine(JSONWriter.compact(.obj([("at", .string(ISOTime.string(Date())))] + fields)), to: journalURL)
    }

    /// Keeps a copy of a malformed file with the reason, for the Health page. The original is never touched.
    func quarantine(_ file: URL, device: String, reason: String) {
        let folder = quarantineDir.appendingPathComponent(device, isDirectory: true)
        guard case .ok(let data) = SafeFile.read(file), (try? AtomicFile.makePrivateFolder(folder)) != nil else { return }
        try? AtomicFile.write(data, to: folder.appendingPathComponent(file.lastPathComponent))
        try? AtomicFile.write(Data((reason + "\n").utf8), to: folder.appendingPathComponent(file.lastPathComponent + ".why"))
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
    }

    // MARK: - Sweep

    /// One pass: list every device folder, diff against the cursor, ingest what is complete.
    public func sweep(binders: [ShelfRow], commands: Commands, now: Date = Date()) -> SweepResult {
        var result = SweepResult()
        guard SafeFile.isTrustedFolder(root) else {
            if FileManager.default.fileExists(atPath: root.path) { result.refusedFolders += 1 }
            return result
        }
        // A cursor, registry or digest list that cannot be read stops the sweep: rebuilt, it would card every
        // capture again and save over what is there (capture-event-v0 §5.3).
        var state: State
        let producers: [String: String]
        do {
            state = try readState()
            producers = try readProducers()
            _ = try unfiledDigests()
        } catch {
            result.unreadable = (error as? ShelfStore.Unreadable).map { URL(fileURLWithPath: $0.path).lastPathComponent } ?? "capture state"
            journal([("stage", .str("state_unreadable"))])
            return result
        }
        let notices = notices()
        let fm = FileManager.default
        // A card the person filed just before a crash leaves its Inbox copy behind; it goes now.
        dropFiled(binders: binders, commands: commands)
        // Raises to private that could not be written last time are tried again first.
        for (id, chain) in (state.raises ?? [:]).sorted(by: { $0.key < $1.key }) where raisePrivacy(chain: chain, binders: binders, commands: commands, now: now) {
            state.raises?[id] = nil
        }
        guard let devices = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return result }
        for device in devices.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where !device.lastPathComponent.hasPrefix(".") {
            let deviceName = device.lastPathComponent
            guard SafeFile.isTrustedFolder(device) else {
                if (try? device.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) != true { result.refusedFolders += 1 }
                continue
            }
            guard let names = try? fm.contentsOfDirectory(atPath: device.path) else { continue }
            for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
                let file = device.appendingPathComponent(name)
                let stem = String(name.dropLast(5))
                // The journal names an event only by a valid id; any other file name may be the person's words.
                let logged: JSONValue = CaptureEvent.isUUIDText(stem) ? .string(stem) : .str("invalid-name")
                // An id still at "ingested" crashed before its card was made, and one at "retracting" has a part of
                // its retraction left to do: either is picked up again here.
                if let stage = state.ingested[stem], stage != "ingested", stage != "retracting" { continue }
                let key = deviceName + "/" + name
                var st = stat()
                guard lstat(file.path, &st) == 0 else { continue }
                let size = Int(st.st_size)
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                if let seen = state.examined[key], seen.size == size, seen.mtime == mtime, seen.outcome != "pending" { continue }
                var (check, event) = CaptureEvent.check(file, deviceFolder: device)
                if case .complete(.capture) = check, let e = event, let expected = producers[deviceName], e.app != expected {
                    check = .quarantined("source.app does not match the folder's registered producer")
                    event = nil
                }
                // The app sends its notice around the moment it publishes; an own-folder note without one waits a
                // few seconds, so the binder the person chose is not lost to a sweep that ran first (architecture 8).
                if case .complete(.capture) = check, producers[deviceName] == "sprava", let e = event, notices[e.id] == nil {
                    let age = now.timeIntervalSince1970 - mtime
                    if age > -60 && age < 10 {
                        result.pending += 1
                        state.examined[key] = .init(size: size, mtime: mtime, outcome: "pending")
                        continue
                    }
                }
                switch check {
                case .pending:
                    result.pending += 1
                    state.examined[key] = .init(size: size, mtime: mtime, outcome: "pending")
                case .deferred:
                    state.examined[key] = .init(size: size, mtime: mtime, outcome: "deferred")
                    journal([("event", logged), ("stage", .str("newer_format"))])
                case .quarantined(let why):
                    result.quarantined += 1
                    state.examined[key] = .init(size: size, mtime: mtime, outcome: "quarantined")
                    quarantine(file, device: deviceName, reason: why)
                    journal([("event", logged), ("stage", .str("quarantined")), ("reason", .string(why))])
                case .complete(.derived):
                    state.ingested[stem] = "derived"
                case .complete(.capture):
                    guard let event else { continue }
                    state.paths = (state.paths ?? [:]).merging([stem: key]) { $1 }
                    ingest(event, device: deviceName, producer: producers[deviceName], notice: notices[stem], size: size,
                           state: &state, result: &result, binders: binders, commands: commands, now: now)
                }
            }
        }
        try? save(state)
        return result
    }

    func ingest(_ event: CaptureEvent, device: String, producer: String?, notice: String?, size: Int, state: inout State,
                result: inout SweepResult, binders: [ShelfRow], commands: Commands, now: Date) {
        let id = event.id
        let textHash = CaptureInbox.digest(Data(event.text.utf8))
        // Only a registered producer's own events can change a chain (architecture 8; capture-event-v0 §3.2).
        let registered = producer != nil && producer == event.app
        let chainKey = event.app + "|" + (event.raw["source"]?["ref"]?.stringValue ?? "")
        let chain = registered ? (state.chains?[chainKey] ?? []).filter { $0 != id } : []
        // The current event of a chain is the one with the highest HLC (capture-event-v0 §3.2).
        let clocks = state.clocks ?? [:]
        let current = chain.max { (clocks[$0] ?? "") < (clocks[$1] ?? "") }
        let currentRetracted = current.map { ["retracted", "retracting"].contains(state.ingested[$0] ?? "") } ?? false
        // A deletion after the chain's current event, or a restore after its deletion, changes what the chain is:
        // neither repeats an earlier event of the same triple, so neither is taken for a duplicate (§3.2).
        let transition = current.map { (clocks[$0] ?? "") < Self.clockKey(event) } == true && event.retracted != currentRetracted

        if state.ingested[id] == nil {
            if let earlier = state.dedupe[event.dedupeKey], !transition {
                // The same capture again: only a raise of sensitivity is applied (capture-event-v0 §3.2).
                result.duplicates += 1
                state.ingested[id] = "duplicate"
                if registered, event.isPrivate { raise([earlier] + chain, for: id, state: &state, binders: binders, commands: commands, now: now) }
                journal([("event", .string(id)), ("stage", .str("duplicate")), ("of", .string(earlier))])
                return
            }
            // Ingesting is one durable step, recorded before anything else happens.
            state.ingested[id] = "ingested"
            state.dedupe[event.dedupeKey] = id
            state.apps[id] = event.app
            state.texts = (state.texts ?? [:]).merging([id: textHash]) { $1 }
            state.clocks = (state.clocks ?? [:]).merging([id: Self.clockKey(event)]) { $1 }
            if registered { state.chains = (state.chains ?? [:]).merging([chainKey: chain + [id]]) { $1 } }
            try? save(state)
            journal([("event", .string(id)), ("stage", .str("ingested")), ("bytes", .int(size))])
            result.ingested += 1
        }

        // A revision that arrives late but is older than what the chain already has changes nothing.
        if let current, (clocks[current] ?? "") > Self.clockKey(event) {
            state.ingested[id] = "stale_revision"
            journal([("event", .string(id)), ("stage", .str("stale_revision"))])
            return
        }
        if event.retracted {
            // Every part of a retraction is done, or the stage says so and the next sweep does the rest.
            let done = chain.isEmpty || retract(chain: chain, retraction: id, state: &state, binders: binders, commands: commands, now: now)
            state.ingested[id] = done ? "retracted" : "retracting"
            journal([("event", .string(id)), ("stage", .str(done ? "retracted" : "retract_failed"))])
            return
        }
        if event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.ingested[id] = "nothing_to_file"
            return
        }
        if event.isPrivate, current != nil { raise(chain, for: id, state: &state, binders: binders, commands: commands, now: now) }
        // A chain raised to private stays private for every card made from it later (§3.3).
        let filedAs = Self.asFiled(event, privates: Set(state.privates ?? []), chain: chain)
        if filedAs.isPrivate { markPrivate([id], state: &state) }
        // A later event of the chain: the same text changes only sensitivity; other text replaces what still waits.
        // A restore after a deletion is new content to review, since what was filed may be dropped by now (§3.2).
        var replaces: String?
        if let earlier = current, !currentRetracted {
            if state.texts?[earlier] == textHash {
                state.ingested[id] = "same_text"
                journal([("event", .string(id)), ("stage", .str("same_text"))])
                return
            }
            replaces = earlier
            // Items already filed from the earlier version get a change card, never new items beside them (§6.5). What
            // waits from the chain is withdrawn only once those cards are kept: when one cannot be saved or trusted,
            // nothing changed, the stage stays "ingested", and the next sweep tries again from the same place.
            let withdrawing = withdrawable(chain: chain, binders: binders, deviceID: commands.deviceID)
            let corrections: [(URL?, String)]?
            do {
                corrections = try correctionCards(filedAs, chain: chain, current: earlier, withdrawn: withdrawing, paths: state.paths ?? [:],
                                                  binders: binders, commands: commands, now: now)
            } catch {
                journal([("event", .string(id)), ("stage", .str("card_failed")), ("code", .string("\(type(of: error))"))])
                return
            }
            withdraw(chain: chain, reason: "replaced by a corrected note", state: &state, binders: binders, deviceID: commands.deviceID, now: now)
            if let made = corrections {
                if let (folder, card) = made.first {
                    state.cards[id] = card
                    if let folder { state.cardBinder = (state.cardBinder ?? [:]).merging([id: folder.path]) { $1 } }
                    result.filed += 1
                }
                state.clerk = (state.clerk ?? [:]).merging([id: "kept"]) { $1 }   // the clerk would add them again
                state.ingested[id] = made.isEmpty ? "nothing_to_change" : "proposed"
                journal([("event", .string(id)), ("stage", .str("correction_proposed")), ("cards", .int(made.count))])
                return
            }
        }

        // Verification (architecture 8): Sprava's own folder needs a matching notice; an unregistered folder is
        // unverified; a hint is honoured only from a verified note of Sprava's own.
        let own = producer == "sprava"
        let verified = own ? notice == event.digest : producer != nil
        let hint = own && verified ? event.binderHint : nil
        let made: (String, URL?)
        do {
            // A card made before a crash, whose id never reached the cursor, is kept, never made twice (§5.3).
            let (waitingUnfiled, waitingFiled) = pendingCards(chain: [id], binders: binders, deviceID: commands.deviceID)
            if let p = waitingUnfiled.first {
                made = (p.id, nil)
            } else if let (folder, p) = waitingFiled.first {
                made = (p.id, folder)
            } else {
                made = try card(for: filedAs, hint: hint, verified: verified, producer: producer ?? event.app,
                                replaces: replaces, binders: binders, commands: commands, now: now)
            }
        } catch {
            // The stage stays "ingested", so the next sweep makes the card.
            journal([("event", .string(id)), ("stage", .str("card_failed")), ("code", .string("\(type(of: error))"))])
            return
        }
        let (proposalID, filedTo) = made
        state.cards[id] = proposalID
        if let filedTo { state.cardBinder = (state.cardBinder ?? [:]).merging([id: filedTo.path]) { $1 } }
        if let hint, filedTo != nil { state.hints = (state.hints ?? [:]).merging([id: hint]) { $1 } }
        // The clerk reads it next; private captures too, on the device.
        state.clerk = (state.clerk ?? [:]).merging([id: "pending"]) { $1 }
        state.ingested[id] = filedTo == nil ? "unfiled" : "proposed"
        try? save(state)   // the card's id reaches the cursor now, not at the end of the sweep
        if filedTo == nil { result.unfiled += 1 } else { result.filed += 1 }
        if let end = event.endedAt { result.latencies.append(max(0, now.timeIntervalSince(end))) }
        journal([("event", .string(id)), ("stage", .str(filedTo == nil ? "unfiled" : "proposed")), ("tier", .str("0")),
                 ("verified", .bool(verified))])
    }

    /// An event's HLC as text that sorts like the clock: wall time, counter, then the id breaks a tie.
    static func clockKey(_ event: CaptureEvent) -> String {
        let wall = event.raw["hlc"]?["wall_ms"]?.numberValue?.safeInteger ?? 0
        let counter = event.raw["hlc"]?["counter"]?.numberValue?.safeInteger ?? 0
        return String(format: "%016lld:%08lld:", wall, counter) + event.id
    }

    /// Pending cards built from any event of a chain: unfiled ones, and proposals waiting in the binders this Mac
    /// manages (a binder another Mac owns is read-only here, mvp.md feature 1).
    func pendingCards(chain: [String], binders: [ShelfRow], deviceID: String) -> (unfiled: [Proposal], filed: [(URL, Proposal)]) {
        let ids = Set(chain)
        func fromChain(_ p: Proposal) -> Bool {
            !(p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter(ids.contains).isEmpty
        }
        let unfiled = self.unfiled().filter(fromChain)
        var filed: [(URL, Proposal)] = []
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == deviceID {
            for (p, _) in ProposalStore.list(in: row.folder) where p.state == "proposed" && fromChain(p) { filed.append((row.folder, p)) }
        }
        return (unfiled, filed)
    }

    /// What happened to one line of an earlier text in the corrected one.
    enum LineFate: Equatable { case same(Int), changed(Int), removed }

    /// The most cells the line diff's table may have (16 MB): a correction runs during the sweep, outside the clerk's
    /// poison rule, so its work is bounded whatever the size of the note.
    static let diffCells = 4_000_000

    /// A line diff: the longest common run of equal lines anchors the two texts; between anchors, old and new lines
    /// pair up in order as changed, and what is left over was removed or added. Returns each old line's fate and the
    /// indices of the added new lines. Equal lines at both ends anchor first; when what lies between them would
    /// need a table over `diffCells`, it has no anchors and its lines pair up in order.
    static func diffLines(_ old: [String], _ new: [String]) -> (fates: [LineFate], added: [Int]) {
        let n = old.count, m = new.count
        var head = 0
        while head < n, head < m, old[head] == new[head] { head += 1 }
        var tail = 0
        while tail < n - head, tail < m - head, old[n - 1 - tail] == new[m - 1 - tail] { tail += 1 }
        var anchors: [(Int, Int)] = (0..<head).map { ($0, $0) }
        let rows = n - head - tail, cols = m - head - tail
        if rows > 0, cols > 0, rows * cols <= diffCells {
            // Lines as numbers, so the table compares integers.
            var numbers: [String: Int32] = [:]
            func number(_ line: String) -> Int32 {
                if let k = numbers[line] { return k }
                let k = Int32(numbers.count)
                numbers[line] = k
                return k
            }
            let a = old[head..<(head + rows)].map(number), b = new[head..<(head + cols)].map(number)
            let width = cols + 1
            var lcs = [Int32](repeating: 0, count: (rows + 1) * width)
            for i in stride(from: rows - 1, through: 0, by: -1) {
                for j in stride(from: cols - 1, through: 0, by: -1) {
                    lcs[i * width + j] = a[i] == b[j] ? lcs[(i + 1) * width + j + 1] + 1 : max(lcs[(i + 1) * width + j], lcs[i * width + j + 1])
                }
            }
            var i = 0, j = 0
            while i < rows, j < cols {
                if a[i] == b[j] {
                    anchors.append((head + i, head + j)); i += 1; j += 1
                } else if lcs[(i + 1) * width + j] >= lcs[i * width + j + 1] { i += 1 } else { j += 1 }
            }
        }
        anchors += (0..<tail).map { (n - tail + $0, m - tail + $0) }
        var fates = Array(repeating: LineFate.removed, count: n)
        var added: [Int] = []
        var (a, c) = (0, 0)
        for (b, d) in anchors + [(n, m)] {
            let paired = min(b - a, d - c)
            for t in 0..<paired { fates[a + t] = .changed(c + t) }
            added += Array((c + paired)..<d)
            if b < n { fates[b] = .same(d) }
            (a, c) = (b + 1, d + 1)
        }
        return (fates, added)
    }

    /// The text of an earlier event, read again from the capture folder; nil when it is gone or unreadable.
    func storedText(_ id: String, paths: [String: String]) -> String? {
        guard let parts = paths[id]?.split(separator: "/").map(String.init), parts.count == 2,
              case .ok(let data) = SafeFile.read(root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])) else { return nil }
        return (try? JSONParser.parse(data).value)?["text"]?.stringValue
    }

    /// Change cards for a corrected note whose earlier version was already filed (capture-event-v0 §3.2, §6.5).
    /// Each filed item is matched to its own source line: by its title when that is exactly one line of the current
    /// text, else by the span it carries, and followed line by line through the current text to the new one (each
    /// step a line diff): an item whose line changed
    /// gets the new line as its title when its title is still that line's words (a clerk's title is its own words and
    /// stays), an item whose line is gone is offered to drop, and an item whose line cannot be identified is left
    /// alone. New lines, and lines whose waiting card this correction withdrew, are proposed once: in the binder of
    /// the item filed from the nearest line, else unfiled. A private correction redacts every item it touches.
    /// Returns (binder or nil for unfiled, card id) for each card saved; nil when nothing was filed from the chain.
    /// Throws when a card cannot be saved or trusted; the cards already made are found again on the retry.
    func correctionCards(_ event: CaptureEvent, chain: [String], current: String, withdrawn: [(URL?, Proposal)], paths: [String: String],
                         binders: [ShelfRow], commands: Commands, now: Date) throws -> [(URL?, String)]? {
        let ids = Set(chain)
        let newLines = Self.lines(of: event.text)
        typealias Lines = [(text: String, start: Int, end: Int)]
        var linesCache: [String: Lines?] = [:]
        var toCurrent: [String: [LineFate]?] = [:]
        func lines(_ id: String) -> Lines? {
            if let cached = linesCache[id] { return cached }
            let found = storedText(id, paths: paths).map(Self.lines(of:))
            linesCache[id] = .some(found)
            return found
        }
        /// The line of `id`'s text that holds offset `start`.
        func line(of start: Int, in id: String) -> Int? {
            lines(id)?.firstIndex { $0.start <= start && start < $0.end }
        }
        // Lines move from the event an item came from to the current text, then from the current text to the new one.
        let currentLines = lines(current)
        let step = currentLines.map { Self.diffLines($0.map(\.text), newLines.map(\.text)) }
        /// The current text's line for line `k` of event `id`'s text; nil when an earlier correction removed it.
        func inCurrent(_ id: String, _ k: Int) -> Int? {
            if id == current { return k }
            if toCurrent[id] == nil {
                toCurrent[id] = .some(lines(id).flatMap { old in currentLines.map { Self.diffLines(old.map(\.text), $0.map(\.text)).fates } })
            }
            guard let fates = toCurrent[id] ?? nil, k < fates.count else { return nil }
            switch fates[k] {
            case .same(let c), .changed(let c): return c
            case .removed: return nil
            }
        }

        let rows = binders.filter { $0.teka.isAdopted && Owner.device(of: $0.folder) == commands.deviceID }
        let filed = rows.map { row in
            (row.folder, row.teka.items.compactMap(\.object).filter { o in
                (o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []).contains(where: ids.contains)
            })
        }.filter { !$0.1.isEmpty }
        guard !filed.isEmpty else { return nil }

        let closedAt = JSONValue.string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))
        var ops: [URL: [JSONObject]] = [:]
        var placedAt: [Int: URL] = [:]   // new line -> a binder holding an item filed from it
        for (folder, items) in filed {
            for o in items {
                guard let itemID = o["id"] else { continue }
                let title = o["title"]?.stringValue ?? ""
                // The item's own line: its title in the current text, else its span in the text it came from.
                var source: (event: String, line: Int)?
                let matches = (currentLines ?? []).indices.filter { String(currentLines![$0].text.prefix(200)) == title }
                if matches.count == 1 {
                    source = (current, matches[0])
                } else if let start = o["provenance"]?["span"]?["start"]?.numberValue?.safeInteger,
                          let from = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue).first(where: ids.contains),
                          let k = line(of: Int(start), in: from) {
                    source = (from, k)
                }
                var set = JSONObject()
                var drop = false
                if let source, let c = inCurrent(source.event, source.line), let fates = step?.fates, c < fates.count {
                    switch fates[c] {
                    case .same(let j):
                        placedAt[j] = placedAt[j] ?? folder
                    case .changed(let j):
                        placedAt[j] = placedAt[j] ?? folder
                        // Only words that are still the line's own are rewritten.
                        let newTitle = String(newLines[j].text.prefix(200))
                        let own = [lines(source.event)?[source.line].text, currentLines?[c].text].compactMap { $0.map { String($0.prefix(200)) } }
                        if own.contains(title), newTitle != title { set.set("title", .string(newTitle)) }
                    case .removed:
                        drop = true
                    }
                }
                if drop {
                    // A private correction closes nothing in the clear: the closure keeps the item's title, and the hub
                    // shows it once more, so the redaction goes first in the same batch (capture-event-v0 §3.3).
                    if event.isPrivate, o["redact"] != .bool(true) {
                        var redact = JSONObject([(key: "redact", value: .bool(true))])
                        if o["kind"] == nil { redact.set("kind", .str("other")) }
                        ops[folder, default: []].append(JSONObject([(key: "op", value: .str("update_item")),
                                                                   (key: "args", value: .obj([("id", itemID), ("set", .object(redact))]))]))
                    }
                    ops[folder, default: []].append(JSONObject([(key: "op", value: .str("drop")), (key: "args", value: .obj([
                        ("id", itemID), ("closed_at", closedAt), ("source", .str("capture"))]))]))
                    continue
                }
                // A private correction's words are redacted as they land, and so is what it leaves in place (§3.3).
                if event.isPrivate, o["redact"] != .bool(true) {
                    set.set("redact", .bool(true))
                    if o["kind"] == nil { set.set("kind", .str("other")) }
                }
                guard !set.entries.isEmpty else { continue }
                ops[folder, default: []].append(JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(set))]))]))
            }
        }

        // Lines to propose: new ones, and those whose waiting card was withdrawn above, each once.
        var propose: [Int: URL?] = [:]
        for (folder, p) in withdrawn {
            for op in p.ops where op["op"] == .str("add_item") {
                guard let span = op["spans"]?.arrayValue?.first, let from = span["event"]?.stringValue, ids.contains(from),
                      let start = span["start"]?.numberValue?.safeInteger, let k = line(of: Int(start), in: from),
                      let c = inCurrent(from, k), let fates = step?.fates, c < fates.count else { continue }
                switch fates[c] {
                case .same(let j), .changed(let j):
                    // Back where it waited when that binder is this Mac's, else unfiled.
                    let back = folder.flatMap { f in rows.contains { $0.folder == f } ? f : nil }
                    if placedAt[j] == nil, propose[j] == nil { propose[j] = .some(back) }
                case .removed: break
                }
            }
        }
        for j in step?.added ?? [] where propose[j] == nil {
            let before = placedAt.keys.filter { $0 < j }.max(), after = placedAt.keys.filter { $0 > j }.min()
            propose[j] = .some(before.flatMap { placedAt[$0] } ?? after.flatMap { placedAt[$0] })
        }
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
        var adds: [URL?: [JSONObject]] = [:]
        for j in propose.keys.sorted().prefix(10) {
            let target = propose[j]!
            var item = JSONObject()
            item.set("id", .string("$new:\((adds[target]?.count ?? 0) + 1)"))
            item.set("title", .string(String(newLines[j].text.prefix(200))))
            item.set("status", .str("open"))
            item.set("priority", .str("normal"))
            item.set("no_deadline", .bool(true))
            if event.isPrivate {
                item.set("redact", .bool(true))
                item.set("kind", .str("other"))
            }
            item.set("provenance", .obj([("events", .array([.string(event.id)])), ("proposed_by", .object(actor)),
                                         ("span", .obj([("start", .int(newLines[j].start)), ("end", .int(newLines[j].end))]))]))
            let span = JSONValue.obj([("event", .string(event.id)), ("start", .int(newLines[j].start)), ("end", .int(newLines[j].end))])
            adds[target, default: []].append(JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))])),
                                                         (key: "spans", value: .array([span]))]))
        }

        var provenance = JSONObject([(key: "events", value: .array([.string(event.id)])), (key: "supersedes", value: .array(chain.map(JSONValue.string))),
                                     (key: "filed_by", value: .str("code, no model"))])
        if event.isPrivate { provenance.set("private", .bool(true)) }
        var made: [(URL?, String)] = []
        for folder in rows.map(\.folder) where ops[folder] != nil || adds[folder] != nil {
            let cardOps = (ops[folder] ?? []) + (adds[folder] ?? [])
            guard !cardOps.isEmpty else { continue }
            // A retry after a partial failure keeps the card this correction already made here, never a second one.
            if let kept = madeCorrection(event.id, in: folder, commands: commands) {
                made.append((folder, kept))
                continue
            }
            let card = Proposal.make(title: "A note was corrected. Change what was filed from it?", actor: actor, ops: cardOps,
                                     provenance: provenance, now: now)
            try ProposalStore.save(card, in: folder)
            do {
                try commands.trustProposals([card.id], in: folder)
            } catch {
                // A card whose digest was not kept could never be approved: it goes, and the correction is tried again.
                let written = ProposalStore.dir(folder).appendingPathComponent("\(card.id).json")
                if (try? FileManager.default.removeItem(at: written)) == nil {
                    try? TekaStore(folder: folder).reject(card, reason: "its digest could not be kept", now: now)
                }
                throw error
            }
            made.append((folder, card.id))
        }
        if let unfiledOps = adds[nil] {
            if let kept = unfiled().first(where: { Self.isCorrection($0, of: event.id) }) {
                made.append((nil, kept.id))
            } else {
                let noun = event.raw["source"]?["kind"]?.stringValue == "dictation" ? "dictation" : "note"
                var card = Proposal.make(title: "Corrected \(noun): add \(unfiledOps.count == 1 ? "a new line" : "\(unfiledOps.count) new lines")",
                                         actor: actor, ops: unfiledOps, provenance: provenance, now: now).raw
                card.set("binder", .str("not sure"))
                try writeUnfiled(card)
                made.append((nil, card["id"]?.stringValue ?? ""))
            }
        }
        return made
    }

    /// A correction card of `event`: its only event, and it names what it supersedes.
    package static func isCorrection(_ p: Proposal, of event: String) -> Bool {
        p.raw["provenance"]?["events"] == .array([.string(event)]) && p.raw["provenance"]?["supersedes"] != nil
    }

    /// The correction card `event` already has in `folder`: one waiting as Sprava wrote it, or one the person
    /// approved; nil when there is none.
    func madeCorrection(_ event: String, in folder: URL, commands: Commands) -> String? {
        ProposalStore.list(in: folder).map(\.0).first { p in
            Self.isCorrection(p, of: event) && (p.state == "applied" || (p.state == "proposed" && commands.isTrusted(p.id, in: folder)))
        }?.id
    }

    /// Withdraws what still waits from a chain, and ends the clerk's work on it. A card that only redacts stays: a
    /// raise to private holds whatever comes after it. Returns false when a card could not be withdrawn.
    @discardableResult
    func withdraw(chain: [String], reason: String, state: inout State, binders: [ShelfRow], deviceID: String, now: Date) -> Bool {
        var complete = true
        for (folder, p) in withdrawable(chain: chain, binders: binders, deviceID: deviceID) {
            if let folder {
                if (try? TekaStore(folder: folder).reject(p, reason: reason, now: now)) == nil { complete = false }
            } else if let file = unfiledFile(p.id), (try? FileManager.default.removeItem(at: file)) == nil,
                      FileManager.default.fileExists(atPath: file.path) {
                complete = false
            }
        }
        var clerk = state.clerk ?? [:]
        for id in chain where clerk[id] != nil { clerk[id] = "superseded" }
        state.clerk = clerk
        return complete
    }

    /// The cards `withdraw` would take from a chain, without touching them: every unfiled one, and each one waiting
    /// in a binder unless it only redacts.
    func withdrawable(chain: [String], binders: [ShelfRow], deviceID: String) -> [(URL?, Proposal)] {
        let (unfiled, filed) = pendingCards(chain: chain, binders: binders, deviceID: deviceID)
        func onlyRedacts(_ p: Proposal) -> Bool {
            !p.ops.isEmpty && p.ops.allSatisfy { $0["op"] == .str("update_item") && $0["args"]?["set"]?["redact"] == .bool(true) }
        }
        return unfiled.map { (nil, $0) } + filed.filter { !onlyRedacts($0.1) }.map { ($0.0, $0.1) }
    }

    /// A retraction (capture-event-v0 §3.2): what waits is withdrawn, Sprava's own copies are forgotten, and items
    /// already filed get a card that offers to drop them. Returns false when any of it could not be done; run again,
    /// it does only what is left, and never makes a second card.
    func retract(chain: [String], retraction: String, state: inout State, binders: [ShelfRow], commands: Commands, now: Date) -> Bool {
        var complete = withdraw(chain: chain, reason: "the note was deleted where it was taken", state: &state, binders: binders,
                                deviceID: commands.deviceID, now: now)
        var clerk = state.clerk ?? [:]
        for id in chain {
            clerk[id] = "retracted"
            let interpretation = dir.appendingPathComponent("interpretations/\(id).json")
            if (try? FileManager.default.removeItem(at: interpretation)) == nil, FileManager.default.fileExists(atPath: interpretation.path) {
                complete = false
            }
        }
        state.clerk = clerk
        let ids = Set(chain)
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let filed = row.teka.items.compactMap { item -> JSONObject? in
                guard let o = item.object, let events = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue),
                      events.contains(where: ids.contains), let itemID = o["id"] else { return nil }
                return JSONObject([(key: "op", value: .str("drop")), (key: "args", value: .obj([
                    ("id", itemID), ("closed_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))), ("source", .str("capture"))]))])
            }
            guard !filed.isEmpty else { continue }
            // A card this retraction already made, waiting or acted on, is kept; a leftover that was never trusted
            // could not be approved, so it goes and the card is made again.
            let leftover = "its digest could not be kept"
            var made = false
            for (p, _) in ProposalStore.list(in: row.folder) where p.raw["provenance"]?["retraction"] == .string(retraction) {
                if p.state == "proposed", !commands.isTrusted(p.id, in: row.folder) {
                    if (try? TekaStore(folder: row.folder).reject(p, reason: leftover, now: now)) == nil { complete = false }
                } else if p.raw["rejected_reason"] != .string(leftover) {
                    made = true
                }
            }
            guard !made else { continue }
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
            let card = Proposal.make(title: "A note was deleted where it was taken. Remove what was filed from it?", actor: actor, ops: filed,
                                     provenance: JSONObject([(key: "events", value: .array(chain.map(JSONValue.string))),
                                                             (key: "retraction", value: .string(retraction)),
                                                             (key: "remains", value: .str("the event files in the capture folder, the titles in this binder's history, and backups"))]),
                                     now: now)
            do {
                try ProposalStore.save(card, in: row.folder)
            } catch {
                complete = false
                continue
            }
            if (try? commands.trustProposals([card.id], in: row.folder)) == nil {
                let written = ProposalStore.dir(row.folder).appendingPathComponent("\(card.id).json")
                if (try? FileManager.default.removeItem(at: written)) == nil {
                    try? TekaStore(folder: row.folder).reject(card, reason: leftover, now: now)
                }
                complete = false
            }
        }
        return complete
    }

    /// Applies a raise to private for event `id`; one that could not be written is kept in the cursor and tried
    /// again by every sweep until it is, so an unredacted card never stays approvable.
    func raise(_ chain: [String], for id: String, state: inout State, binders: [ShelfRow], commands: Commands, now: Date) {
        // From now on the chain is private: for cards made later, and for the clerk's reading already under way.
        markPrivate(chain + [id], state: &state)
        try? save(state)
        guard !raisePrivacy(chain: chain, binders: binders, commands: commands, now: now) else { return }
        state.raises = (state.raises ?? [:]).merging([id: chain]) { $1 }
        journal([("event", .string(id)), ("stage", .str("privacy_raise_failed"))])
    }

    /// Records events as private in the cursor; nothing ever takes one out (capture-event-v0 §3.3).
    func markPrivate(_ ids: [String], state: inout State) {
        let known = Set(state.privates ?? [])
        guard !known.isSuperset(of: ids) else { return }
        state.privates = known.union(ids).sorted()
    }

    /// The event as its cards file it: private when it is, or when it or its chain was raised to private before;
    /// sensitivity never goes down (capture-event-v0 §3.3).
    static func asFiled(_ event: CaptureEvent, privates: Set<String>, chain: [String] = []) -> CaptureEvent {
        guard !event.isPrivate, privates.contains(event.id) || chain.contains(where: privates.contains) else { return event }
        var raw = event.raw
        raw.set("sensitivity", .str("private"))
        return CaptureEvent(raw: raw, url: event.url, digest: event.digest)
    }

    /// A raise to private (capture-event-v0 §3.2, §3.3): waiting cards from the chain become private and redacted
    /// at once; cards in binders are rewritten by Sprava and trusted again. Returns false when any rewrite or
    /// redaction card could not be saved.
    package func raisePrivacy(chain: [String], binders: [ShelfRow], commands: Commands, now: Date) -> Bool {
        var complete = true
        let (unfiled, filed) = pendingCards(chain: chain, binders: binders, deviceID: commands.deviceID)
        for p in unfiled where p.raw["provenance"]?["private"] != .bool(true) {
            if (try? writeUnfiled(Self.privateCopy(p, catalog: nil).raw)) == nil { complete = false }
        }
        // Only a card still as Sprava wrote it is rewritten and trusted again; one another program changed stays
        // unverified, so it can never be approved, and covers nothing below.
        var changed = Set<String>()
        for (folder, p) in filed where p.raw["provenance"]?["private"] != .bool(true) {
            // A rewritten card that cannot be trusted again is not approvable, so the raise is retried.
            do { try commands.rewriteTrusted(p.id, in: folder) { Self.privateCopy($0, catalog: Teka.read(folder).catalog) } }
            catch is ProposalStore.Tampered { changed.insert(p.id) }
            catch { complete = false }
        }
        if !changed.isEmpty { journal([("stage", .str("card_changed_outside")), ("cards", .int(changed.count))]) }
        // Items already filed from the chain get a card that redacts them (capture-event-v0 §3.2, §3.3), unless a
        // card waiting from the chain already does (a retry after a partial failure).
        let ids = Set(chain)
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let waiting = filed.filter { folder, p in
                folder.standardizedFileURL == row.folder.standardizedFileURL && commands.isTrusted(p.id, in: folder)
            }.map { _, p in
                p.raw["provenance"]?["private"] == .bool(true) ? p : Self.privateCopy(p, catalog: row.teka.catalog)
            }
            let covered = Set(waiting.flatMap(\.ops).compactMap { op -> String? in
                guard op["op"] == .str("update_item"), op["args"]?["set"]?["redact"] == .bool(true), let id = op["args"]?["id"] else { return nil }
                return canonicalText(id)
            })
            let ops = row.teka.items.compactMap { item -> JSONObject? in
                guard let o = item.object, o["redact"] != .bool(true), let itemID = o["id"], !covered.contains(canonicalText(itemID)),
                      let events = o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue), events.contains(where: ids.contains) else { return nil }
                var set = JSONObject([(key: "redact", value: .bool(true))])
                if o["kind"] == nil { set.set("kind", .str("other")) }
                return JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(set))]))])
            }
            guard !ops.isEmpty else { continue }
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
            let card = Proposal.make(title: "A note became private. Redact what was filed from it?", actor: actor, ops: ops,
                                     provenance: JSONObject([(key: "events", value: .array(chain.map(JSONValue.string))), (key: "private", value: .bool(true)),
                                                             (key: "remains", value: .str("titles already published to the hub until the next publish"))]),
                                     now: now)
            if (try? ProposalStore.save(card, in: row.folder)) != nil, (try? commands.trustProposals([card.id], in: row.folder)) != nil {} else { complete = false }
        }
        journal([("stage", .str("sensitivity_raised")), ("cards", .int(unfiled.count + filed.count))])
        return complete
    }

    /// A card made private (capture-event-v0 §3.3): every item it writes to is redacted in the same batch. A new
    /// item is redacted as it lands; an `update_item` sets `redact` with its other changes; a status change,
    /// completion or drop is preceded by an `update_item` that redacts the item, unless the card or the item
    /// already does. A redaction needs a kind, so an item without one gets `other`, as the clerk does for a
    /// private update; without the catalog (an unfiled card), the kind is left to the guard to ask for.
    static func privateCopy(_ p: Proposal, catalog: JSONObject?) -> Proposal {
        var raw = p.raw
        var prov = raw["provenance"]?.objectValue ?? JSONObject()
        prov.set("private", .bool(true))
        raw.set("provenance", .object(prov))
        let items = catalog?["open_items"]?.arrayValue ?? []
        func item(_ id: JSONValue) -> JSONValue? { items.first { $0["id"] == id } }
        func needsKind(_ id: JSONValue) -> Bool { catalog != nil && id.stringValue?.hasPrefix("$new:") != true && item(id)?["kind"] == nil }
        var redacted = Set<String>()   // items this card already redacts or adds, by the id's canonical text
        var ops: [JSONValue] = []
        for op in p.ops {
            guard var args = op["args"]?.objectValue else { ops.append(.object(op)); continue }
            var o = op
            switch op["op"]?.stringValue {
            case "add_item":
                guard var new = args["item"]?.objectValue else { break }
                new.set("redact", .bool(true))
                if new["kind"] == nil { new.set("kind", .str("other")) }
                if let id = new["id"] { redacted.insert(canonicalText(id)) }
                args.set("item", .object(new))
                o.set("args", .object(args))
            case "update_item":
                guard let id = args["id"] else { break }
                var set = args["set"]?.objectValue ?? JSONObject()
                set.set("redact", .bool(true))
                if set["kind"] == nil, needsKind(id) { set.set("kind", .str("other")) }
                args.set("set", .object(set))
                // Nothing this card writes takes the redaction or its kind away again.
                if let unset = args["unset"]?.arrayValue?.filter({ !["redact", "kind"].contains($0.stringValue ?? "") }) {
                    if unset.isEmpty { args.remove("unset") } else { args.set("unset", .array(unset)) }
                }
                o.set("args", .object(args))
                redacted.insert(canonicalText(id))
            case "set_status", "complete", "drop":
                guard let id = args["id"], !redacted.contains(canonicalText(id)), item(id)?["redact"] != .bool(true) else { break }
                var set = JSONObject([(key: "redact", value: .bool(true))])
                if needsKind(id) { set.set("kind", .str("other")) }
                ops.append(.obj([("op", .str("update_item")), ("args", .obj([("id", id), ("set", .object(set))]))]))
                redacted.insert(canonicalText(id))
            default:
                break
            }
            ops.append(.object(o))
        }
        raw.set("ops", .array(ops))
        return Proposal(raw: raw)
    }

    /// The words of the spans a card lists as not filed yet, read from the capture itself.
    public func notFiled(_ proposal: Proposal) -> [String] {
        guard let spans = proposal.raw["provenance"]?["unfiled"]?.arrayValue, !spans.isEmpty,
              let id = proposal.raw["provenance"]?["events"]?.arrayValue?.first?.stringValue,
              let text = storedText(id, paths: loadState().paths ?? [:]) else { return [] }
        let scalars = Array(text.unicodeScalars)
        return spans.compactMap { span in
            guard let a = span["start"]?.numberValue?.safeInteger, let b = span["end"]?.numberValue?.safeInteger,
                  a >= 0, a < b, Int(b) <= scalars.count else { return nil }
            var v = String.UnicodeScalarView()
            v.append(contentsOf: scalars[Int(a)..<Int(b)])
            return String(v)
        }
    }

    // MARK: - The clerk's queue (architecture 3.4, 5.3, 8)

    public struct ClerkWork: Sendable {
        public let event: CaptureEvent
        public let hint: String?
        package let tier0: String
        package let tier0Binder: String?
    }

    /// Picks the oldest capture waiting for the clerk whose code-built card is still untouched, and records the
    /// attempt before any model call (the poison rule: two unfinished attempts and the capture keeps its card).
    public func nextForClerk() -> ClerkWork? {
        guard var state = try? readState() else { return nil }
        var clerk = state.clerk ?? [:]
        var attempts = state.attempts ?? [:]
        defer {
            state.clerk = clerk
            state.attempts = attempts
            try? save(state)
        }
        for id in clerk.filter({ $0.value == "pending" || $0.value == "retry" }).keys.sorted() {
            guard let card = state.cards[id], let path = state.paths?[id] else { clerk[id] = "kept"; continue }
            let binder = state.cardBinder?[id]
            if !tier0Pending(card, binder: binder) { clerk[id] = "acted"; continue }
            if attempts[id, default: 0] >= 2 {
                let failed = clerk[id] == "retry"
                clerk[id] = failed ? "failed" : "poison"
                journal([("event", .string(id)), ("stage", .str("clerk_set_aside")),
                         ("reason", .str(failed ? "the clerk could not read this" : "crashed the clerk twice"))])
                continue
            }
            let parts = path.split(separator: "/").map(String.init)
            let device = root.appendingPathComponent(parts[0], isDirectory: true)
            guard parts.count == 2, case (.complete(.capture), let event?) = CaptureEvent.check(device.appendingPathComponent(parts[1]), deviceFolder: device)
            else { clerk[id] = "kept"; continue }
            attempts[id, default: 0] += 1
            // The attempt is on disk before any model call, or there is no call this run (the poison rule).
            state.clerk = clerk
            state.attempts = attempts
            guard (try? save(state)) != nil else { return nil }
            journal([("event", .string(id)), ("stage", .str("clerk_attempt")), ("n", .int(attempts[id]!))])
            return ClerkWork(event: Self.asFiled(event, privates: Set(state.privates ?? [])), hint: state.hints?[id], tier0: card, tier0Binder: binder)
        }
        return nil
    }

    func tier0Pending(_ card: String, binder: String?) -> Bool {
        if let binder {
            return ProposalStore.list(in: URL(fileURLWithPath: binder, isDirectory: true)).contains { $0.0.id == card && $0.0.state == "proposed" }
        }
        return unfiled().contains { $0.id == card }
    }

    public struct ClerkOutcome: Equatable, Sendable {
        public var items = 0
        public var filed = 0
        public var unsure = 0
        public var replaced = false
    }

    /// Stores the clerk's cards and withdraws the code-built one, unless the person acted on it meanwhile.
    public func commitClerk(_ work: ClerkWork, _ interp: Interpretation, filing: [FilingBinder], rows: [ShelfRow],
                            commands: Commands, seconds: Double, now: Date = Date()) -> ClerkOutcome {
        var outcome = ClerkOutcome()
        // A cursor that cannot be read is never saved over: nothing to do this time.
        guard var state = try? readState() else { return outcome }
        var clerk = state.clerk ?? [:]
        defer {
            state.clerk = clerk
            try? save(state)
        }
        let id = work.event.id
        guard ["pending", "retry"].contains(clerk[id] ?? ""), tier0Pending(work.tier0, binder: work.tier0Binder) else {
            if clerk[id] == "pending" || clerk[id] == "retry" { clerk[id] = "acted" }
            return outcome
        }
        func log(_ stage: String) {
            journal([("event", .string(id)), ("stage", .string(stage)), ("outcome", .string(interp.outcome)), ("items", .int(interp.items.count)),
                     ("filed", .int(outcome.filed)), ("not_sure", .int(outcome.unsure)), ("dropped", .int(interp.dropped)),
                     ("unfiled_spans", .int(interp.unfiled.count)), ("calls", .int(interp.calls)), ("ms", .int(Int(seconds * 1000)))])
        }
        // The interpretation the cards will name is on disk first (decisions.md C3); if it cannot be written, the
        // code-built card stays and the reading is tried again.
        do {
            try AtomicFile.makePrivateFolder(dir.appendingPathComponent("interpretations", isDirectory: true))
            try AtomicFile.write(Data(JSONWriter.pretty(.object(Self.record(interp))).utf8),
                                 to: dir.appendingPathComponent("interpretations/\(id).json"))
        } catch {
            clerk[id] = "retry"
            log("clerk_write_failed")
            return outcome
        }
        outcome.items = interp.items.count
        guard !interp.items.isEmpty else {
            // A model failure gets one more try under the background budget (architecture 3.4, 8); otherwise
            // the code-built card is the best there is.
            clerk[id] = interp.unfiled.contains(where: { ["invalid_output", "refused", "truncated"].contains($0.reason) }) ? "retry" : "kept"
            log("clerk")
            return outcome
        }
        // A raise to private that came while the clerk was reading holds for its cards too (capture-event-v0 §3.2).
        let event = Self.asFiled(work.event, privates: Set(state.privates ?? []))
        let today = Clerk.captureDay(event.raw["captured_at"]?.stringValue ?? "") ?? CalendarDate.today(now: now)
        let cards = Clerk.proposals(interp, event: event, today: today, client: commands.client, now: now)
        guard !cards.isEmpty else {
            // Everything the clerk read is already in the binder: the code-built card stays, saying so.
            clerk[id] = "kept"
            let already = interp.items.compactMap { $0.match?.relation == "same" ? $0.match?.candidate.title : nil }
            annotateTier0(work, already: already, commands: commands)
            log("clerk_already")
            return outcome
        }
        // A binder name resolves through the filing list (where a disclosure-none binder has only its label), else
        // to an adopted binder this Mac manages that is not at disclosure none, as the privacy ratchet reads it.
        let placed = cards.map { binder, proposal in
            (proposal, binder.flatMap { name in
                filing.first { $0.name == name }?.folder ?? rows.first {
                    $0.teka.isAdopted && $0.name == name && !$0.teka.writesBlocked && Owner.device(of: $0.folder) == commands.deviceID
                        && PrivacyRatchet.disclosure($0) != "none"
                }?.folder
            })
        }
        // The "not sure" cards are written first, then the binders'; when any save fails, the cards already saved
        // are taken back, so the clerk's cards never wait beside the code-built one, and the reading is not retried
        // into duplicates.
        var saved: [(URL?, String)] = []
        func takeBack() {
            for (folder, pid) in saved {
                if let folder, let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == pid }) {
                    try? TekaStore(folder: folder).reject(p, reason: "the clerk's cards could not all be saved", now: now)
                } else if folder == nil, let file = unfiledFile(pid) {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        for (proposal, folder) in placed.filter({ $0.1 == nil }) + placed.filter({ $0.1 != nil }) {
            if let folder, (try? ProposalStore.save(proposal, in: folder)) != nil {
                saved.append((folder, proposal.id))
                // A card counts as made only once it is trusted: an untrusted one could never be approved, so
                // everything saved is taken back and the code-built card stays; the reading is tried again.
                guard (try? commands.trustProposals([proposal.id], in: folder)) != nil else {
                    takeBack()
                    outcome = ClerkOutcome(items: outcome.items)
                    clerk[id] = (state.attempts?[id] ?? 0) >= 2 ? "kept" : "retry"
                    log("clerk_trust_failed")
                    return outcome
                }
                outcome.filed += proposal.ops.count
            } else {
                var raw = proposal.raw
                raw.set("binder", .str("not sure"))
                do { try writeUnfiled(raw) } catch {
                    takeBack()
                    outcome = ClerkOutcome(items: outcome.items)
                    clerk[id] = "kept"
                    log("clerk_write_failed")
                    return outcome   // the code-built card stays; nothing is lost
                }
                saved.append((nil, proposal.id))
                outcome.unsure += proposal.ops.count
            }
        }
        // The code-built card gives way to the clerk's reading.
        if let binder = work.tier0Binder {
            let folder = URL(fileURLWithPath: binder, isDirectory: true)
            if let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == work.tier0 }) {
                try? TekaStore(folder: folder).reject(p, reason: "replaced by the clerk's reading", now: now)
            }
        } else if let file = unfiledFile(work.tier0) {
            try? FileManager.default.removeItem(at: file)
        }
        outcome.replaced = true
        clerk[id] = "done"
        log("clerk")
        return outcome
    }

    /// Notes on the code-built card that the clerk found its items already in the binder.
    func annotateTier0(_ work: ClerkWork, already: [String], commands: Commands) {
        guard !already.isEmpty else { return }
        func annotated(_ p: Proposal) -> Proposal {
            var raw = p.raw
            var prov = raw["provenance"]?.objectValue ?? JSONObject()
            prov.set("already_in_binder", .array(already.map(JSONValue.string)))
            raw.set("provenance", .object(prov))
            return Proposal(raw: raw)
        }
        if let binder = work.tier0Binder {
            // A card another program changed since Sprava wrote it is left as it is, unverified (architecture 4.6).
            do { try commands.rewriteTrusted(work.tier0, in: URL(fileURLWithPath: binder, isDirectory: true), transform: annotated) }
            catch is ProposalStore.Tampered { journal([("event", .string(work.event.id)), ("stage", .str("card_changed_outside"))]) }
            catch {}
        } else if let p = unfiled().first(where: { $0.id == work.tier0 }) {
            try? writeUnfiled(annotated(p).raw)
        }
    }

    /// The interpretation as kept in Sprava's own capture store (decisions.md C3).
    public static func record(_ interp: Interpretation) -> JSONObject {
        var o = JSONObject()
        o.set("id", .string(interp.id))
        o.set("event", .string(interp.event))
        o.set("model", .string(interp.model))
        o.set("outcome", .string(interp.outcome))
        o.set("dropped_items", .int(interp.dropped))
        o.set("items", .array(interp.items.map { i in
            var item = JSONObject()
            item.set("title", .string(i.title))
            item.set("action", .string(i.action))
            item.set("source_span", .obj([("start", .int(i.sentence.start)), ("end", .int(i.sentence.end)), ("anchored", .bool(true))]))
            if let w = i.whenText { item.set("when_text", .string(w)) }
            if let r = i.whenRole { item.set("when_role", .string(r.rawValue)) }
            if let d = i.whenResolved { item.set("when_resolved", .string(d.description)) }
            item.set("people", .array(i.people.map(JSONValue.string)))
            if let a = i.amount { item.set("amount", .obj([("value", .number(JSONNumber(text: String(a.value)))), ("text", .string(i.amountText ?? ""))])) }
            item.set("binder_guess", .obj([("name", i.binder.map(JSONValue.string) ?? .null), ("signals", .array(i.signals.map(JSONValue.string))),
                                           ("confidence_band", .string(i.band))]))
            return .object(item)
        }))
        o.set("unfiled", .array(interp.unfiled.map { .obj([("start", .int($0.span.start)), ("end", .int($0.span.end)), ("reason", .string($0.reason))]) }))
        return o
    }

    // MARK: - Cards

    /// The Tier 0 card: one item per non-empty line of the capture (at most 10), undated (`no_deadline`), filed into
    /// the binder the person named when it is adopted, owned by this Mac and not at disclosure `none`, otherwise
    /// kept unfiled with the binder "not sure". Returns the card's id and, when filed, the binder folder.
    func card(for event: CaptureEvent, hint: String?, verified: Bool, producer: String, replaces: String?,
              binders: [ShelfRow], commands: Commands, now: Date) throws -> (String, URL?) {
        let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .str("none"))])
        let allLines = Self.lines(of: event.text)
        let lines = allLines.prefix(10)
        var ops: [JSONObject] = []
        for (i, line) in lines.enumerated() {
            var item = JSONObject()
            item.set("id", .string("$new:\(i + 1)"))
            item.set("title", .string(String(line.text.prefix(200))))
            item.set("status", .str("open"))
            item.set("priority", .str("normal"))
            item.set("no_deadline", .bool(true))
            if event.isPrivate {
                item.set("redact", .bool(true))
                item.set("kind", .str("other"))
            }
            // The item keeps its line's span, so a correction of the note finds the item's own line (§6.5).
            item.set("provenance", .obj([("events", .array([.string(event.id)])), ("proposed_by", .object(actor)),
                                         ("span", .obj([("start", .int(line.start)), ("end", .int(line.end))]))]))
            let span = JSONValue.obj([("event", .string(event.id)), ("start", .int(line.start)), ("end", .int(line.end))])
            ops.append(JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))])),
                                   (key: "spans", value: .array([span]))]))
        }
        var provenance = JSONObject([(key: "events", value: .array([.string(event.id)])), (key: "producer", value: .string(producer)),
                                     (key: "filed_by", value: .str("code, no model"))])
        if !verified { provenance.set("unverified_source", .bool(true)) }
        if let replaces { provenance.set("supersedes", .string(replaces)) }
        // Lines past the tenth are kept as parts not filed yet, in the note's own words (architecture 5.2).
        if allLines.count > 10 {
            provenance.set("unfiled", .array(allLines.dropFirst(10).map { .obj([("start", .int($0.start)), ("end", .int($0.end)), ("reason", .str("more_lines"))]) }))
        }
        if event.isPrivate { provenance.set("private", .bool(true)) }
        let noun = event.raw["source"]?["kind"]?.stringValue == "dictation" ? "dictation" : "note"
        var title = lines.count == 1 ? "Add from a \(noun)" : "Add \(lines.count) items from a \(noun)"
        if replaces != nil { title = "Corrected \(noun): " + title.prefix(1).lowercased() + title.dropFirst() }
        let proposal = Proposal.make(title: title, actor: actor, ops: ops, provenance: provenance, now: now)

        if let hint, let row = binders.first(where: { $0.teka.isAdopted && $0.teka.name == hint }),
           Owner.device(of: row.folder) == commands.deviceID,
           PrivacyRatchet.disclosure(row) != "none" {
            do {
                try ProposalStore.save(proposal, in: row.folder)
                try commands.trustProposals([proposal.id], in: row.folder)
                return (proposal.id, row.folder)
            } catch {
                journal([("event", .string(event.id)), ("stage", .str("file_failed")), ("code", .string("\(type(of: error))"))])
            }
        }
        var raw = proposal.raw
        raw.set("binder", .str("not sure"))
        try writeUnfiled(raw)
        return (proposal.id, nil)
    }

    package func writeUnfiled(_ raw: JSONObject) throws {
        guard let id = raw["id"]?.stringValue, let file = unfiledFile(id) else { throw Commands.Failure(message: "a card without a valid id") }
        try AtomicFile.makePrivateFolder(unfiledDir)
        let bytes = Data(JSONWriter.pretty(.object(raw)).utf8)
        let digest = Self.digest(bytes)
        // The digest is recorded first: a card whose file was written but not recorded would never be shown. A card
        // rewritten in place keeps the digest of the file still there beside the new one until the new file is
        // down, so a rewrite that fails, or a crash in between, never hides the card; the next rewrite tries again.
        var digests = try unfiledDigests()
        var both: String?
        if case .ok(let data) = SafeFile.read(file), case let current = Self.digest(data), current != digest,
           Self.accepted(digests[id]).contains(current) {
            both = digest + " " + current
        }
        digests[id] = both ?? digest
        try saveUnfiledDigests(digests)
        try AtomicFile.write(bytes, to: file)
        if both != nil {
            digests[id] = digest
            try? saveUnfiledDigests(digests)   // a pair left behind still names the file there
        }
    }

    /// The digests an entry of the digest list accepts: one, or two while a card is rewritten.
    static func accepted(_ entry: String?) -> [String] { entry?.split(separator: " ").map(String.init) ?? [] }

    /// Card id -> digest of the file the inbox wrote. Throws when the list exists but cannot be read, so it is
    /// never saved over with one entry.
    package func unfiledDigests() throws -> [String: String] {
        try StateFile.read([String: String].self, from: unfiledDigestsURL) ?? [:]
    }

    package func saveUnfiledDigests(_ digests: [String: String]) throws {
        try AtomicFile.makePrivateFolder(dir)
        try AtomicFile.write(try JSONEncoder().encode(digests), to: unfiledDigestsURL)
    }

    package static func digest(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Non-empty lines of a capture's text, trimmed, with half-open offsets in Unicode scalars
    /// (capture-event-v0 §3, spans).
    static func lines(of text: String) -> [(text: String, start: Int, end: Int)] {
        var out: [(String, Int, Int)] = []
        var current: [Unicode.Scalar] = []
        var start = 0
        func flush() {
            var lo = 0, hi = current.count
            while lo < hi, current[lo].properties.isWhitespace { lo += 1 }
            while hi > lo, current[hi - 1].properties.isWhitespace { hi -= 1 }
            if lo < hi {
                var s = String.UnicodeScalarView()
                s.append(contentsOf: current[lo..<hi])
                out.append((String(s), start + lo, start + hi))
            }
        }
        var index = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" || scalar == "\u{2028}" || scalar == "\u{2029}" || scalar == "\u{85}" {
                flush()
                current = []
                start = index + 1
            } else {
                current.append(scalar)
            }
            index += 1
        }
        flush()
        return out
    }

    // MARK: - Unfiled cards

    /// Unfiled cards waiting for the person to pick a binder. A card whose file changed since the inbox wrote it is
    /// left out, and so is one whose name is not `<id>.json` for the id inside it; none is shown while the digest
    /// list cannot be read (the sweep reports that).
    public func unfiled() -> [Proposal] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: unfiledDir.path),
              let digests = try? unfiledDigests() else { return [] }
        return names.filter { $0.hasSuffix(".json") && ProposalStore.isValidID(String($0.dropLast(5))) }.sorted().compactMap { name in
            let id = String(name.dropLast(5))
            guard case .ok(let data) = SafeFile.read(unfiledDir.appendingPathComponent(name)),
                  Self.accepted(digests[id]).contains(Self.digest(data)),
                  case .object(let o)? = try? JSONParser.parse(data).value, o["id"]?.stringValue == id else { return nil }
            return Proposal(raw: o)
        }
    }

    /// Moves an unfiled card into the binder the person picked, as a proposal there under the same id. The binder's
    /// copy is saved and trusted first; only then does the Inbox let go of the card, its digest and then its file.
    /// A crash in between leaves the card in both places, never in neither, and the next sweep drops the Inbox copy
    /// of a card already trusted in a binder (`dropFiled`). An Inbox card can only be filed, never approved, so the
    /// two copies are never both approvable.
    public func file(_ proposalID: String, into folder: URL, commands: Commands) throws {
        guard ProposalStore.isValidID(proposalID), var raw = unfiled().first(where: { $0.id == proposalID })?.raw else {
            throw Commands.Failure(message: "this card is gone or changed since Sprava wrote it")
        }
        let teka = Teka.read(folder)
        guard teka.isAdopted else { throw Commands.Failure(message: "this binder is not adopted yet") }
        guard Owner.device(of: folder) == commands.deviceID else { throw Commands.Failure(message: "this binder is read-only here") }
        // Filed before a crash: only the Inbox's copy is left to remove.
        if !commands.isTrusted(proposalID, in: folder) {
            // Filed into another binder before a crash: never a second approvable copy.
            if (try? commands.loadDigests())?.keys.contains(where: { $0.hasSuffix("#" + proposalID) }) == true {
                throw Commands.Failure(message: "this card was already filed into another binder; it leaves the Inbox shortly")
            }
            for key in ["binder", "source_retracted", "source_corrected"] { raw.remove(key) }
            try ProposalStore.save(Proposal(raw: raw), in: folder)
            do { try commands.trustProposals([proposalID], in: folder) } catch {
                // A copy saved but not trusted cannot be approved; it is taken back, and the Inbox keeps the card.
                if let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == proposalID }) {
                    try? TekaStore(folder: folder).reject(p, reason: "it could not be moved from the Inbox")
                }
                throw error
            }
        }
        // The card is in the binder now; a leftover the Inbox could not let go of is dropped by the next sweep.
        try? letGo(proposalID)
        journal([("card", .string(proposalID)), ("stage", .str("filed_by_person"))])
    }

    /// The Inbox lets go of a card: its digest first, so the leftover file is never shown, then the file.
    func letGo(_ id: String) throws {
        var digests = try unfiledDigests()
        if digests.removeValue(forKey: id) != nil { try saveUnfiledDigests(digests) }
        if let file = unfiledFile(id) { try? FileManager.default.removeItem(at: file) }
    }

    /// Drops from the Inbox every card already filed: a trusted proposal with its id waits in a binder this Mac
    /// manages. That is what a filing cut short by a crash leaves behind (`file`).
    func dropFiled(binders: [ShelfRow], commands: Commands) {
        let waiting = Set(unfiled().map(\.id))
        guard !waiting.isEmpty else { return }
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            for (p, _) in ProposalStore.list(in: row.folder) where waiting.contains(p.id) && commands.isTrusted(p.id, in: row.folder) {
                guard (try? letGo(p.id)) != nil else { continue }
                journal([("card", .string(p.id)), ("stage", .str("filed_by_person_finished"))])
            }
        }
    }

    public func discard(_ proposalID: String) throws {
        guard let file = unfiledFile(proposalID) else { throw Commands.Failure(message: "bad card id") }
        try FileManager.default.removeItem(at: file)
        journal([("card", .string(proposalID)), ("stage", .str("discarded"))])
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

import CryptoKit
import Foundation

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

    var dir: URL { support.appendingPathComponent("capture", isDirectory: true) }
    var journalURL: URL { dir.appendingPathComponent("journal.ndjson") }
    var stateURL: URL { dir.appendingPathComponent("state.json") }
    var noticesURL: URL { dir.appendingPathComponent("app-notices.ndjson") }
    var producersURL: URL { dir.appendingPathComponent("producers.json") }
    var quarantineDir: URL { dir.appendingPathComponent("quarantine", isDirectory: true) }
    var unfiledDigestsURL: URL { dir.appendingPathComponent("unfiled-digests.json") }
    public var unfiledDir: URL { support.appendingPathComponent("unfiled", isDirectory: true) }

    // MARK: - Producers and notices (architecture 8)

    /// Device folder name -> the `source.app` expected there.
    public func producers() -> [String: String] {
        (try? Data(contentsOf: producersURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    public func registerProducer(folder: String, app: String) throws {
        var p = producers()
        guard p[folder] != app else { return }
        p[folder] = app
        try AtomicFile.makePrivateFolder(dir)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try encoder.encode(p), to: producersURL)
    }

    /// Records that the app wrote this event, so its binder hint can be trusted.
    public func recordNotice(event: String, digest: String, now: Date = Date()) throws {
        guard CaptureEvent.isUUIDText(event), digest.hasPrefix("sha256:") else { throw Commands.Failure(message: "bad notice") }
        try AtomicFile.makePrivateFolder(dir)
        AtomicFile.appendLine(JSONWriter.compact(.obj([("at", .string(ISOTime.string(now))), ("event", .string(event)),
                                                       ("sha256", .string(digest))])), to: noticesURL)
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
    struct State: Codable {
        var ingested: [String: String] = [:]          // id -> stage
        var dedupe: [String: String] = [:]            // app|ref|revision -> id
        var apps: [String: String] = [:]              // id -> source.app, for supersede chains
        var cards: [String: String] = [:]             // id -> the proposal id of its card
        var paths: [String: String]? = [:]            // id -> device/name, for the clerk
        var cardBinder: [String: String]? = [:]       // id -> folder path of a filed Tier 0 card
        var hints: [String: String]? = [:]            // id -> the binder name a verified hint named
        var clerk: [String: String]? = [:]            // id -> pending, retry, done, kept, acted, poison, failed, retracted, superseded
        var attempts: [String: Int]? = [:]
        var chains: [String: [String]]? = [:]         // app|ref -> event ids, oldest first (capture-event-v0 §3.2)
        var texts: [String: String]? = [:]            // id -> SHA-256 of its text, to see a change that is not one
        var clocks: [String: String]? = [:]           // id -> its HLC as sortable text, to find a chain's current event
        var examined: [String: Examined] = [:]        // device/name -> last seen
        struct Examined: Codable, Equatable {
            var size: Int
            var mtime: Double
            var outcome: String
        }
    }

    func loadState() -> State {
        (try? Data(contentsOf: stateURL)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func save(_ s: State) throws {
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
    }

    // MARK: - Sweep

    /// One pass: list every device folder, diff against the cursor, ingest what is complete.
    public func sweep(binders: [ShelfRow], commands: Commands, now: Date = Date()) -> SweepResult {
        var result = SweepResult()
        guard SafeFile.isTrustedFolder(root) else {
            if FileManager.default.fileExists(atPath: root.path) { result.refusedFolders += 1 }
            return result
        }
        var state = loadState()
        let producers = producers()
        let notices = notices()
        let fm = FileManager.default
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
                // An id still at "ingested" crashed before its card was made: it is picked up again here.
                if let stage = state.ingested[stem], stage != "ingested" { continue }
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
                    journal([("event", .string(stem)), ("stage", .str("newer_format"))])
                case .quarantined(let why):
                    result.quarantined += 1
                    state.examined[key] = .init(size: size, mtime: mtime, outcome: "quarantined")
                    quarantine(file, device: deviceName, reason: why)
                    journal([("event", .string(stem)), ("stage", .str("quarantined")), ("reason", .string(why))])
                case .complete(.derived):
                    state.ingested[stem] = "derived"
                case .complete(.capture):
                    guard let event else { continue }
                    ingest(event, device: deviceName, producer: producers[deviceName], notice: notices[stem], size: size,
                           state: &state, result: &result, binders: binders, commands: commands, now: now)
                    state.paths = (state.paths ?? [:]).merging([stem: key]) { $1 }
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

        if state.ingested[id] == nil {
            if let earlier = state.dedupe[event.dedupeKey] {
                // The same capture again: only a raise of sensitivity is applied (capture-event-v0 §3.2).
                result.duplicates += 1
                state.ingested[id] = "duplicate"
                if registered, event.isPrivate { raisePrivacy(chain: [earlier] + chain, binders: binders, commands: commands, now: now) }
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

        // The current event of a chain is the one with the highest HLC (capture-event-v0 §3.2): a revision that
        // arrives late but is older than what the chain already has changes nothing.
        let clocks = state.clocks ?? [:]
        let current = chain.max { (clocks[$0] ?? "") < (clocks[$1] ?? "") }
        if let current, (clocks[current] ?? "") > Self.clockKey(event) {
            state.ingested[id] = "stale_revision"
            journal([("event", .string(id)), ("stage", .str("stale_revision"))])
            return
        }
        if event.retracted {
            if !chain.isEmpty { retract(chain: chain, retraction: id, state: &state, binders: binders, commands: commands, now: now) }
            state.ingested[id] = "retracted"
            journal([("event", .string(id)), ("stage", .str("retracted"))])
            return
        }
        if event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            state.ingested[id] = "nothing_to_file"
            return
        }
        // A later event of the chain: the same text changes only sensitivity; other text replaces what still waits.
        var replaces: String?
        if let earlier = current {
            if event.isPrivate { raisePrivacy(chain: chain, binders: binders, commands: commands, now: now) }
            if state.texts?[earlier] == textHash {
                state.ingested[id] = "same_text"
                journal([("event", .string(id)), ("stage", .str("same_text"))])
                return
            }
            replaces = earlier
            withdraw(chain: chain, reason: "replaced by a corrected note", state: &state, binders: binders, now: now)
            // Items already filed from the earlier version get a change card, never new items beside them (§6.5).
            if let made = correctionCards(event, chain: chain, binders: binders, commands: commands, now: now), !made.isEmpty {
                state.cards[id] = made[0].1
                state.cardBinder = (state.cardBinder ?? [:]).merging([id: made[0].0.path]) { $1 }
                state.clerk = (state.clerk ?? [:]).merging([id: "kept"]) { $1 }   // the clerk would add them again
                state.ingested[id] = "proposed"
                result.filed += 1
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
            made = try card(for: event, hint: hint, verified: verified, producer: producer ?? event.app,
                            replaces: replaces, binders: binders, commands: commands, now: now)
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

    /// Pending cards built from any event of a chain: unfiled ones, and proposals waiting in the binders.
    func pendingCards(chain: [String], binders: [ShelfRow]) -> (unfiled: [Proposal], filed: [(URL, Proposal)]) {
        let ids = Set(chain)
        func fromChain(_ p: Proposal) -> Bool {
            !(p.raw["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []).filter(ids.contains).isEmpty
        }
        let unfiled = self.unfiled().filter(fromChain)
        var filed: [(URL, Proposal)] = []
        for row in binders where row.teka.isAdopted {
            for (p, _) in ProposalStore.list(in: row.folder) where p.state == "proposed" && fromChain(p) { filed.append((row.folder, p)) }
        }
        return (unfiled, filed)
    }

    /// Change cards for a corrected note whose earlier version was already filed: per binder, the note's lines map
    /// in order onto the items filed from the chain. A changed line updates the title, an extra line adds an item, and
    /// an item with no line left is offered to drop. Returns (binder, card id) for each card saved.
    func correctionCards(_ event: CaptureEvent, chain: [String], binders: [ShelfRow], commands: Commands, now: Date) -> [(URL, String)]? {
        let ids = Set(chain)
        let lines = Self.lines(of: event.text).prefix(10).map(\.text)
        var made: [(URL, String)] = []
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let filed = row.teka.items.compactMap { $0.object }.filter { o in
                (o["provenance"]?["events"]?.arrayValue?.compactMap(\.stringValue) ?? []).contains(where: ids.contains)
            }
            guard !filed.isEmpty else { continue }
            var ops: [JSONObject] = []
            for i in 0..<max(filed.count, lines.count) {
                if i < filed.count, i < lines.count {
                    guard let itemID = filed[i]["id"], filed[i]["title"]?.stringValue != lines[i] else { continue }
                    var set = JSONObject([(key: "title", value: .string(String(lines[i].prefix(200))))])
                    // A private correction's words are redacted as they land (capture-event-v0 §3.3).
                    if event.isPrivate {
                        set.set("redact", .bool(true))
                        if filed[i]["kind"] == nil { set.set("kind", .str("other")) }
                    }
                    ops.append(JSONObject([(key: "op", value: .str("update_item")), (key: "args", value: .obj([("id", itemID), ("set", .object(set))]))]))
                } else if i < lines.count {
                    var item = JSONObject()
                    item.set("id", .string("$new:\(i + 1)"))
                    item.set("title", .string(String(lines[i].prefix(200))))
                    item.set("status", .str("open"))
                    item.set("priority", .str("normal"))
                    item.set("no_deadline", .bool(true))
                    if event.isPrivate {
                        item.set("redact", .bool(true))
                        item.set("kind", .str("other"))
                    }
                    item.set("provenance", .obj([("events", .array([.string(event.id)]))]))
                    ops.append(JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: .obj([("item", .object(item))]))]))
                } else if let itemID = filed[i]["id"] {
                    ops.append(JSONObject([(key: "op", value: .str("drop")), (key: "args", value: .obj([
                        ("id", itemID), ("closed_at", .string(ISOTime.string(now, timeZone: TimeZone(identifier: "UTC")!))), ("source", .str("capture"))]))]))
                }
            }
            guard !ops.isEmpty else { continue }
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
            var provenance = JSONObject([(key: "events", value: .array([.string(event.id)])), (key: "supersedes", value: .array(chain.map(JSONValue.string))),
                                         (key: "filed_by", value: .str("code, no model"))])
            if event.isPrivate { provenance.set("private", .bool(true)) }
            let card = Proposal.make(title: "A note was corrected. Change what was filed from it?", actor: actor, ops: ops,
                                     provenance: provenance, now: now)
            if (try? ProposalStore.save(card, in: row.folder)) != nil {
                commands.trustProposals([card.id], in: row.folder)
                made.append((row.folder, card.id))
            }
        }
        return made
    }

    /// Withdraws what still waits from a chain, and ends the clerk's work on it.
    func withdraw(chain: [String], reason: String, state: inout State, binders: [ShelfRow], now: Date) {
        let (unfiled, filed) = pendingCards(chain: chain, binders: binders)
        for p in unfiled { try? FileManager.default.removeItem(at: unfiledDir.appendingPathComponent("\(p.id).json")) }
        for (folder, p) in filed { try? TekaStore(folder: folder).reject(p, reason: reason, now: now) }
        var clerk = state.clerk ?? [:]
        for id in chain where clerk[id] != nil { clerk[id] = "superseded" }
        state.clerk = clerk
    }

    /// A retraction (capture-event-v0 §3.2): what waits is withdrawn, Sprava's own copies are forgotten, and items
    /// already filed get a card that offers to drop them.
    func retract(chain: [String], retraction: String, state: inout State, binders: [ShelfRow], commands: Commands, now: Date) {
        withdraw(chain: chain, reason: "the note was deleted where it was taken", state: &state, binders: binders, now: now)
        var clerk = state.clerk ?? [:]
        for id in chain {
            clerk[id] = "retracted"
            try? FileManager.default.removeItem(at: dir.appendingPathComponent("interpretations/\(id).json"))
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
            let actor = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .string(commands.client)), (key: "model", value: .str("none"))])
            let card = Proposal.make(title: "A note was deleted where it was taken. Remove what was filed from it?", actor: actor, ops: filed,
                                     provenance: JSONObject([(key: "events", value: .array(chain.map(JSONValue.string))),
                                                             (key: "retraction", value: .string(retraction)),
                                                             (key: "remains", value: .str("the event files in the capture folder, the titles in this binder's history, and backups"))]),
                                     now: now)
            if (try? ProposalStore.save(card, in: row.folder)) != nil { commands.trustProposals([card.id], in: row.folder) }
        }
    }

    /// A raise to private (capture-event-v0 §3.2, §3.3): waiting cards from the chain become private and redacted
    /// at once; cards in binders are rewritten by Sprava and trusted again.
    func raisePrivacy(chain: [String], binders: [ShelfRow], commands: Commands, now: Date) {
        let (unfiled, filed) = pendingCards(chain: chain, binders: binders)
        func privateCopy(_ p: Proposal) -> Proposal {
            var raw = p.raw
            var prov = raw["provenance"]?.objectValue ?? JSONObject()
            prov.set("private", .bool(true))
            raw.set("provenance", .object(prov))
            raw.set("ops", .array(p.ops.map { op -> JSONValue in
                guard op["op"] == .str("add_item"), var args = op["args"]?.objectValue, var item = args["item"]?.objectValue else { return .object(op) }
                item.set("redact", .bool(true))
                if item["kind"] == nil { item.set("kind", .str("other")) }
                args.set("item", .object(item))
                var o = op
                o.set("args", .object(args))
                return .object(o)
            }))
            return Proposal(raw: raw)
        }
        for p in unfiled { try? writeUnfiled(privateCopy(p).raw) }
        for (folder, p) in filed where (try? ProposalStore.save(privateCopy(p), in: folder)) != nil {
            commands.trustProposals([p.id], in: folder)
        }
        // Items already filed from the chain get a card that redacts them (capture-event-v0 §3.2, §3.3).
        let ids = Set(chain)
        for row in binders where row.teka.isAdopted && Owner.device(of: row.folder) == commands.deviceID {
            let ops = row.teka.items.compactMap { item -> JSONObject? in
                guard let o = item.object, o["redact"] != .bool(true), let itemID = o["id"],
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
            if (try? ProposalStore.save(card, in: row.folder)) != nil { commands.trustProposals([card.id], in: row.folder) }
        }
        journal([("stage", .str("sensitivity_raised")), ("cards", .int(unfiled.count + filed.count))])
    }

    /// The words of the spans a card lists as not filed yet, read from the capture itself.
    public func notFiled(_ proposal: Proposal) -> [String] {
        guard let spans = proposal.raw["provenance"]?["unfiled"]?.arrayValue, !spans.isEmpty,
              let id = proposal.raw["provenance"]?["events"]?.arrayValue?.first?.stringValue,
              let path = loadState().paths?[id] else { return [] }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 2, case .ok(let data) = SafeFile.read(root.appendingPathComponent(parts[0]).appendingPathComponent(parts[1])),
              let text = (try? JSONParser.parse(data).value)?["text"]?.stringValue else { return [] }
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
        let tier0: String
        let tier0Binder: String?
    }

    /// Picks the oldest capture waiting for the clerk whose code-built card is still untouched, and records the
    /// attempt before any model call (the poison rule: two unfinished attempts and the capture keeps its card).
    public func nextForClerk() -> ClerkWork? {
        var state = loadState()
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
            journal([("event", .string(id)), ("stage", .str("clerk_attempt")), ("n", .int(attempts[id]!))])
            return ClerkWork(event: event, hint: state.hints?[id], tier0: card, tier0Binder: binder)
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
        var state = loadState()
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
        try? AtomicFile.makePrivateFolder(dir.appendingPathComponent("interpretations", isDirectory: true))
        try? AtomicFile.write(Data(JSONWriter.pretty(.object(Self.record(interp))).utf8),
                              to: dir.appendingPathComponent("interpretations/\(id).json"))
        outcome.items = interp.items.count
        func log(_ stage: String) {
            journal([("event", .string(id)), ("stage", .string(stage)), ("outcome", .string(interp.outcome)), ("items", .int(interp.items.count)),
                     ("filed", .int(outcome.filed)), ("not_sure", .int(outcome.unsure)), ("dropped", .int(interp.dropped)),
                     ("unfiled_spans", .int(interp.unfiled.count)), ("calls", .int(interp.calls)), ("ms", .int(Int(seconds * 1000)))])
        }
        guard !interp.items.isEmpty else {
            // A model failure gets one more try under the background budget (architecture 3.4, 8); otherwise
            // the code-built card is the best there is.
            clerk[id] = interp.unfiled.contains(where: { ["invalid_output", "refused", "truncated"].contains($0.reason) }) ? "retry" : "kept"
            log("clerk")
            return outcome
        }
        let today = Clerk.captureDay(work.event.raw["captured_at"]?.stringValue ?? "") ?? CalendarDate.today(now: now)
        let cards = Clerk.proposals(interp, event: work.event, today: today, client: commands.client, now: now)
        guard !cards.isEmpty else {
            // Everything the clerk read is already in the binder: the code-built card stays, saying so.
            clerk[id] = "kept"
            let already = interp.items.compactMap { $0.match?.relation == "same" ? $0.match?.candidate.title : nil }
            annotateTier0(work, already: already, commands: commands)
            log("clerk_already")
            return outcome
        }
        for (binder, proposal) in cards {
            let folder = binder.flatMap { name in
                filing.first { $0.name == name }?.folder ?? rows.first {
                    $0.teka.isAdopted && $0.name == name && !$0.teka.writesBlocked && Owner.device(of: $0.folder) == commands.deviceID
                }?.folder
            }
            if let folder, (try? ProposalStore.save(proposal, in: folder)) != nil {
                commands.trustProposals([proposal.id], in: folder)
                outcome.filed += proposal.ops.count
            } else {
                var raw = proposal.raw
                raw.set("binder", .str("not sure"))
                do { try writeUnfiled(raw) } catch {
                    log("clerk_write_failed")
                    return outcome   // the code-built card stays; nothing is lost
                }
                outcome.unsure += proposal.ops.count
            }
        }
        // The code-built card gives way to the clerk's reading.
        if let binder = work.tier0Binder {
            let folder = URL(fileURLWithPath: binder, isDirectory: true)
            if let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == work.tier0 }) {
                try? TekaStore(folder: folder).reject(p, reason: "replaced by the clerk's reading", now: now)
            }
        } else {
            try? FileManager.default.removeItem(at: unfiledDir.appendingPathComponent("\(work.tier0).json"))
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
            let folder = URL(fileURLWithPath: binder, isDirectory: true)
            if let (p, _) = ProposalStore.list(in: folder).first(where: { $0.0.id == work.tier0 }),
               (try? ProposalStore.save(annotated(p), in: folder)) != nil {
                commands.trustProposals([p.id], in: folder)
            }
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
            item.set("provenance", .obj([("events", .array([.string(event.id)])), ("proposed_by", .object(actor))]))
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
           row.teka.catalog?["meta"]?["disclosure"]?.stringValue != "none" {
            do {
                try ProposalStore.save(proposal, in: row.folder)
                commands.trustProposals([proposal.id], in: row.folder)
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

    func writeUnfiled(_ raw: JSONObject) throws {
        guard let id = raw["id"]?.stringValue else { throw Commands.Failure(message: "a card without an id") }
        try AtomicFile.makePrivateFolder(unfiledDir)
        let bytes = Data(JSONWriter.pretty(.object(raw)).utf8)
        // The digest is recorded first: a card whose file was written but not recorded would never be shown.
        var digests = unfiledDigests()
        digests[id] = Self.digest(bytes)
        try AtomicFile.write(try JSONEncoder().encode(digests), to: unfiledDigestsURL)
        try AtomicFile.write(bytes, to: unfiledDir.appendingPathComponent("\(id).json"))
    }


    func unfiledDigests() -> [String: String] {
        (try? Data(contentsOf: unfiledDigestsURL)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
    }

    static func digest(_ data: Data) -> String { "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

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
    /// left out.
    public func unfiled() -> [Proposal] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: unfiledDir.path) else { return [] }
        let digests = unfiledDigests()
        return names.filter { $0.hasSuffix(".json") && !$0.hasPrefix(".") }.sorted().compactMap { name in
            guard case .ok(let data) = SafeFile.read(unfiledDir.appendingPathComponent(name)),
                  digests[String(name.dropLast(5))] == Self.digest(data),
                  case .object(let o)? = try? JSONParser.parse(data).value else { return nil }
            return Proposal(raw: o)
        }
    }

    /// Moves an unfiled card into the binder the person picked, as a proposal there; the unfiled file is removed.
    public func file(_ proposalID: String, into folder: URL, commands: Commands) throws {
        guard var raw = unfiled().first(where: { $0.id == proposalID })?.raw else {
            throw Commands.Failure(message: "this card is gone or changed since Sprava wrote it")
        }
        let teka = Teka.read(folder)
        guard teka.isAdopted else { throw Commands.Failure(message: "this binder is not adopted yet") }
        guard Owner.device(of: folder) == commands.deviceID else { throw Commands.Failure(message: "this binder is read-only here") }
        for key in ["binder", "source_retracted", "source_corrected"] { raw.remove(key) }
        try ProposalStore.save(Proposal(raw: raw), in: folder)
        commands.trustProposals([proposalID], in: folder)
        try FileManager.default.removeItem(at: unfiledDir.appendingPathComponent("\(proposalID).json"))
        journal([("card", .string(proposalID)), ("stage", .str("filed_by_person"))])
    }

    public func discard(_ proposalID: String) throws {
        guard CaptureEvent.isUUIDText(proposalID) else { throw Commands.Failure(message: "bad card id") }
        try FileManager.default.removeItem(at: unfiledDir.appendingPathComponent("\(proposalID).json"))
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

import Darwin
import Foundation
import Testing
@testable import SpravaCore

/// Regressions from the review of increment 1's MCP server and runtime state files. Invented data only.
@Suite(.serialized) struct BugbotMCPTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    let meta = #""_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}"#

    struct Setup {
        let server: MCPServer
        let folders: [URL]
        let commands: Commands
        var folder: URL { folders[0] }
    }

    func adopted(mutate: ((inout [String: Any]) -> Void)? = nil) throws -> URL {
        let folder = try makeTeka(fixture: "sprava-v0")
        if let mutate {
            let url = folder.appendingPathComponent("catalog.json")
            var catalog = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            mutate(&catalog)
            try JSONSerialization.data(withJSONObject: catalog, options: [.prettyPrinted]).write(to: url)
        }
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        return folder
    }

    func setup(level: String = "propose", binders: Int = 1, documents: Bool = false, mutate: ((inout [String: Any]) -> Void)? = nil) throws -> Setup {
        let folders = try (0..<binders).map { _ in try adopted(mutate: mutate) }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-mcp-\(UUID().uuidString)")
        let commands = Commands(support: support, deviceID: "t")
        let client = MCPClientRecord(id: "claude-code-1", name: "Claude Code", tokenSHA256: "",
                                     binders: Dictionary(uniqueKeysWithValues: folders.map { ($0.standardizedFileURL.path, level) }),
                                     createdAt: "", revoked: false, documents: documents ? true : nil)
        let now = self.now
        let server = MCPServer(client: client, commands: commands, shelf: { Shelf.rows(registry: nil, picked: folders) }, now: { now })
        return Setup(server: server, folders: folders, commands: commands)
    }

    func tool(_ s: MCPServer, _ name: String, _ arguments: JSONValue) throws -> JSONValue {
        let line = JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", .int(1)), ("method", .str("tools/call")),
                                            ("params", .obj([("_meta", .obj([("io.modelcontextprotocol/protocolVersion", .str("2026-07-28"))])),
                                                             ("name", .string(name)), ("arguments", arguments)]))]))
        let reply = try #require(s.handle(line: line))
        return try #require(try JSONParser.parse(reply).value["result"])
    }

    func addItem(_ n: Int, title: String = "Call the notary") -> JSONValue {
        .obj([("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .string("$new:\(n)")), ("title", .string(title)), ("status", .str("open")),
                                                                     ("priority", .str("normal")), ("no_deadline", .bool(true))]))]))])
    }

    func propose(_ s: MCPServer, title: String = "Invented card", ops: [JSONValue], requestID: String? = nil) throws -> JSONValue {
        var fields: [(String, JSONValue)] = [("binder", .str("estate-example")), ("title", .string(title)), ("ops", .array(ops))]
        if let requestID { fields.append(("request_id", .string(requestID))) }
        return try tool(s, "propose_ops", .obj(fields))
    }

    func cards(_ c: Commands, _ folder: URL) throws -> [JSONValue] {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("proposals")), ("binder", .string(folder.path))])))).value["proposals"]?.arrayValue ?? []
    }

    // MARK: - p8-Q7: a name two binders share is refused

    @Test func aSharedBinderNameIsRefused() throws {
        let s = try setup(binders: 2)
        let r = try propose(s.server, ops: [addItem(1)])
        #expect(r["isError"] == .bool(true))
        #expect(r["structuredContent"]?["error"]?.stringValue?.contains("share this name") == true)
        for folder in s.folders { #expect(ProposalStore.list(in: folder).isEmpty) }
    }

    // MARK: - qBsse: a retry recovers a card whose digest was lost, but never trusts an edited file

    @Test func aRetryRecordsALostDigestOnlyForTheSameBatch() throws {
        let s = try setup()
        let first = try propose(s.server, ops: [addItem(1)], requestID: "r1")
        let pid = try #require(first["structuredContent"]?["proposal_id"]?.stringValue)
        try JSONWriter.compact(.obj([])).write(to: s.commands.digestsURL, atomically: true, encoding: .utf8)
        #expect(try cards(s.commands, s.folder).first { $0["id"] == .string(pid) }?["verified"] == .bool(false))
        #expect(try propose(s.server, ops: [addItem(1)], requestID: "r1")["isError"] == .bool(false))
        #expect(try cards(s.commands, s.folder).first { $0["id"] == .string(pid) }?["verified"] == .bool(true))

        // The same again, but the file was changed on disk before the retry: it stays unverified.
        let second = try propose(s.server, ops: [addItem(1, title: "Book the appraiser")], requestID: "r2")
        let pid2 = try #require(second["structuredContent"]?["proposal_id"]?.stringValue)
        try JSONWriter.compact(.obj([])).write(to: s.commands.digestsURL, atomically: true, encoding: .utf8)
        let file = s.folder.appendingPathComponent(".sprava/proposals/\(pid2).json")
        let text = try String(contentsOf: file, encoding: .utf8)
        try text.replacingOccurrences(of: "Book the appraiser", with: "Sell the house").write(to: file, atomically: true, encoding: .utf8)
        #expect(try propose(s.server, ops: [addItem(1, title: "Book the appraiser")], requestID: "r2")["isError"] == .bool(true))
        #expect(try cards(s.commands, s.folder).first { $0["id"] == .string(pid2) }?["verified"] == .bool(false))
    }

    // MARK: - qIe1K: a brain may propose filing a file from intake/

    @Test func aBrainProposesFilingAnIntakeFile() throws {
        let s = try setup()
        let intake = s.folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try Data("invented scan".utf8).write(to: intake.appendingPathComponent("scan.pdf"))
        let sha = try #require(DocumentPaths.sha256(of: intake.appendingPathComponent("scan.pdf")))
        func filing(from: String?) -> JSONValue {
            var args: [(String, JSONValue)] = [("document", .obj([("id", .str("$new:1")), ("title", .str("Invented scan")),
                                                                  ("path", .str("correspondence/notary/scan.pdf")), ("sha256", .string(sha))]))]
            if let from { args.append(("from", .string(from))) }
            return .obj([("op", .str("file_document")), ("args", .obj(args))])
        }
        #expect(try propose(s.server, ops: [filing(from: nil)])["isError"] == .bool(true))
        let r = try propose(s.server, ops: [filing(from: "intake/scan.pdf")])
        #expect(r["isError"] == .bool(false), "\(r)")
        let pid = try #require(r["structuredContent"]?["proposal_id"]?.stringValue)
        let card = try #require(try cards(s.commands, s.folder).first { $0["id"] == .string(pid) })
        #expect(card["verified"] == .bool(true))
        let approved = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([("command", .str("approve")), ("binder", .string(s.folder.path)),
                                                                                       ("proposal", .string(pid)), ("digest", card["digest"]!)])), now: now)).value
        #expect(approved["ok"] == .bool(true), "\(approved)")
        #expect(FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("correspondence/notary/scan.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: intake.appendingPathComponent("scan.pdf").path))
    }

    // MARK: - qJwVi: open counts leave out dismissed and closed items

    @Test func theOpenCountMatchesTheNowPage() throws {
        let s = try setup { catalog in
            var items = catalog["open_items"] as? [[String: Any]] ?? []
            if let i = items.firstIndex(where: { $0["id"] as? String == "estate-example-2026-010" }) { items[i]["status"] = "done" }
            catalog["open_items"] = items
        }
        let listed = try tool(s.server, "list_binders", .obj([]))
        // Six entries: one dismissed, one left at status done.
        #expect(Teka.read(s.folder).items.count == 6)
        #expect(listed["structuredContent"]?["binders"]?.arrayValue?.first?["open"] == .int(4))
    }

    // MARK: - qfZ26: text with invisible or direction-changing characters is refused

    @Test func invisibleCharactersInABrainsTextAreRefused() throws {
        let s = try setup()
        for bad in ["Pay \u{202E}gnirts", "Pay\u{200B}the bill", "Pay the bill\u{E0041}"] {
            #expect(try propose(s.server, ops: [addItem(1, title: bad)])["isError"] == .bool(true))
        }
        #expect(try propose(s.server, title: "Two\nlines", ops: [addItem(1)])["isError"] == .bool(true))
        #expect(ProposalStore.list(in: s.folder).isEmpty)
        #expect(try propose(s.server, title: "Réparer le toit", ops: [addItem(1, title: "Réparer le toit")])["isError"] == .bool(false))
    }

    // MARK: - qfZ3G: a read-only client cannot finish a reading

    @Test func aReadOnlyClientCannotFinishAReading() throws {
        let s = try setup(level: "read")
        let store = IntakeReadings(support: s.commands.support)
        var e = IntakeReadings.Entry(id: "reading-1", binder: s.folder.standardizedFileURL.path, name: "letter.pdf", sha256: String(repeating: "0", count: 64),
                                     card: "card-1", reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented letter.", channel: "other"), now: now)
        e.escalation = "waiting"
        store.save(e)
        let r = try tool(s.server, "finish_reading", .obj([("binder", .str("estate-example")), ("reading_id", .str("reading-1"))]))
        #expect(r["isError"] == .bool(true))
        #expect(store.load("reading-1")?.escalation == "waiting")
    }

    // MARK: - qgAPD: the batch limit the schema advertises is enforced

    @Test func atMostFiftyOpsPerProposal() throws {
        let s = try setup()
        #expect(try propose(s.server, ops: (1...51).map { addItem($0) })["isError"] == .bool(true))
        #expect(ProposalStore.list(in: s.folder).isEmpty)
        #expect(try propose(s.server, ops: (1...50).map { addItem($0) })["isError"] == .bool(false))
    }

    // MARK: - qIlEP: an unreadable client registry is never replaced

    @Test func anUnreadableClientRegistryIsLeftAsItIs() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-clients-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "t")
        let url = MCPClients.url(support)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let garbage = Data("{\"clients\": [ not json".utf8)
        try garbage.write(to: url)
        let r = try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("register_client")), ("client_id", .str("claude-code-2")),
                                                                         ("binders", .obj([("/Invented/estate-example", .str("read"))]))])))).value
        #expect(r["ok"] == .bool(false))
        #expect(try Data(contentsOf: url) == garbage)
        #expect(throws: MCPClients.Unreadable.self) { _ = try MCPClients.load(support) }
        // A missing registry is an empty one.
        try FileManager.default.removeItem(at: url)
        #expect(try MCPClients.load(support).clients.isEmpty)
    }

    // MARK: - qfZ4K: a change to a client's rights ends its open connection

    @Test func aChangedClientRecordClosesItsConnection() throws {
        let folder = try adopted()
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-sock-\(UUID().uuidString)")
        let c = Commands(support: support, deviceID: "t")
        func command(_ f: [(String, JSONValue)]) throws -> JSONValue { try JSONParser.parse(c.handle(JSONWriter.compact(.obj(f)))).value }
        let token = try #require(try command([("command", .str("register_client")), ("client_id", .str("claude-code-3")), ("documents", .bool(true)),
                                              ("binders", .obj([(folder.standardizedFileURL.path, .str("read"))]))])["token"]?.stringValue)
        let listener = MCPListener(support: support, commands: c, queue: DispatchQueue(label: "test.mcp"),
                                   shelf: { Shelf.rows(registry: nil, picked: [folder]) }, log: { _ in })
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let server = fds[1]
        Thread { listener.serve(server) }.start()
        let client = fds[0]
        defer { close(client) }
        setTimeout(client, seconds: 5)
        let reader = LineReader(fd: client)
        #expect(writeLine(client, JSONWriter.compact(.obj([("sprava_auth", .obj([("client_id", .str("claude-code-3")), ("token", .string(token))]))]))))
        guard case .line(let auth) = reader.next(limit: 4096) else { Issue.record("no reply to the preamble"); return }
        #expect(auth.contains("\"ok\":true"))
        let list = #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(meta)}}"#
        #expect(writeLine(client, list))
        guard case .line(let reply) = reader.next(limit: MCPListener.lineLimit) else { Issue.record("an unchanged client got no reply"); return }
        #expect(reply.contains("list_binders"))

        _ = try command([("command", .str("client_documents")), ("client_id", .str("claude-code-3")), ("documents", .bool(false))])
        #expect(writeLine(client, list))
        guard case .end = reader.next(limit: MCPListener.lineLimit) else { Issue.record("the connection stayed open"); return }
    }
}

@Suite(.serialized) struct BugbotRuntimeTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-bugbot-runtime-\(UUID().uuidString)")
        try AtomicFile.makePrivateFolder(dir)
        return dir
    }

    // MARK: - p8-Rb: jobs fail on a Shelf that cannot be read

    @Test func jobsSeeAnUnreadableShelf() throws {
        let support = try folder()
        let store = ShelfStore(supportDirectory: support)
        #expect(try store.rowsForJobs().isEmpty)
        try Data("{ not json".utf8).write(to: store.file)
        #expect(throws: ShelfStore.Unreadable.self) { _ = try store.rowsForJobs() }
    }

    // MARK: - qBssn: a job with nothing set up is not overdue

    @Test func idleRunsKeepAJobGreenAndSkippedRunsDoNot() {
        let spec = JobSpec(key: "hub", budget: .seconds(30), expectedCadence: 300, breakerThreshold: 3)
        let started = now
        var idle = JobRecord(), skipped = JobRecord()
        for i in 0...10 {
            let t = started.addingTimeInterval(Double(i) * 300)
            idle.start(at: t); idle.finish(.idle, at: t, durationMS: 1, threshold: 3)
            skipped.start(at: t); skipped.finish(.skipped, at: t, durationMS: 1, threshold: 3)
        }
        let at = started.addingTimeInterval(10 * 300 + 10)
        #expect(idle.lastSuccess == nil)
        #expect(HealthGrade.job(idle.heartbeatJob(spec: spec, now: at, wedged: false), startedAt: started, lastWake: nil, now: at) == .green)
        #expect(HealthGrade.job(skipped.heartbeatJob(spec: spec, now: at, wedged: false), startedAt: started, lastWake: nil, now: at) == .red)
        // The heartbeat still says "skipped", the schema's word.
        #expect(idle.heartbeatJob(spec: spec, now: at, wedged: false).last_outcome == "skipped")
    }

    // MARK: - qHLuK, qfZ21: one device id, never replaced

    @Test func concurrentFirstLoadsAgreeOnOneDeviceID() throws {
        let support = try folder()
        final class Box: @unchecked Sendable { let lock = NSLock(); var ids: [String] = [] }
        let box = Box()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let id = try? DeviceID.load(support: support)
            box.lock.lock(); box.ids.append(id ?? "failed"); box.lock.unlock()
        }
        #expect(Set(box.ids).count == 1)
        let stored = try String(contentsOf: support.appendingPathComponent("device-id"), encoding: .utf8)
        #expect(stored.trimmingCharacters(in: .whitespacesAndNewlines) == box.ids.first)
    }

    @Test func anUnreadableDeviceIDIsNeverReplaced() throws {
        let support = try folder()
        let url = support.appendingPathComponent("device-id")
        let bad = Data([0xFF, 0xFE, 0x00, 0x41])
        try bad.write(to: url)
        #expect(throws: DeviceID.Unreadable.self) { _ = try DeviceID.load(support: support) }
        #expect(try Data(contentsOf: url) == bad)
        // A folder where the id cannot be written: no id is made up.
        let locked = try folder()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { _ = try DeviceID.load(support: locked) }
    }

    // MARK: - qHLug: opaque binder ids are never reassigned over an unreadable file

    @Test func unreadableBinderIDsThrow() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("binder-ids.json")
        #expect(try BinderIDs.load(url).byPath.isEmpty)
        try Data("{\"byPath\": ".utf8).write(to: url)
        #expect(throws: BinderIDs.Unreadable.self) { _ = try BinderIDs.load(url) }
    }

    // MARK: - qIlEU: unreadable breakers are kept and every job starts half-open

    @Test func unreadableBreakersAreSetAsideAndHalfOpen() throws {
        let dir = try folder()
        let url = dir.appendingPathComponent("breakers.json")
        let bad = Data("{\"jobs\": {".utf8)
        try bad.write(to: url)
        let (records, aside) = JobRecords.loadAtStart(url, jobs: ["hub", "sentinel"], now: now)
        let kept = try #require(aside)
        #expect(try Data(contentsOf: kept) == bad)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(records.jobs["hub"]?.breaker == "half_open" && records.jobs["sentinel"]?.breaker == "half_open")

        // An older file without newer fields keeps its values.
        try Data(#"{"jobs": {"hub": {"breaker": "open", "breakerOpenedAt": "2026-10-01T10:00:00Z", "consecutiveFailures": 4}}}"#.utf8).write(to: url)
        let (old, none) = JobRecords.loadAtStart(url, jobs: ["hub"], now: now)
        #expect(none == nil)
        #expect(old.jobs["hub"]?.breaker == "open" && old.jobs["hub"]?.consecutiveFailures == 4)
    }

    // MARK: - qJwV5: a clock set back leaves no job waiting out the jump

    @Test func aClockChangeMakesEveryIntervalJobDue() {
        let later = now.addingTimeInterval(3 * 3600)
        var d = JobDeadlines(now: later)
        d.clockChanged(now: now)
        for date in [d.sentinel, d.alerts, d.hub, d.intake, d.dashboard] { #expect(date <= now) }
    }

    // MARK: - qJwV8: the summary never runs the sentinel past its open breaker

    @Test func theSummaryRespectsTheSentinelBreaker() {
        #expect(SummaryFallback.decide(reportFresh: true, sentinelBreaker: "open") == .useReport)
        #expect(SummaryFallback.decide(reportFresh: false, sentinelBreaker: "open") == .stale)
        #expect(SummaryFallback.decide(reportFresh: false, sentinelBreaker: "half_open") == .runSentinel)
        #expect(SummaryFallback.decide(reportFresh: false, sentinelBreaker: nil) == .runSentinel)
    }

    // MARK: - qgXOh: time asleep does not make a job wedged

    @Test func sleepDoesNotCountTowardsAWedge() {
        final class Clock: @unchecked Sendable { let lock = NSLock(); var awake: Duration = .zero }
        let clock = Clock()
        let box = WatchBox(budgets: ["backup": .seconds(3 * 3600)], awake: { clock.lock.lock(); defer { clock.lock.unlock() }; return clock.awake })
        box.started("backup")
        // A night asleep moves the wall clock, not this one.
        #expect(box.read().1 == nil)
        clock.lock.lock(); clock.awake = .seconds(6 * 3600 + 601); clock.lock.unlock()
        #expect(box.read().1 == "backup")
        #expect(box.runningFor("backup") == .seconds(6 * 3600 + 601))
    }

    // MARK: - qfZ4n: a hand edit with no Sprava write after it still reaches the op log

    @Test func aHandEditIsRecordedWithoutAWrite() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        let url = folder.appendingPathComponent("catalog.json")
        let text = try String(contentsOf: url, encoding: .utf8)
        try text.replacingOccurrences(of: "\"estate-example-2026-007\"", with: "\"estate-example-2026-007\", \"note\": \"edited by hand\"")
            .write(to: url, atomically: true, encoding: .utf8)
        let at = Date()
        let rows = Shelf.rows(registry: nil, picked: [folder])
        #expect(OutsideEdits.settle(rows, deviceID: "t", now: at).failed.isEmpty)
        #expect(try TekaStore(folder: folder).readOpLog().ops.last?["op"] == .str("external_edit"))
        let day = CalendarDate.today(now: at)
        #expect(Measures(support: try self.folder()).compute(rows: rows, from: day, to: day, now: at).externalEdits.count == 1)
        // Settling again finds nothing new.
        _ = OutsideEdits.settle(rows, deviceID: "t", now: at)
        #expect(try TekaStore(folder: folder).readOpLog().ops.filter { $0["op"] == .str("external_edit") }.count == 1)
    }
}

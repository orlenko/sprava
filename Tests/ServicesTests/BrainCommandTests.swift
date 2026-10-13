import BinderFormat
import BinderStore
import Brains
import Capture
import Darwin
import Extract
import Foundation
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Brains through the command table and the MCP server together: retries, filing proposals, the client registry,
/// changed and revoked clients, and documents a brain may not read. Invented data only.
@Suite(.serialized) struct BrainCommandTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    let clerk = JSONObject([(key: "kind", value: .str("clerk")), (key: "client", value: .str("t")), (key: "model", value: .str("none"))])

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

    func temp(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sb-\(label)-\(UUID().uuidString.prefix(8))")
    }

    func call(_ c: Commands, _ fields: [(String, JSONValue)]) throws -> JSONValue {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj(fields)), now: now, today: today)).value
    }

    func cards(_ c: Commands, _ folder: URL) throws -> [JSONValue] {
        try JSONParser.parse(c.handle(JSONWriter.compact(.obj([("command", .str("proposals")), ("binder", .string(folder.path))])))).value["proposals"]?.arrayValue ?? []
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

    // MARK: - qIe1K: no brain files a file from intake/ while intake documents do not reach brains (issue #283)

    @Test func aBrainCannotProposeFilingAnIntakeFile() throws {
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
        let before = try cards(s.commands, s.folder).count
        #expect(try propose(s.server, ops: [filing(from: nil)])["isError"] == .bool(true))
        let r = try propose(s.server, ops: [filing(from: "intake/scan.pdf")])
        #expect(r["isError"] == .bool(true), "\(r)")
        #expect(r["structuredContent"]?["error"]?.stringValue?.hasPrefix("file_document: brains get no intake documents") == true)
        #expect(try cards(s.commands, s.folder).count == before)
        #expect(FileManager.default.fileExists(atPath: intake.appendingPathComponent("scan.pdf").path))
        #expect(!FileManager.default.fileExists(atPath: s.folder.appendingPathComponent("correspondence/notary/scan.pdf").path))
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

    /// No intake document reaches a brain (issue #283): a remembered reading id opens nothing, before or after the
    /// person rejects its card, and the reading stays waiting for the person.
    @Test func aRememberedReadingIDOpensNothing() throws {
        let s = try setup(documents: true)
        let set = try JSONParser.parse(s.commands.handle(JSONWriter.compact(.obj([
            ("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("set_disclosure")),
            ("args", .obj([("disclosure", .str("full"))]))])), now: pNow, today: today)).value
        #expect(set["ok"] == .bool(true), "\(set)")
        let card = Proposal.make(title: "File the invented notice", actor: clerk, ops: [], now: pNow)
        try ProposalStore.save(card, in: s.folder)
        let store = IntakeReadings(support: s.commands.support)
        var e = IntakeReadings.Entry(id: "reading-astra", binder: s.folder.standardizedFileURL.path, name: "notice.txt",
                                     sha256: String(repeating: "0", count: 64), card: card.id,
                                     reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented notice.", channel: "other"), now: pNow)
        e.escalation = "waiting"
        try store.save(e)
        let args = JSONValue.obj([("binder", .str("estate-example")), ("reading_id", .str("reading-astra"))])
        for rejected in [false, true] {
            if rejected { try TekaStore(folder: s.folder).reject(card, now: pNow) }
            #expect(try tool(s.server, "read_document", args)["structuredContent"]?["error"] == .str("not found"))
            #expect(try tool(s.server, "finish_reading", args)["structuredContent"]?["error"] == .str("not found"))
            let proposed = try tool(s.server, "propose_ops", .obj([("binder", .str("estate-example")), ("title", .str("Invented card")),
                                                                     ("reading_id", .str("reading-astra")), ("ops", .array([addItem(1)]))]))
            #expect(proposed["structuredContent"]?["error"] == .str("reading_id: not found"))
            #expect(store.load("reading-astra")?.escalation == "waiting")
        }
    }

    @Test func aRevocationQueuedAheadOfACallStopsIt() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("dev"))]), now: now)
        let support = temp("sock")
        let c = Commands(support: support, deviceID: "dev")
        let token = try #require(try call(c, [("command", .str("register_client")), ("client_id", .str("brain-7")),
                                              ("binders", .obj([(folder.standardizedFileURL.path, .str("propose"))]))])["token"]?.stringValue)
        let queue = DispatchQueue(label: "test.mcp.commands")
        let listener = MCPListener(support: support, commands: c, queue: queue,
                                   shelf: { Shelf.rows(registry: nil, picked: [folder]) }, log: { _ in })
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let server = fds[1]
        Thread { listener.serve(server) }.start()
        let client = fds[0]
        defer { close(client) }
        setTimeout(client, seconds: 5)
        let reader = LineReader(fd: client)
        #expect(writeLine(client, JSONWriter.compact(.obj([("sprava_auth", .obj([("client_id", .str("brain-7")), ("token", .string(token))]))]))))
        guard case .line(let auth) = reader.next(limit: 4096) else { Issue.record("no reply to the preamble"); return }
        #expect(auth.contains("\"ok\":true"))

        // The command queue is busy; the call arrives and waits behind it, then the revocation lands first.
        let busy = DispatchSemaphore(value: 0)
        queue.async { busy.wait() }
        #expect(writeLine(client, #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{\#(meta),"name":"list_binders","arguments":{}}}"#))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(try call(c, [("command", .str("revoke_client")), ("client_id", .str("brain-7"))])["ok"] == .bool(true))
        busy.signal()
        guard case .end = reader.next(limit: MCPListener.lineLimit) else { Issue.record("the revoked client's call ran"); return }
    }

    @Test func aRevokedClientIsCutOffAndItsCardsWithdrawn() throws {
        let folder = try makeTeka(fixture: "sprava-v0")
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sp3r-\(UUID().uuidString.prefix(8))")
        let commands = Commands(support: support, deviceID: "t")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: pNow)
        var clients = MCPClients()
        let token = try clients.register(id: "brain-1", name: "b", binders: [folder.standardizedFileURL.path: "propose"])
        try clients.save(support)
        let listener = MCPListener(support: support, commands: commands, queue: DispatchQueue(label: "q"),
                                   shelf: { Shelf.rows(registry: nil, picked: [folder]) }, log: { _ in })
        try listener.start()
        defer { listener.stop() }
        let fd = try MCPShimConnection.connect(socket: listener.socketURL.path, clientID: "brain-1", token: token).get()
        defer { close(fd) }
        let reader = LineReader(fd: fd)
        let meta = #""_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientCapabilities":{}}"#
        func propose(_ n: Int) -> JSONValue? {
            let line = #"{"jsonrpc":"2.0","id":\#(n),"method":"tools/call","params":{\#(meta),"name":"propose_ops","arguments":{"binder":"estate-example","title":"t\#(n)","ops":[{"op":"add_log_entry","args":{"entry":{"action":"noted","title":"x","date":"2026-10-06"}}}]}}}"#
            _ = writeLine(fd, line)
            guard case .line(let r) = reader.next(limit: 1 << 20) else { return nil }
            return try? JSONParser.parse(r).value
        }
        #expect(propose(1)?["result"]?["structuredContent"]?["proposal_id"] != nil)
        let r = try JSONParser.parse(commands.handle(#"{"command":"revoke_client","client_id":"brain-1"}"#, now: pNow)).value
        #expect(r["withdrawn"] == .int(1))
        #expect(propose(2) == nil)   // the connection is closed
    }
}

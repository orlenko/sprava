import BinderFormat
import BinderStore
@testable import Brains
import Capture
import CryptoKit
import Darwin
import Extract
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// Regressions from the second layer review of the Brains target: retries that believed a stored card's metadata,
/// an unreadable card that let a request make a second one, intake hashing on the command queue, authenticated
/// connections without a limit, and peer text in the log. Invented data only.
@Suite(.serialized) struct BrainsLayerReview2Tests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-brains2-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func setup() throws -> (MCPServer, URL, Commands) {
        let folder = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: folder).adopt(survey: JSONObject(), owner: JSONObject([(key: "device", value: .str("t"))]), now: now)
        let commands = Commands(support: try scratch("support"), deviceID: "t")
        let client = MCPClientRecord(id: "claude-code-1", name: "Claude Code", tokenSHA256: "", binders: [folder.standardizedFileURL.path: "propose"],
                                     createdAt: "", revoked: false)
        let now = self.now
        return (MCPServer(client: client, commands: commands, shelf: { Shelf.rows(registry: nil, picked: [folder]) }, now: { now }), folder, commands)
    }

    func line(_ name: String, _ arguments: [(String, JSONValue)]) -> String {
        JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", .int(1)), ("method", .str("tools/call")),
                                 ("params", .obj([("_meta", .obj([("io.modelcontextprotocol/protocolVersion", .str("2026-07-28"))])),
                                                  ("name", .string(name)), ("arguments", .obj(arguments))]))]))
    }

    func result(_ s: MCPServer, _ line: String) throws -> JSONValue {
        let reply = try #require(s.handle(line: line))
        return try #require(try JSONParser.parse(reply).value["result"])
    }

    func tool(_ s: MCPServer, _ name: String, _ arguments: [(String, JSONValue)]) throws -> JSONValue { try result(s, line(name, arguments)) }

    let addItem = JSONValue.obj([("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Call the notary")),
                                                                                       ("status", .str("open")), ("priority", .str("normal")),
                                                                                       ("no_deadline", .bool(true))]))]))])

    func waiting(_ id: String, card: String, in folder: URL, _ commands: Commands) throws -> IntakeReadings {
        let readings = IntakeReadings(support: commands.support)
        var e = IntakeReadings.Entry(id: id, binder: folder.standardizedFileURL.path, name: "letter.pdf", sha256: String(repeating: "0", count: 64),
                                     card: card, reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented letter.", channel: "other"), now: now)
        e.escalation = "waiting"
        try readings.save(e)
        return readings
    }

    func cardFile(_ folder: URL, _ id: String) -> URL { ProposalStore.dir(folder).appendingPathComponent("\(id).json") }

    // MARK: - 1. A retry believes nothing in a stored card unless Sprava recorded its digest

    @Test func aRetryNeverBelievesAChangedRecordedCard() throws {
        let (server, folder, commands) = try setup()
        let filing = try tool(server, "propose_ops", [("binder", .str("estate-example")), ("title", .str("Filing card")), ("ops", .array([addItem]))])
        let readings = try waiting("reading-other", card: try #require(filing["structuredContent"]?["proposal_id"]?.stringValue), in: folder, commands)
        #expect(readings.escalation("reading-other", in: folder.standardizedFileURL.path) != nil)
        let args: [(String, JSONValue)] = [("binder", .str("estate-example")), ("title", .str("Call card")), ("ops", .array([addItem])),
                                           ("request_id", .str("invented-request-1"))]
        let id = try #require(try tool(server, "propose_ops", args)["structuredContent"]?["proposal_id"]?.stringValue)

        // Another program points the recorded card at another reading.
        var raw = try #require(ProposalStore.list(in: folder).first { $0.0.id == id }?.0.raw)
        raw.set("provenance", .obj([("client", .str("claude-code-1")), ("reading", .str("reading-other"))]))
        try Data(JSONWriter.pretty(.object(raw)).utf8).write(to: cardFile(folder, id))

        let r = try tool(server, "propose_ops", args)
        #expect(r["isError"] == .bool(true))
        #expect(r["structuredContent"]?["error"]?.stringValue?.contains("changed outside Sprava") == true)
        #expect(readings.load("reading-other")?.escalation == "waiting")
    }

    @Test func anUnrecordedCardIsReplacedByTheRequest() throws {
        let (server, folder, commands) = try setup()
        // As a runtime that stopped before recording it would have left it, but with a forged expectation and reading.
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .str("claude-code-1"))])
        let body = JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: addItem["args"] ?? .obj([]))])
        var card = Proposal.make(title: "Earlier card", actor: actor, ops: [body], now: now)
        card.raw.set("request_id", .str("invented-request-2"))
        card.raw.set("expect", .obj([("invented-item-1", .str("forged"))]))
        card.raw.set("provenance", .obj([("client", .str("claude-code-1")), ("reading", .str("reading-forged"))]))
        try FileManager.default.createDirectory(at: ProposalStore.dir(folder), withIntermediateDirectories: true)
        try Data(JSONWriter.pretty(.object(card.raw)).utf8).write(to: cardFile(folder, card.id))

        let r = try tool(server, "propose_ops", [("binder", .str("estate-example")), ("title", .str("Earlier card")), ("ops", .array([addItem])),
                                                 ("request_id", .str("invented-request-2"))])
        #expect(r["isError"] == .bool(false))
        #expect(r["structuredContent"]?["proposal_id"]?.stringValue == card.id)
        let stored = try commands.loadTrusted(card.id, in: folder)
        #expect(stored.raw["expect"]?["invented-item-1"] == nil)
        #expect(stored.raw["provenance"]?["reading"] == nil)
        #expect(ProposalStore.list(in: folder).count == 1)
    }

    // MARK: - 2. An unreadable card stops a request from making a second one

    @Test func anUnreadableCardRefusesTheRetry() throws {
        let (server, folder, _) = try setup()
        let args: [(String, JSONValue)] = [("binder", .str("estate-example")), ("title", .str("Call card")), ("ops", .array([addItem])),
                                           ("request_id", .str("invented-request-3"))]
        let id = try #require(try tool(server, "propose_ops", args)["structuredContent"]?["proposal_id"]?.stringValue)
        chmod(cardFile(folder, id).path, 0)
        let r = try tool(server, "propose_ops", args)
        chmod(cardFile(folder, id).path, 0o600)
        #expect(r["isError"] == .bool(true))
        #expect(r["structuredContent"]?["error"]?.stringValue?.contains("cannot all be read") == true)
        #expect(ProposalStore.list(in: folder).count == 1)
        // Readable again: the retry answers from the one card.
        #expect(try tool(server, "propose_ops", args)["structuredContent"]?["proposal_id"]?.stringValue == id)
        #expect(ProposalStore.list(in: folder).count == 1)
    }

    // MARK: - 3. A large intake file is hashed off the command queue, and only within a limit

    func filing(_ sha: String) -> [(String, JSONValue)] {
        let op = JSONValue.obj([("op", .str("file_document")), ("args", .obj([
            ("from", .str("intake/scan.bin")),
            ("document", .obj([("id", .str("$new:1")), ("title", .str("Invented scan")), ("path", .str("correspondence/scan.bin")),
                               ("sha256", .string(sha))]))]))])
        return [("binder", .str("estate-example")), ("title", .str("File a scan")), ("ops", .array([op]))]
    }

    @Test func aLargeIntakeFileIsHashedOnlyByPrepare() throws {
        let (server, folder, _) = try setup()
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        let data = Data(repeating: 0x61, count: MCPServer.queuedHashLimit * 2)
        try data.write(to: intake.appendingPathComponent("scan.bin"))
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let request = line("propose_ops", filing(sha))

        // Handled without prepare, as on the command queue: the large file is never read there.
        #expect(try result(server, request)["isError"] == .bool(true))
        // Prepared first, then changed: the digest taken is not used for the new file.
        server.prepare(line: request)
        try data.write(to: intake.appendingPathComponent("scan.bin"))
        #expect(try result(server, request)["isError"] == .bool(true))
        // Prepared first, unchanged: accepted.
        server.prepare(line: request)
        let r = try result(server, request)
        #expect(r["isError"] == .bool(false), "\(r)")
    }

    @Test func anIntakeFileOverTheLimitIsNeverRead() throws {
        let (_, folder, _) = try setup()
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        let url = intake.appendingPathComponent("huge.bin")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        let fd = open(url.path, O_WRONLY)
        #expect(ftruncate(fd, off_t(MCPServer.intakeSizeLimit + 1)) == 0)   // sparse: nothing is written
        close(fd)
        let started = Date()
        #expect(MCPServer.intakeDigest("intake/huge.bin", in: folder) == nil)
        #expect(Date().timeIntervalSince(started) < 1)
    }

    // MARK: - 4. Authenticated connections are limited, and closed on revocation and on stop

    func listener() throws -> (MCPListener, URL, String) {
        // Short, so the socket path stays under the 104-byte limit.
        let support = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spb2-\(UUID().uuidString.prefix(8))")
        var clients = MCPClients()
        let token = try clients.register(id: "invented-1", name: "Invented", binders: [:], now: now)
        try clients.save(support)
        let listener = MCPListener(support: support, commands: Commands(support: support, deviceID: "t"), queue: DispatchQueue(label: "test.mcp-b2"),
                                   shelf: { [] }, log: { _ in })
        try listener.start()
        return (listener, support, token)
    }

    func connect(_ l: MCPListener, _ token: String) -> Result<Int32, MCPShimConnection.Failure> {
        MCPShimConnection.connect(socket: l.socketURL.path, clientID: "invented-1", token: token)
    }

    /// Whether the runtime ended the connection within a few seconds.
    func ended(_ fd: Int32) -> Bool {
        setTimeout(fd, seconds: 5)
        var byte: UInt8 = 0
        return read(fd, &byte, 1) == 0
    }

    @Test func aClientHoldsAtMostItsShareOfConnections() throws {
        let (l, _, token) = try listener()
        defer { l.stop() }
        let held = try (0..<MCPListener.maxPerClient).map { _ in try connect(l, token).get() }
        defer { held.forEach { close($0) } }
        guard case .failure(let failure) = connect(l, token) else { Issue.record("a connection over the limit was admitted"); return }
        #expect(failure.message.contains("too many open connections"))
        // One closes: its place is free again.
        close(held[0])
        Thread.sleep(forTimeInterval: 0.2)
        let again = try connect(l, token).get()
        close(again)
        // Stopping ends the connections still open.
        l.stop()
        #expect(ended(held[1]))
    }

    @Test func anIdleConnectionClosesWhenItsClientIsRevoked() throws {
        let (l, support, token) = try listener()
        defer { l.stop() }
        l.idleCheckSeconds = 1
        let fd = try connect(l, token).get()
        defer { close(fd) }
        var clients = try MCPClients.load(support)
        clients.revoke(id: "invented-1")
        try clients.save(support)
        #expect(ended(fd))
    }

    // MARK: - 5. A refused peer's id reaches the log only when it is registered

    final class Lines: @unchecked Sendable {
        let lock = NSLock()
        var all: [String] = []
        func add(_ s: String) { lock.withLock { all.append(s) } }
    }

    @Test func aRefusedPeerIDIsLoggedOnlyWhenRegistered() throws {
        let support = try scratch("log")
        var clients = MCPClients()
        _ = try clients.register(id: "invented-1", name: "Invented", binders: [:], now: now)
        try clients.save(support)
        let lines = Lines()
        let l = MCPListener(support: support, commands: Commands(support: support, deviceID: "t"), queue: DispatchQueue(label: "test.mcp-log"),
                            shelf: { [] }, log: { lines.add($0) })
        for id in ["confidential-case-4821", "invented-1"] {
            var fds: [Int32] = [0, 0]
            #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
            #expect(writeLine(fds[1], #"{"sprava_auth":{"client_id":"\#(id)","token":"sprava_ct_invented"}}"#))
            l.serve(fds[0])
            close(fds[1])
        }
        #expect(lines.all == ["mcp client=unknown auth=refused", "mcp client=invented-1 auth=refused"])
    }
}

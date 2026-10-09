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

/// Regressions from the layer review of the Brains target: intake hashing through a linked folder, a registry
/// behind a failed lookup, a reading left waiting behind a stored card, and whole lines over the byte limit.
/// Invented data only.
@Suite(.serialized) struct BrainsLayerReviewTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)

    func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-brains-\(name)-\(UUID().uuidString)")
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

    func tool(_ s: MCPServer, _ name: String, _ arguments: [(String, JSONValue)]) throws -> JSONValue {
        let line = JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", .int(1)), ("method", .str("tools/call")),
                                            ("params", .obj([("_meta", .obj([("io.modelcontextprotocol/protocolVersion", .str("2026-07-28"))])),
                                                             ("name", .string(name)), ("arguments", .obj(arguments))]))]))
        let reply = try #require(s.handle(line: line))
        return try #require(try JSONParser.parse(reply).value["result"])
    }

    let addItem = JSONValue.obj([("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Call the notary")),
                                                                                       ("status", .str("open")), ("priority", .str("normal")),
                                                                                       ("no_deadline", .bool(true))]))]))])

    func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    // MARK: - 1. A file behind a linked folder in intake/ is never hashed

    @Test func aLinkedFolderInIntakeIsNeverHashed() throws {
        let (server, folder, _) = try setup()
        let outside = try scratch("outside")
        let secret = Data("An invented private note.".utf8)
        try secret.write(to: outside.appendingPathComponent("note.txt"))
        let intake = folder.appendingPathComponent("intake")
        try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: intake.appendingPathComponent("archive"), withDestinationURL: outside)
        let plain = Data("An invented scan.".utf8)
        try plain.write(to: intake.appendingPathComponent("scan.txt"))
        try Data("invented".utf8).write(to: intake.appendingPathComponent("signing.pem"))

        #expect(MCPServer.intakeDigest("intake/archive/note.txt", in: folder) == nil)
        #expect(MCPServer.intakeDigest("intake/signing.pem", in: folder) == nil)
        #expect(MCPServer.intakeDigest("intake/scan.txt", in: folder) == hex(plain))

        // The right digest of the outside file is refused exactly as a wrong one is: nothing to tell them apart.
        for digest in [hex(secret), String(repeating: "0", count: 64)] {
            let op = JSONValue.obj([("op", .str("file_document")), ("args", .obj([
                ("from", .str("intake/archive/note.txt")),
                ("document", .obj([("id", .str("$new:1")), ("title", .str("Invented note")), ("path", .str("notes/note.txt")),
                                   ("sha256", .string(digest))]))]))])
            let r = try tool(server, "propose_ops", [("binder", .str("estate-example")), ("title", .str("File a note")), ("ops", .array([op]))])
            #expect(r["isError"] == .bool(true))
            #expect(r["structuredContent"]?["error"]?.stringValue?.contains("is not in intake/, or sha256 is not its digest") == true)
        }
        #expect(ProposalStore.list(in: folder).isEmpty)
    }

    // MARK: - 2. A registry whose lookup fails is never read as empty

    @Test func aRegistryBehindAFailedLookupThrows() throws {
        let base = try scratch("registry")
        let support = base.appendingPathComponent("support")
        #expect(try MCPClients.load(support).clients.isEmpty)   // not there: an empty registry

        let locked = base.appendingPathComponent("locked")
        var held = MCPClients()
        _ = try held.register(id: "invented-1", name: "Invented", binders: [:], now: now)
        try held.save(locked)
        try FileManager.default.createDirectory(at: support.appendingPathComponent("mcp"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: MCPClients.url(support), withDestinationURL: MCPClients.url(locked))
        chmod(locked.appendingPathComponent("mcp").path, 0)
        defer { chmod(locked.appendingPathComponent("mcp").path, 0o700) }

        #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(support) }
    }

    // MARK: - 3. A reading left waiting behind a stored card is reported, and a retry finishes it

    @Test func aRetryFinishesTheReadingItsCardAnswers() throws {
        let (server, folder, commands) = try setup()
        let first = try tool(server, "propose_ops", [("binder", .str("estate-example")), ("title", .str("Filing card")), ("ops", .array([addItem]))])
        let card = try #require(first["structuredContent"]?["proposal_id"]?.stringValue)
        let readings = IntakeReadings(support: commands.support)
        var e = IntakeReadings.Entry(id: "reading-1", binder: folder.standardizedFileURL.path, name: "letter.pdf", sha256: String(repeating: "0", count: 64),
                                     card: card, reading: IntakeReading(kind: "text", textFrom: "parsed", text: "An invented letter.", channel: "other"), now: now)
        e.escalation = "waiting"
        try readings.save(e)

        let args: [(String, JSONValue)] = [("binder", .str("estate-example")), ("title", .str("Answer the letter")), ("ops", .array([addItem])),
                                           ("reading_id", .str("reading-1")), ("request_id", .str("invented-request-1"))]
        chmod(readings.dir.path, 0o500)
        let failed = try tool(server, "propose_ops", args)
        chmod(readings.dir.path, 0o700)
        #expect(failed["isError"] == .bool(true))
        #expect(failed["structuredContent"]?["error"]?.stringValue?.contains("could not be marked answered") == true)
        #expect(readings.load("reading-1")?.escalation == "waiting")

        let retried = try tool(server, "propose_ops", args)
        #expect(retried["isError"] == .bool(false))
        let id = try #require(retried["structuredContent"]?["proposal_id"]?.stringValue)
        #expect(readings.load("reading-1")?.escalation == "answered")
        #expect(readings.load("reading-1")?.answer == id)
        #expect(ProposalStore.list(in: folder).filter { $0.0.raw["request_id"] == .str("invented-request-1") }.count == 1)
    }

    // MARK: - 4. A whole line that arrives in one read is held to the limit

    func reader(sending bytes: [UInt8]) throws -> (LineReader, [Int32]) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        #expect(bytes.withUnsafeBytes { write(fds[1], $0.baseAddress!, bytes.count) } == bytes.count)
        return (LineReader(fd: fds[0]), fds)
    }

    @Test func aCompleteLineOverTheLimitIsTooLong() throws {
        let (over, a) = try reader(sending: [UInt8](repeating: 0x61, count: MCPListener.preambleLimit + 904) + [0x0A])
        defer { a.forEach { close($0) } }
        guard case .tooLong = over.next(limit: MCPListener.preambleLimit) else { Issue.record("a 5,000-byte line passed a 4,096-byte limit"); return }

        let (exact, b) = try reader(sending: [UInt8](repeating: 0x61, count: MCPListener.preambleLimit) + [0x0A])
        defer { b.forEach { close($0) } }
        guard case .line(let line) = exact.next(limit: MCPListener.preambleLimit) else { Issue.record("a line at the limit was refused"); return }
        #expect(line.utf8.count == MCPListener.preambleLimit)
    }

    // MARK: - 5. A retried card an earlier runtime stored is trusted by the digest of the bytes compared

    @Test func aRetriedCardFromAnEarlierRuntimeIsTrustedByItsCheckedDigest() throws {
        let (server, folder, commands) = try setup()
        // Written as a runtime that stopped before recording it would have left it: not by this process.
        let actor = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .string(commands.client)),
                                (key: "model", value: .str("claude-code-1"))])
        let body = JSONObject([(key: "op", value: .str("add_item")), (key: "args", value: addItem["args"] ?? .obj([]))])
        var card = Proposal.make(title: "Earlier card", actor: actor, ops: [body], now: now)
        card.raw.set("request_id", .str("invented-request-2"))
        let dir = ProposalStore.dir(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(JSONWriter.pretty(.object(card.raw)).utf8).write(to: dir.appendingPathComponent("\(card.id).json"))
        #expect(!server.isRecorded(card.id, in: folder))

        let r = try tool(server, "propose_ops", [("binder", .str("estate-example")), ("title", .str("Earlier card")), ("ops", .array([addItem])),
                                                 ("request_id", .str("invented-request-2"))])
        #expect(r["isError"] == .bool(false))
        #expect(r["structuredContent"]?["proposal_id"]?.stringValue == card.id)
        #expect(server.isRecorded(card.id, in: folder))
        let (_, digest) = try #require(ProposalStore.list(in: folder).first { $0.0.id == card.id })
        #expect(try commands.loadDigests()[commands.key(folder, card.id)] == digest)
    }
}

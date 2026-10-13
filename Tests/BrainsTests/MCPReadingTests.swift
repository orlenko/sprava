import BinderFormat
import BinderStore
@testable import Brains
import Capture
import Darwin
import Foundation
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// A client registry behind a failed lookup throws, and a retried card from an earlier runtime is trusted by its
/// checked digest. Invented data only.
@Suite(.serialized) struct MCPReadingTests {
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

    // MARK: - 1. A registry whose lookup fails is never read as empty

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

    // MARK: - 2. A retried card from an earlier runtime is trusted by its checked digest

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

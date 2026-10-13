import BinderFormat
import BinderStore
import Brains
import Capture
import Clerk
import ClerkTestSupport
import Foundation
import Hub
@testable import Services
import Shelf
import SpravaKit
import SpravaTestSupport
import Testing

/// A brain's view of a binder follows what the person confirmed: an outside widening does not open it, and a
/// revocation withdraws the cards a client registered again under the same id had made. Invented data only.
@Suite(.serialized) struct BrainScopeCommandTests: BinderCommandFixture {
    @Test func anOutsideWideningDoesNotOpenTheBinderToBrains() throws {
        let c = commands()
        let (folder, _) = try createdBinder(c)
        try outsideEdit(folder, setMeta("disclosure", .str("full")))
        let client = MCPClientRecord(id: "brain-1", name: "Brain", tokenSHA256: "", binders: [folder.standardizedFileURL.path: "propose"],
                                     createdAt: "", revoked: false)
        let server = MCPServer(client: client, commands: c, shelf: { Shelf.rows(registry: nil, picked: [folder]) }, now: { self.now })
        #expect(server.visible().isEmpty)
        // The person's own raise opens it at once.
        _ = try apply(c, folder, "set_disclosure", .obj([("disclosure", .str("full"))]))
        #expect(server.visible().count == 1)
    }

    @Test func revokeWithdrawsCardsOfAClientRegisteredAgain() throws {   // p8-Qs
        let c = commands()
        let (a, _) = try readyBinder(c)
        let (b, _) = try createdBinder(c)
        _ = try call(c, [("command", .str("register_client")), ("client_id", .str("c1")), ("binders", .obj([(a.path, .str("propose"))]))])
        _ = try call(c, [("command", .str("revoke_client")), ("client_id", .str("c1"))])
        _ = try call(c, [("command", .str("register_client")), ("client_id", .str("c1")), ("binders", .obj([(b.path, .str("propose"))]))])
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "client", value: .str("sprava/0.1")), (key: "model", value: .str("c1"))])
        let card = Proposal.make(title: "x", actor: brain, ops: [body("add_log_entry", .obj([("entry", .obj([("action", .str("noted"))]))]))], now: now)
        try ProposalStore.save(card, in: b)
        let r = try call(c, [("command", .str("revoke_client")), ("client_id", .str("c1"))])
        #expect(r["withdrawn"] == .int(1))
        #expect(ProposalStore.list(in: b).first { $0.0.id == card.id }?.0.state == "rejected")
    }

    @Test func anOversizedProposalCollectionDoesNotPreventRevocationOrReportWithdrawal() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        _ = try call(c, [("command", .str("register_client")), ("client_id", .str("invented-client")),
                         ("binders", .obj([(folder.path, .str("propose"))]))])
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "model", value: .str("invented-client"))])
        let card = Proposal.make(title: "Invented card", actor: brain, ops: [], now: now)
        try ProposalStore.save(card, in: folder)
        let directory = folder.appendingPathComponent(".sprava/proposals")
        for i in 0..<120 { try Data().write(to: directory.appendingPathComponent("invented-\(i).txt")) }
        let result = try call(c, [("command", .str("revoke_client")), ("client_id", .str("invented-client"))])
        #expect(result["ok"] == .bool(false))
        #expect(result["error"]?.stringValue?.contains("client was revoked") == true)
        #expect(try MCPClients.load(c.support).clients.first { $0.id == "invented-client" }?.revoked == true)
        #expect(try ProposalStore.load(card.id, in: folder, expectedDigest: nil).state == "proposed")
        // Removing the excess entries lets the person retry the withdrawal after access has already ended.
        for i in 0..<120 { try FileManager.default.removeItem(at: directory.appendingPathComponent("invented-\(i).txt")) }
        let retried = try call(c, [("command", .str("revoke_client")), ("client_id", .str("invented-client"))])
        #expect(retried["ok"] == .bool(true) && retried["withdrawn"] == .int(1))
        #expect(try ProposalStore.load(card.id, in: folder, expectedDigest: nil).state == "rejected")
    }

    @Test func aWithdrawalThatCannotBeSavedIsReportedAndCanBeRetried() throws {
        let c = commands()
        let (folder, _) = try readyBinder(c)
        _ = try call(c, [("command", .str("register_client")), ("client_id", .str("invented-client")),
                         ("binders", .obj([(folder.path, .str("propose"))]))])
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "model", value: .str("invented-client"))])
        let card = Proposal.make(title: "Invented card", actor: brain, ops: [], now: now)
        try ProposalStore.save(card, in: folder)
        let directory = folder.appendingPathComponent(".sprava/proposals")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        let result = try call(c, [("command", .str("revoke_client")), ("client_id", .str("invented-client"))])
        #expect(result["ok"] == .bool(false))
        #expect(result["error"]?.stringValue?.contains("client was revoked") == true)
        #expect(try MCPClients.load(c.support).clients.first { $0.id == "invented-client" }?.revoked == true)
        #expect(try ProposalStore.load(card.id, in: folder, expectedDigest: nil).state == "proposed")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let retried = try call(c, [("command", .str("revoke_client")), ("client_id", .str("invented-client"))])
        #expect(retried["ok"] == .bool(true) && retried["withdrawn"] == .int(1))
        #expect(try ProposalStore.load(card.id, in: folder, expectedDigest: nil).state == "rejected")
    }

    @Test func revocationWithdrawsOnlyCardsInBindersThisDeviceOwns() throws {
        let c = commands()
        let (owned, _) = try readyBinder(c)
        let foreign = try makeTeka(fixture: "sprava-v0")
        _ = try TekaStore(folder: foreign).adopt(survey: JSONObject(),
            owner: JSONObject([(key: "device", value: .str("invented-other-device"))]), now: now)
        _ = try call(c, [("command", .str("register_client")), ("client_id", .str("invented-client")),
                         ("binders", .obj([(owned.path, .str("propose")), (foreign.path, .str("propose"))]))])
        let brain = JSONObject([(key: "kind", value: .str("brain")), (key: "model", value: .str("invented-client"))])
        let ownCard = Proposal.make(title: "Invented local card", actor: brain, ops: [], now: now)
        let foreignCard = Proposal.make(title: "Invented foreign card", actor: brain, ops: [], now: now)
        try ProposalStore.save(ownCard, in: owned)
        try ProposalStore.save(foreignCard, in: foreign)
        let foreignFile = foreign.appendingPathComponent(".sprava/proposals/\(foreignCard.id).json")
        let before = try Data(contentsOf: foreignFile)
        let result = try call(c, [("command", .str("revoke_client")), ("client_id", .str("invented-client"))])
        #expect(result["ok"] == .bool(true) && result["withdrawn"] == .int(1))
        #expect(try MCPClients.load(c.support).clients.first { $0.id == "invented-client" }?.revoked == true)
        #expect(try ProposalStore.load(ownCard.id, in: owned, expectedDigest: nil).state == "rejected")
        #expect(try Data(contentsOf: foreignFile) == before)
    }
}

extension IntakeReadingCommandTests {
    /// No intake document reaches a brain (MCPServer.intakeReachesBrains, issue #283), even one the person allowed
    /// to read documents, in a binder at full disclosure where it may propose: the reading stays with the person.
    @Test func aBrainWithinItsPermissionGetsNoIntakeReading() async throws {
        let s = try setup()
        _ = try await clerkReads(s)
        let name = Teka.read(s.folder).name
        _ = try call(s, [("command", .str("apply")), ("binder", .string(s.folder.path)), ("op", .str("set_disclosure")),
                         ("args", .obj([("disclosure", .str("full"))]))])
        let readings = IntakeReadings(support: s.support)
        let id = try #require(readings.escalations().first?.id)
        #expect(readings.load(id)?.escalation == "waiting")
        func server(documents: Bool) -> MCPServer {
            var client = MCPClientRecord(id: "claude-code-1", name: "Claude Code", tokenSHA256: "",
                                         binders: [s.folder.standardizedFileURL.path: "propose"], createdAt: "", revoked: false)
            client.documents = documents ? true : nil
            return MCPServer(client: client, commands: s.commands, shelf: { Shelf.rows(registry: nil, picked: [s.folder]) }, now: { self.now })
        }
        func tool(_ srv: MCPServer, _ name: String, _ args: JSONValue) throws -> JSONValue {
            let line = JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", .int(1)), ("method", .str("tools/call")),
                                                ("params", .obj([("_meta", .obj([("io.modelcontextprotocol/protocolVersion", .str("2026-07-28")),
                                                                                  ("io.modelcontextprotocol/clientCapabilities", .obj([]))])),
                                                                 ("name", .string(name)), ("arguments", args)]))]))
            return try JSONParser.parse(try #require(srv.handle(line: line))).value["result"] ?? .null
        }
        let brain = server(documents: true)
        let listed = try tool(brain, "list_readings", .obj([]))
        #expect(listed["structuredContent"]?["can_read_documents"] == .bool(true))
        #expect(listed["structuredContent"]?["readings"]?.arrayValue?.isEmpty == true)
        // Without the person's permission the answer is about the permission; with it, the reading is not found.
        let args = JSONValue.obj([("binder", .string(name)), ("reading_id", .string(id))])
        let refused = try tool(server(documents: false), "read_document", args)
        #expect(refused["isError"] == .bool(true))
        #expect(refused["structuredContent"]?["error"]?.stringValue?.contains("not allowed") == true)
        let read = try tool(brain, "read_document", args)
        #expect(read["isError"] == .bool(true))
        #expect(read["structuredContent"]?["error"] == .str("not found"))
        #expect(try tool(brain, "finish_reading", args)["structuredContent"]?["error"] == .str("not found"))
        let item = JSONValue.obj([("op", .str("add_item")), ("args", .obj([("item", .obj([("id", .str("$new:1")), ("title", .str("Confirm the payment method")),
                                                                                        ("status", .str("open")), ("priority", .str("normal")), ("due", .str("2026-10-20"))]))]))])
        let before = ProposalStore.list(in: s.folder).count
        let answered = try tool(brain, "propose_ops", .obj([("binder", .string(name)), ("title", .str("Confirm the payment method")),
                                                            ("reading_id", .string(id)), ("ops", .array([item]))]))
        #expect(answered["isError"] == .bool(true))
        #expect(ProposalStore.list(in: s.folder).count == before)
        #expect(readings.load(id)?.escalation == "waiting")
        // Proposing within its permission still works, and leaves the reading waiting for the person.
        let proposed = try tool(brain, "propose_ops", .obj([("binder", .string(name)), ("title", .str("Confirm the payment method")),
                                                            ("ops", .array([item]))]))
        #expect(proposed["isError"] == .bool(false), "\(proposed)")
        #expect(readings.load(id)?.escalation == "waiting")
    }
}

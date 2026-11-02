import BinderStore
import Brains
import Foundation
import Services
import SpravaKit
import Testing

struct ExternalRegistrationRetirementTests {
    @Test func registrationAndWideningCommandsAreGoneAndLegacyRevocationPersists() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("retired-mcp-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support) }
        let commands = Commands(support: support, deviceID: "invented")
        func call(_ fields: [(String, JSONValue)]) throws -> JSONValue {
            try JSONParser.parse(commands.handle(JSONWriter.compact(.obj(fields)))).value
        }
        for name in ["register_client", "client_documents"] {
            #expect(try call([("command", .str(name)), ("client_id", .str("claude-code-1")),
                              ("binders", .obj([])), ("documents", .bool(true))])["ok"] == .bool(false))
        }
        #expect(!FileManager.default.fileExists(atPath: support.path))
        _ = try legacyClient(commands, id: "claude-code-1", binders: [:]) // an older renewed generation
        let old = try legacyClient(commands, id: "claude-code-1", binders: [:])
        let other = try legacyClient(commands, id: "invented-other", binders: [:])
        #expect(try call([("command", .str("list_clients"))])["legacy_terminal"] == .bool(false))
        _ = try call([("command", .str("revoke_client")), ("client_id", .str("claude-code-1"))])
        let listed = try call([("command", .str("list_clients"))])
        #expect(listed["legacy_terminal"] == .bool(true))
        #expect(listed["clients"]?.arrayValue?.map { $0["id"]?.stringValue } == ["invented-other"])
        let persisted = try MCPClients.load(support)
        #expect(persisted.authenticate(clientID: "claude-code-1", token: old) == nil)
        #expect(persisted.authenticate(clientID: "invented-other", token: other) != nil)
    }
}

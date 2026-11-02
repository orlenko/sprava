import BinderStore
import Brains
import Foundation
import Services
import SpravaKit
import Testing
@testable import SpravaApp

@MainActor @Suite struct BrainsModelTests {
    @Test func freshAssistantDoesNotCreateAClientRegistry() async throws {
        let root = try temporaryFolder(), support = root.appendingPathComponent("support")
        defer { try? FileManager.default.removeItem(at: root) }
        let commands = Commands(support: support, deviceID: "invented")
        var sent: [String] = []
        let model = BrainsModel(client: RuntimeClient(answer: { text in
            sent.append(try JSONParser.parse(text).value["command"]?.stringValue ?? "?")
            return commands.handle(text)
        }))
        await model.load()
        #expect(sent == ["list_clients"] && model.clients.isEmpty && !model.legacyTerminal)
        #expect(!FileManager.default.fileExists(atPath: support.path))
    }

    @Test func openingAssistantRetiresOnlyTheKnownInstallerCapabilityAndRemembersIt() async throws {
        let support = try temporaryFolder()
        defer { try? FileManager.default.removeItem(at: support) }
        var records = MCPClients()
        let old = try records.register(id: "claude-code-1", name: "Claude Code", binders: [:])
        let other = try records.register(id: "invented-other", name: "Invented other client", binders: [:])
        try records.save(support)
        let commands = Commands(support: support, deviceID: "invented")
        var sent: [String] = []
        let client = RuntimeClient(answer: { text in
            sent.append(try JSONParser.parse(text).value["command"]?.stringValue ?? "?")
            return commands.handle(text)
        })
        let model = BrainsModel(client: client)
        await model.load()
        #expect(sent == ["list_clients", "revoke_client", "list_clients"])
        #expect(model.legacyTerminal && model.clients.map(\.id) == ["invented-other"])
        let saved = try MCPClients.load(support)
        #expect(saved.authenticate(clientID: "claude-code-1", token: old) == nil)
        #expect(saved.authenticate(clientID: "invented-other", token: other) != nil)
        sent = []
        let reopened = BrainsModel(client: client)
        await reopened.load()
        #expect(reopened.legacyTerminal && sent == ["list_clients"])
        await reopened.disconnect(try #require(reopened.clients.first))
        #expect(reopened.clients.isEmpty)
        #expect(try MCPClients.load(support).authenticate(clientID: "invented-other", token: other) == nil)
    }

    @Test func incompleteWithdrawalRemainsVisibleAfterAccessHasEnded() async {
        let runtime = StandInRuntime()
        var revoked = false
        runtime.answers["list_clients"] = { _ in JSONWriter.compact(.obj([
            ("ok", .bool(true)), ("legacy_terminal", .bool(revoked)),
            ("clients", .array(revoked ? [] : [.obj([("id", .str("claude-code-1")), ("binders", .obj([]))])])),
        ])) }
        runtime.answers["revoke_client"] = { _ in
            revoked = true
            return #"{"ok":false,"error":"the client was revoked, but its waiting proposals could not all be withdrawn"}"#
        }
        let model = BrainsModel(client: runtime.client)
        await model.load()
        #expect(model.legacyTerminal && model.clients.isEmpty && !model.busy)
        #expect(model.message?.contains("Access was revoked") == true)
    }

    @Test func aFailedRetirementStaysVisibleAndCanBeRetried() async {
        let runtime = StandInRuntime()
        runtime.answers["list_clients"] = { _ in #"{"ok":true,"clients":[{"id":"claude-code-1","binders":{}}]}"# }
        runtime.answers["revoke_client"] = { _ in #"{"ok":false,"error":"invented private provider output"}"# }
        let model = BrainsModel(client: runtime.client)
        await model.load()
        #expect(model.clients.count == 1 && model.message?.contains("could not be disconnected") == true)
        #expect(model.message?.contains("private provider") == false && !model.busy)
    }

    @Test func assistantAccountSetupStillUsesThePrivateRuntimeConfiguration() async {
        let runtime = StandInRuntime()
        runtime.answers["claude_configure"] = { _ in #"{"ok":true}"# }
        runtime.answers["claude_status"] = { _ in #"{"ok":true,"enabled":true,"available":true,"persistent":true}"# }
        let model = ClaudeAccountModel(client: runtime.client, authenticate: {})
        model.program = "/invented/claude"; model.token = "invented-subscription-token"
        await model.enable()
        #expect(model.enabled && model.token.isEmpty)
        #expect(runtime.sent.map { $0["command"]?.stringValue } == ["claude_configure", "claude_status"])
    }
}

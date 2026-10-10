@testable import Brains
import Darwin
import Foundation
import SpravaKit
import Testing

/// Client registry fixtures are invented and live only in temporary folders.
@Suite struct MCPClientsTests {
    let now = Date(timeIntervalSince1970: 1_791_360_000)
    @Test func tokensAuthenticateAndRevoke() throws {
        var clients = MCPClients()
        let token = try clients.register(id: "claude-code-1", name: "Claude Code", binders: [:])
        #expect(token.hasPrefix("sprava_ct_") && token.count == 74)
        #expect(clients.authenticate(clientID: "claude-code-1", token: token) != nil)
        #expect(clients.authenticate(clientID: "claude-code-1", token: token + "x") == nil)
        #expect(clients.authenticate(clientID: "other", token: token) == nil)
        clients.revoke(id: "claude-code-1")
        #expect(clients.authenticate(clientID: "claude-code-1", token: token) == nil)
    }
    @Test func zeroBytesWouldMakeTheAllZeroToken() {
        // What a failed random source would have left: the token every such client would share.
        #expect(MCPClients.token([UInt8](repeating: 0, count: 32)) == "sprava_ct_" + String(repeating: "0", count: 64))
    }

    @Test func newTokensAreRandomAndWellFormed() throws {
        let tokens = (0..<64).map { _ in MCPClients.newToken() }
        #expect(Set(tokens).count == tokens.count)
        #expect(!tokens.contains(MCPClients.token([UInt8](repeating: 0, count: 32))))
        for token in tokens { #expect(token.wholeMatch(of: /sprava_ct_[0-9a-f]{64}/) != nil) }
        var clients = MCPClients()
        let a = try clients.register(id: "invented-a", name: "Invented A", binders: [:], now: now)
        let b = try clients.register(id: "invented-b", name: "Invented B", binders: [:], now: now)
        #expect(a != b)
        #expect(clients.authenticate(clientID: "invented-a", token: a)?.id == "invented-a")
        #expect(clients.authenticate(clientID: "invented-a", token: b) == nil)
    }
    @Test func aSpecialClientRegistryIsRefusedWithoutBlockingTheCommandQueue() throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-brains-registry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: support) }
        let registry = MCPClients.url(support)
        try AtomicFile.makePrivateFolder(registry.deletingLastPathComponent())
        let elsewhere = support.appendingPathComponent("invented-clients.json")
        try Data(#"{"clients":[]}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: registry, withDestinationURL: elsewhere)
        #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(support) }
        try FileManager.default.removeItem(at: registry)

        #expect(mkfifo(registry.path, 0o600) == 0)
        let started = Date()
        #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(support) }
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func theRegistryRoundTripsHashesAndScopesWithoutKeepingTokens() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-client-roundtrip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(try MCPClients.load(root).clients.isEmpty)
        var clients = MCPClients()
        let token = try clients.register(id: "invented-assistant", name: "Invented Assistant", binders: ["/Invented/Binder": "read"], now: now)
        try clients.save(root)
        let stored = try MCPClients.load(root)
        let record = try #require(stored.authenticate(clientID: "invented-assistant", token: token))
        #expect(record.level(for: URL(fileURLWithPath: "/Invented/Binder")) == "read")
        #expect(!record.readsDocuments)
        #expect(!(try String(contentsOf: MCPClients.url(root), encoding: .utf8)).contains(token))
        clients.revoke(id: "invented-assistant")
        try clients.save(root)
        #expect(try MCPClients.load(root).authenticate(clientID: "invented-assistant", token: token) == nil)
    }

    @Test func malformedStateAndInvalidParentsAreNeverTreatedAsEmpty() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-client-damaged-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try AtomicFile.makePrivateFolder(root.appendingPathComponent("mcp"))
        try Data("not JSON".utf8).write(to: MCPClients.url(root))
        #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(root) }
        try FileManager.default.removeItem(at: root.appendingPathComponent("mcp"))
        try Data("invented damaged parent".utf8).write(to: root.appendingPathComponent("mcp"))
        #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(root) }
    }

    @Test func invalidIDsAndDuplicateActiveClientsAreRefused() throws {
        var clients = MCPClients()
        for id in ["", "UPPERCASE", "../escape", String(repeating: "a", count: 42)] {
            #expect(throws: MCPClients.Failure.self) { try clients.register(id: id, name: "Invented", binders: [:]) }
        }
        _ = try clients.register(id: "invented", name: "Invented", binders: [:])
        #expect(throws: MCPClients.Failure.self) { try clients.register(id: "invented", name: "Invented", binders: [:]) }
    }

    @Test func anOversizedSaveKeepsTheReadableRegistry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-client-size-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var clients = MCPClients()
        let token = try clients.register(id: "invented", name: "Invented", binders: [:])
        try clients.save(root)
        let before = try Data(contentsOf: MCPClients.url(root))
        clients.clients[0].name = String(repeating: "i", count: MCPClients.maximumBytes)
        #expect(throws: MCPClients.Failure.self) { try clients.save(root) }
        #expect(try Data(contentsOf: MCPClients.url(root)) == before)
        #expect(try MCPClients.load(root).authenticate(clientID: "invented", token: token) != nil)
    }

    @Test func reRegistrationNeverRevivesTheOldTokenAndKeepsDocumentPermission() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-client-reregister-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var clients = MCPClients()
        let old = try clients.register(id: "invented", name: "Invented", binders: [:], now: now)
        clients.revoke(id: "invented")
        let current = try clients.register(id: "invented", name: "Invented", binders: [:], documents: true, now: now)
        try clients.save(root)
        let reloaded = try MCPClients.load(root)
        #expect(reloaded.authenticate(clientID: "invented", token: old) == nil)
        let active = try #require(reloaded.authenticate(clientID: "invented", token: current))
        #expect(active.readsDocuments)
        #expect(active.level(for: URL(fileURLWithPath: "/Invented/Unlisted")) == nil)
    }

    @Test(arguments: [false, true]) func linkedStateDirectoriesAreNeverReadOrWritten(linkSupport: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-client-parent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("support")
        let outside = root.appendingPathComponent("outside")
        try MCPClients().save(outside)
        if linkSupport {
            try FileManager.default.createSymbolicLink(at: support, withDestinationURL: outside)
        } else {
            try AtomicFile.makePrivateFolder(support)
            try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("mcp"),
                                                       withDestinationURL: outside.appendingPathComponent("mcp"))
        }
        let before = try Data(contentsOf: MCPClients.url(outside))
        var clients = MCPClients()
        _ = try clients.register(id: "invented", name: "Invented", binders: [:])
        #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(support) }
        #expect(throws: MCPClients.Unreadable.self) { try clients.save(support) }
        #expect(try Data(contentsOf: MCPClients.url(outside)) == before)
        try FileManager.default.removeItem(at: outside)
        #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(support) }
        #expect(throws: MCPClients.Unreadable.self) { try clients.save(support) }
        #expect(!FileManager.default.fileExists(atPath: outside.path))
    }

    @Test(arguments: [false, true]) func replacingAValidatedDirectoryNeverRedirectsRegistryIO(writing: Bool) throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("sprava-client-swap-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let support = base.appendingPathComponent("support"), outside = base.appendingPathComponent("outside")
        try MCPClients().save(support)
        var foreign = MCPClients()
        _ = try foreign.register(id: "invented-outside", name: "Invented Outside", binders: [:])
        try foreign.save(outside)
        let before = try Data(contentsOf: MCPClients.url(outside))
        let original = try Data(contentsOf: MCPClients.url(support))
        let moved = base.appendingPathComponent("moved")
        let swap = {
            try FileManager.default.moveItem(at: support.appendingPathComponent("mcp"), to: moved)
            try FileManager.default.createSymbolicLink(at: support.appendingPathComponent("mcp"),
                                                       withDestinationURL: outside.appendingPathComponent("mcp"))
        }
        if writing {
            #expect(throws: (any Error).self) { try MCPClients().save(support, beforeFile: swap) }
        } else {
            #expect(throws: MCPClients.Unreadable.self) { try MCPClients.load(support, beforeFile: swap) }
        }
        #expect(try Data(contentsOf: MCPClients.url(outside)) == before)
        #expect(try Data(contentsOf: moved.appendingPathComponent("clients.json")) == original)
    }
}

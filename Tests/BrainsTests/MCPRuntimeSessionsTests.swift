import BinderStore
@testable import Brains
import Darwin
import Foundation
import SpravaKit
import Testing

@Test func runtimeMCPIdentityIsBoundToOneBinderAndNeverLoadedFromARegisteredRecord() throws {
    let sessions = try MCPRuntimeSessions(maximumSessions: 2)
    let sessionID = UUID()
    let folder = URL(fileURLWithPath: "/invented/runtime-binder")
    let credentials = try sessions.register(sessionID: sessionID, binderID: "invented-canonical-id", folder: folder)
    let auth = try #require(sessions.authenticate(clientID: credentials.clientID, token: credentials.token))
    #expect(auth.identity.sessionID == sessionID)
    #expect(auth.identity.binderID == "invented-canonical-id")
    #expect(auth.client.binders == [folder.path: "read"])
    #expect(auth.client.readsDocuments == false)
    #expect(credentials.description == "<MCP runtime credentials>")
    #expect(credentials.debugDescription == credentials.description)
    #expect(sessions.authenticate(clientID: credentials.clientID, token: "invented-wrong-token") == nil)
    let support = FileManager.default.temporaryDirectory.appendingPathComponent("invented-unused-\(UUID())")
    let commands = Commands(support: support, deviceID: "invented-device")
    let runtime = MCPServer(session: auth, commands: commands, shelf: { [] },
                            sessionReady: { sessions.isActive(auth) })
    #expect(runtime.runtimeSession == auth.identity)
    let registered = MCPServer(client: auth.client, commands: commands, shelf: { [] })
    // Even a persisted clone of every public record field cannot create a runtime role.
    _ = registered.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"role":"back-office","binder_id":"other","session_id":"forged"}}"#)
    #expect(registered.runtimeSession == nil)
}

@Test func runtimeMCPCapacityReplacementAndRevocationNeverRetainAnOldSessionToken() throws {
    #expect(throws: MCPRuntimeSessions.Failure.invalidLimits) { _ = try MCPRuntimeSessions(maximumSessions: 0) }
    let sessions = try MCPRuntimeSessions(maximumSessions: 1)
    let session = UUID(), folder = URL(fileURLWithPath: "/invented/session-binder")
    let first = try sessions.register(sessionID: session, binderID: "invented-first", folder: folder)
    let snapshot = try #require(sessions.authenticate(clientID: first.clientID, token: first.token))
    #expect(throws: MCPRuntimeSessions.Failure.capacity) {
        _ = try sessions.register(sessionID: UUID(), binderID: "invented-other", folder: folder)
    }
    #expect(throws: MCPRuntimeSessions.Failure.invalidScope) {
        _ = try sessions.register(sessionID: session, binderID: "/invented/path", folder: folder)
    }
    #expect(sessions.isCurrent(snapshot))
    #expect(sessions.isActive(snapshot) == false)
    #expect(sessions.activate(sessionID: session, clientID: first.clientID))
    #expect(sessions.isActive(snapshot))
    let replacement = try sessions.register(sessionID: session, binderID: "invented-second", folder: folder)
    #expect(sessions.isCurrent(snapshot) == false)
    #expect(sessions.authenticate(clientID: first.clientID, token: first.token) == nil)
    let current = try #require(sessions.authenticate(clientID: replacement.clientID, token: replacement.token))
    #expect(current.identity.binderID == "invented-second")
    #expect(sessions.isActive(current) == false)
    #expect(sessions.activate(sessionID: session, clientID: first.clientID) == false)
    #expect(sessions.suspend(sessionID: session, clientID: first.clientID) == false)
    #expect(sessions.isActive(current) == false)
    #expect(sessions.activate(sessionID: session, clientID: replacement.clientID))
    #expect(sessions.isActive(current))
    #expect(sessions.revoke(sessionID: session))
    #expect(sessions.isCurrent(current) == false)
    #expect(sessions.isActive(current) == false)
    _ = try sessions.register(sessionID: UUID(), binderID: "invented-last", folder: folder)
    sessions.revokeAll()
    _ = try sessions.register(sessionID: UUID(), binderID: "invented-after-reset", folder: folder)
}

@Suite(.serialized) struct MCPRuntimeSessionSocketTests {
    @Test func runtimeSessionsIgnoreAnUnreadableRegistryAndRevokeLiveConnectionsWithoutFallback() throws {
        let helper = MCPSocketTests()
        let support = helper.support()
        defer { try? FileManager.default.removeItem(at: support) }
        let sessions = try MCPRuntimeSessions(maximumSessions: 1)
        let queue = DispatchQueue(label: "invented.mcp.runtime.sessions")
        let reads = MCPSocketTests.Lines()
        let listener = MCPListener(support: support, commands: Commands(support: support, deviceID: "invented-device"),
                                   queue: queue, shelf: { reads.append("shelf"); return [] }, runtimeSessions: sessions, log: { _ in })
        try listener.start(); defer { listener.stop() }
        // Session authentication must not consult or repair the registered clients' state.
        try Data("invented malformed registry".utf8).write(to: MCPClients.url(support))
        let session = UUID()
        let credentials = try sessions.register(sessionID: session, binderID: "invented-binder-id",
                                                folder: URL(fileURLWithPath: "/invented/session-folder"))
        let snapshot = try #require(sessions.authenticate(clientID: credentials.clientID, token: credentials.token))
        let (fd, reply) = try helper.authenticate(listener, id: credentials.clientID, token: credentials.token)
        defer { close(fd) }
        #expect(reply == #"{"sprava_auth":{"ok":true}}"#)
        helper.send(fd, #"{"jsonrpc":"2.0","id":1,"method":"ping"}"#)
        let reader = LineReader(fd: fd)
        guard case .line(let ping) = reader.next(limit: 4096) else { Issue.record("runtime ping failed"); return }
        #expect(try JSONParser.parse(ping).value["id"] == .int(1))
        #expect(try String(contentsOf: MCPClients.url(support), encoding: .utf8) == "invented malformed registry")
        // Startup handshakes and static tool discovery work, but no binder read reaches the shelf
        // until the runtime activates this credential. Stop suspends it without reconnecting.
        helper.send(fd, #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"}}}"#)
        guard case .line(let tools) = reader.next(limit: MCPListener.lineLimit) else { Issue.record("tool discovery failed"); return }
        #expect(try JSONParser.parse(tools).value["result"]?["tools"]?.arrayValue?.isEmpty == false)
        let request = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28"},"name":"list_binders","arguments":{}}}"#
        helper.send(fd, request)
        guard case .line(let pending) = reader.next(limit: 4096) else { Issue.record("pending refusal missing"); return }
        #expect(try JSONParser.parse(pending).value["result"]?["isError"] == .bool(true))
        #expect(reads.all.isEmpty)
        #expect(queue.sync { sessions.activate(sessionID: session, clientID: credentials.clientID) })
        helper.send(fd, request)
        guard case .line(let active) = reader.next(limit: 4096) else { Issue.record("active tool failed"); return }
        #expect(try JSONParser.parse(active).value["result"]?["isError"] == .bool(false))
        #expect(reads.all.count == 1)
        #expect(queue.sync { sessions.suspend(sessionID: session, clientID: credentials.clientID) })
        helper.send(fd, request)
        guard case .line(let suspended) = reader.next(limit: 4096) else { Issue.record("suspended refusal missing"); return }
        #expect(try JSONParser.parse(suspended).value["result"]?["isError"] == .bool(true))
        #expect(reads.all.count == 1)
        #expect(queue.sync { sessions.activate(sessionID: session, clientID: credentials.clientID) })
        helper.send(fd, request)
        guard case .line = reader.next(limit: 4096) else { Issue.record("reactivation failed"); return }
        #expect(reads.all.count == 2)
        // A persisted clone must not rescue an already-authenticated runtime connection after revocation.
        var clone = MCPClients(); clone.clients = [snapshot.client]; try clone.save(support)
        queue.sync { _ = sessions.revoke(sessionID: session) }
        helper.send(fd, #"{"jsonrpc":"2.0","id":2,"method":"ping"}"#)
        guard case .end = reader.next(limit: 4096) else { Issue.record("revoked runtime connection remained open"); return }
        let (registeredFD, registeredReply) = try helper.authenticate(listener, id: credentials.clientID, token: credentials.token)
        defer { close(registeredFD) }
        #expect(registeredReply == #"{"sprava_auth":{"ok":true}}"#)
        // This new connection is an ordinary registered client; no session authority is available.
        #expect(sessions.authenticate(clientID: credentials.clientID, token: credentials.token) == nil)
    }
}

import Foundation
import SpravaKit

/// Runtime-attested identity, never decoded from MCP arguments or the registered-client state file.
public struct MCPSessionIdentity: Sendable, Equatable {
    public let sessionID: UUID
    public let binderID: String
    package init(sessionID: UUID, binderID: String) { self.sessionID = sessionID; self.binderID = binderID }
}

/// conversation §11.1: a token exists for one runtime session and one binder, then is revoked at exit.
/// Consent and canonical binder resolution precede minting. New tokens can handshake but tools stay closed
/// until the runtime activates this exact credential after startup checks and current-turn admission.
/// This does NOT widen disclosure, grant intake access or authorize direct writes: those adapters are separate.
/// Suspend on Stop/between turns; revoke on exit/offload/removal. Drain the listener's command queue before
/// crossing a binder barrier; suspension cannot undo a call already executing on that queue.
public final class MCPRuntimeSessions: @unchecked Sendable {
    public enum Failure: Error, Sendable, Equatable { case invalidLimits, invalidScope, capacity }
    public struct Credentials: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
        public let clientID: String
        public let token: String
        public var description: String { "<MCP runtime credentials>" }
        public var debugDescription: String { description }
        fileprivate init(clientID: String, token: String) { self.clientID = clientID; self.token = token }
    }
    package struct Authenticated: Sendable, Equatable {
        let identity: MCPSessionIdentity
        let client: MCPClientRecord
    }
    private let lock = NSLock()
    private let maximumSessions: Int
    private var bySession: [UUID: Authenticated] = [:]
    private var byClient: [String: UUID] = [:]
    private var active: Set<String> = []

    public init(maximumSessions: Int) throws {
        guard (1...128).contains(maximumSessions) else { throw Failure.invalidLimits }
        self.maximumSessions = maximumSessions
    }

    /// Canonical identity is supplied by its owner, NOT derived from a folder/name/Services binder id.
    /// Replacing a session invalidates its old token and every old connection before the next dispatch.
    /// Only the hash is retained here; the raw token is returned once for the engine's shim environment.
    public func register(sessionID: UUID, binderID: String, folder: URL, now: Date = Date()) throws -> Credentials {
        guard !binderID.isEmpty, binderID.utf8.count <= 1024,
              !binderID.contains("/"), !binderID.contains("\\"),
              !binderID.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              folder.isFileURL, folder.query == nil, folder.fragment == nil,
              folder.host == nil || folder.host == "localhost" else { throw Failure.invalidScope }
        return try lock.withLock {
            guard bySession[sessionID] != nil || bySession.count < maximumSessions else { throw Failure.capacity }
            let id = "session-" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
            let token = MCPClients.newToken()
            let client = MCPClientRecord(id: id, name: "Runtime session", tokenSHA256: MCPClients.hash(token),
                                         binders: [folder.standardizedFileURL.path: "read"],
                                         createdAt: ISOTime.string(now), revoked: false)
            let entry = Authenticated(identity: .init(sessionID: sessionID, binderID: binderID), client: client)
            if let old = bySession[sessionID] {
                byClient.removeValue(forKey: old.client.id); active.remove(old.client.id)
            }
            bySession[sessionID] = entry; byClient[id] = sessionID
            return Credentials(clientID: id, token: token)
        }
    }

    /// The runtime, never an MCP request, admits a validated session for the current turn. Checking the
    /// client id prevents a delayed startup callback from activating a replacement credential.
    @discardableResult public func activate(sessionID: UUID, clientID: String) -> Bool {
        lock.withLock {
            guard bySession[sessionID]?.client.id == clientID else { return false }
            active.insert(clientID); return true
        }
    }

    /// Closes tool admission while preserving the authenticated connection for a later turn.
    @discardableResult public func suspend(sessionID: UUID, clientID: String) -> Bool {
        lock.withLock {
            guard bySession[sessionID]?.client.id == clientID else { return false }
            active.remove(clientID); return true
        }
    }

    @discardableResult public func revoke(sessionID: UUID) -> Bool {
        lock.withLock {
            guard let old = bySession.removeValue(forKey: sessionID) else { return false }
            byClient.removeValue(forKey: old.client.id); active.remove(old.client.id); return true
        }
    }
    public func revokeAll() { lock.withLock { bySession.removeAll(); byClient.removeAll(); active.removeAll() } }

    package func authenticate(clientID: String, token: String) -> Authenticated? {
        guard clientID.utf8.count == 40, token.utf8.count == 74 else { return nil }
        let given = Data(MCPClients.hash(token).utf8)
        return lock.withLock {
            guard let session = byClient[clientID], let entry = bySession[session] else { return nil }
            let stored = Data(entry.client.tokenSHA256.utf8)
            guard stored.count == given.count,
                  zip(stored, given).reduce(UInt8(0), { $0 | ($1.0 ^ $1.1) }) == 0 else { return nil }
            return entry
        }
    }
    package func isActive(_ snapshot: Authenticated) -> Bool {
        lock.withLock { bySession[snapshot.identity.sessionID] == snapshot && active.contains(snapshot.client.id) }
    }
    package func isCurrent(_ snapshot: Authenticated) -> Bool {
        lock.withLock { bySession[snapshot.identity.sessionID] == snapshot }
    }
}

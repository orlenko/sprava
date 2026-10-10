import CryptoKit
import Darwin
import Foundation
import SpravaKit

/// Registered brains (architecture 7.5): `mcp/clients.json` in Sprava's own state. A record holds no secret,
/// only the SHA-256 of the client's token. Sealing records with the runtime key is deferred in the MVP.
public struct MCPClientRecord: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var tokenSHA256: String
    /// Binder folder path -> "read" or "propose".
    public var binders: [String: String]
    public var createdAt: String
    public var revoked: Bool
    /// May read the full text of intake documents waiting for a careful reading (adaptation-layer §4.4).
    public var documents: Bool?

    package init(id: String, name: String, tokenSHA256: String, binders: [String: String], createdAt: String, revoked: Bool,
                 documents: Bool? = nil) {
        self.id = id
        self.name = name
        self.tokenSHA256 = tokenSHA256
        self.binders = binders
        self.createdAt = createdAt
        self.revoked = revoked
        self.documents = documents
    }

    public var readsDocuments: Bool { documents == true }

    public func level(for folder: URL) -> String? { binders[folder.standardizedFileURL.path] }
}

public struct MCPClients: Codable, Sendable {
    static let maximumBytes = 16 * 1024 * 1024
    public var clients: [MCPClientRecord] = []

    public init() {}

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    public static func url(_ support: URL) -> URL { support.appendingPathComponent("mcp/clients.json") }

    public struct Unreadable: Error, CustomStringConvertible {
        public let path: String
        public var description: String { "the brain client registry cannot be read; it was left as it is" }
    }

    /// The registry. Only a file that is not there is an empty registry; one that exists but cannot be read or
    /// decoded, or whose lookup fails, throws, so a command never saves over the other clients' records. This runs
    /// on the shared MCP command queue, so it also refuses links and special files without ever blocking on them.
    public static func load(_ support: URL) throws -> MCPClients {
        let file = url(support)
        let data: Data
        switch SafeFile.read(file, limit: maximumBytes) {
        case .missing:
            // ENOTDIR also maps to missing. Only a genuinely absent final entry is a fresh registry; a bad parent
            // must not be interpreted as permission to replace it later.
            var info = stat()
            guard lstat(file.path, &info) != 0, errno == ENOENT else { throw Unreadable(path: file.path) }
            return MCPClients()
        case .ok(let read): data = read
        case .refused, .unreadable: throw Unreadable(path: file.path)
        }
        guard let clients = try? JSONDecoder().decode(MCPClients.self, from: data) else { throw Unreadable(path: file.path) }
        return clients
    }

    public func save(_ support: URL) throws {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try e.encode(self)
        guard data.count <= Self.maximumBytes else {
            throw Failure(message: "the brain client registry is too large; its saved records were left as they are")
        }
        try AtomicFile.makePrivateFolder(Self.url(support).deletingLastPathComponent())
        try AtomicFile.write(data, to: Self.url(support))
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A new token: the fixed prefix `sprava_ct_` and 32 random bytes in hex, so scanners recognize it. The bytes
    /// come from `arc4random_buf`, which cannot fail: a source whose failure went unnoticed would leave every byte
    /// zero, and every such client would get the same token.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return token(bytes)
    }

    /// The token for 32 bytes.
    static func token(_ bytes: [UInt8]) -> String {
        precondition(bytes.count == 32)
        return "sprava_ct_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Registers a client and returns its token, shown once.
    public mutating func register(id: String, name: String, binders: [String: String], documents: Bool = false, now: Date = Date()) throws -> String {
        guard id.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,40}$/) != nil else { throw Failure(message: "client id: lowercase letters, digits and hyphens") }
        guard !clients.contains(where: { $0.id == id && !$0.revoked }) else { throw Failure(message: "client \(id) exists") }
        let token = Self.newToken()
        clients.append(MCPClientRecord(id: id, name: name, tokenSHA256: Self.hash(token), binders: binders,
                                       createdAt: ISOTime.string(now), revoked: false, documents: documents ? true : nil))
        return token
    }

    public mutating func revoke(id: String) {
        for i in clients.indices where clients[i].id == id { clients[i].revoked = true }
    }

    /// The client a token belongs to, compared in constant time.
    public func authenticate(clientID: String, token: String) -> MCPClientRecord? {
        let given = Data(Self.hash(token).utf8)
        return clients.first { c in
            guard c.id == clientID, !c.revoked else { return false }
            let stored = Data(c.tokenSHA256.utf8)
            guard stored.count == given.count else { return false }
            return zip(stored, given).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
        }
    }
}

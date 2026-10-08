import CryptoKit
import Foundation

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

    public var readsDocuments: Bool { documents == true }

    public func level(for folder: URL) -> String? { binders[folder.standardizedFileURL.path] }
}

public struct MCPClients: Codable, Sendable {
    public var clients: [MCPClientRecord] = []

    public init() {}

    public static func url(_ support: URL) -> URL { support.appendingPathComponent("mcp/clients.json") }

    public static func load(_ support: URL) -> MCPClients {
        (try? Data(contentsOf: url(support))).flatMap { try? JSONDecoder().decode(MCPClients.self, from: $0) } ?? MCPClients()
    }

    public func save(_ support: URL) throws {
        try AtomicFile.makePrivateFolder(Self.url(support).deletingLastPathComponent())
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try AtomicFile.write(try e.encode(self), to: Self.url(support))
    }

    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A new token: the fixed prefix `sprava_ct_` and 32 random bytes in hex, so scanners recognize it.
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return "sprava_ct_" + bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Registers a client and returns its token, shown once.
    public mutating func register(id: String, name: String, binders: [String: String], documents: Bool = false, now: Date = Date()) throws -> String {
        guard id.wholeMatch(of: /^[a-z0-9][a-z0-9-]{0,40}$/) != nil else { throw Commands.Failure(message: "client id: lowercase letters, digits and hyphens") }
        guard !clients.contains(where: { $0.id == id && !$0.revoked }) else { throw Commands.Failure(message: "client \(id) exists") }
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

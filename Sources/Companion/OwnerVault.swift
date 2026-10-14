import CryptoKit
import Foundation
import SpravaKit

public enum CompanionCredentialError: Error, Equatable { case invalid, unavailable }

/// No default backend: tests and development must explicitly supply isolated storage.
public protocol CompanionCredentialStorage: Sendable {
    func read(account: String) throws -> Data?
    /// Immutable insertion: false means another writer already installed this account.
    func insert(account: String, bytes: Data) throws -> Bool
    /// Idempotent deletion; unavailable storage throws and must remain scheduled for cleanup.
    func remove(account: String) throws
}
public extension CompanionCredentialStorage {
    func remove(account: String) throws { throw CompanionCredentialError.unavailable }
}

public struct CompanionRelayIdentity: Sendable {
    public let origin: String
    public let instance: String
    public init(origin: String, instance: String) throws {
        guard Self.validOrigin(origin), instance.utf8.count == 32,
              instance.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CompanionCredentialError.invalid
        }
        self.origin = origin; self.instance = instance
    }
    // companion-v0 §5.1: an origin only, HTTPS except literal localhost in development.
    static func validOrigin(_ text: String) -> Bool {
        guard text.utf8.count <= 2048, text.utf8.allSatisfy({ (33...126).contains($0) }),
              let c = URLComponents(string: text), let host = c.host, !host.isEmpty,
              c.user == nil, c.password == nil, c.query == nil, c.fragment == nil, c.path.isEmpty,
              c.scheme == "https" || (c.scheme == "http" && host == "localhost"),
              host == host.lowercased(), !text.contains("%"), !text.contains("\\") else { return false }
        if let port = c.port {
            guard (0...65535).contains(port), port != (c.scheme == "https" ? 443 : 80) else { return false }
        }
        let authority = host + (c.port.map { ":\($0)" } ?? "")
        return text == "\(c.scheme!)://\(authority)"
    }
    /// Neither addresses nor credentials appear in Keychain item names or labels.
    var account: String {
        let digest = SHA256.hash(data: Data(origin.utf8)).map { String(format: "%02x", $0) }.joined()
        return "owner-v0:\(digest):\(instance)"
    }
}

/// The immutable claim identity; later rotation and publication state have separate owners.
public struct CompanionOwnerCredentials {
    public let relay: CompanionRelayIdentity
    public let ownerToken: String
    public let signingKey: Curve25519.Signing.PrivateKey
    /// Includes the setup code: keep only in the vault and the bounded claim request, never in logs or SQLite.
    public let claimBody: Data
}

/// companion-v0 §6: persist before any claim request; every retry uses these exact stored credentials.
public struct CompanionOwnerVault: Sendable {
    private let backend: any CompanionCredentialStorage
    public init(backend: any CompanionCredentialStorage) { self.backend = backend }

    public func load(_ relay: CompanionRelayIdentity) throws -> CompanionOwnerCredentials? {
        guard let bytes = try backend.read(account: relay.account) else { return nil }
        return try decode(bytes, relay: relay)
    }

    public func prepare(_ relay: CompanionRelayIdentity, setupCode: String) throws -> CompanionOwnerCredentials {
        guard Self.validSetupCode(setupCode) else { throw CompanionCredentialError.invalid }
        if let existing = try load(relay) { return existing }
        let tokenBytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        let token = CompanionWire.base64(tokenBytes), signing = Curve25519.Signing.PrivateKey()
        let bytes = Self.encode(relay, token, signing.rawRepresentation, setupCode)
        // No update: a parallel creator must use the winning identity, never replace it after a claim.
        _ = try backend.insert(account: relay.account, bytes: bytes)
        guard let stored = try load(relay) else { throw CompanionCredentialError.unavailable }
        return stored
    }

    static func validSetupCode(_ text: String) -> Bool {
        text.utf8.count == 44 && Data(base64Encoded: text)?.count == 32 &&
            Data(base64Encoded: text)?.base64EncodedString() == text
    }
    private static func encode(_ relay: CompanionRelayIdentity, _ token: String, _ signing: Data, _ setup: String) -> Data {
        Data(JSONWriter.compact(.object(JSONObject([
            ("v", .number(JSONNumber(text: "0"))), ("origin", .string(relay.origin)), ("instance", .string(relay.instance)),
            ("token", .string(token)), ("signing", .string(CompanionWire.base64(signing))), ("setup", .string(setup)),
            ("claim", .string(CompanionWire.base64(claimBody(token, setup))))
        ]))).utf8)
    }
    private static func claimBody(_ token: String, _ setup: String) -> Data {
        let hash = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        return Data(JSONWriter.compact(.object(JSONObject([
            ("setup_code", .string(setup)), ("owner_token_sha256", .string(hash))
        ]))).utf8)
    }
    private func decode(_ bytes: Data, relay: CompanionRelayIdentity) throws -> CompanionOwnerCredentials {
        do {
            let value = try CompanionWire.parse(bytes, limit: 4096)
            guard value.objectValue != nil, CompanionWire.unsigned(value["v"]) == 0,
                  value["origin"]?.stringValue == relay.origin, value["instance"]?.stringValue == relay.instance,
                  let token = value["token"]?.stringValue, token.utf8.count == 43, try CompanionWire.decode(token).count == 32,
                  let signing = value["signing"]?.stringValue, let setup = value["setup"]?.stringValue,
                  let claim = value["claim"]?.stringValue,
                  Self.validSetupCode(setup) else { throw CompanionCredentialError.invalid }
            let keyBytes = try CompanionWire.decode(signing)
            guard keyBytes.count == 32 else { throw CompanionCredentialError.invalid }
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: keyBytes)
            let body = try CompanionWire.decode(claim)
            guard body == Self.claimBody(token, setup) else { throw CompanionCredentialError.invalid }
            return CompanionOwnerCredentials(relay: relay, ownerToken: token, signingKey: key, claimBody: body)
        } catch { throw CompanionCredentialError.invalid }
    }
}

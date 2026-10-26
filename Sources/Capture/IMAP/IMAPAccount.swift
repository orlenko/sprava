import Foundation
import SpravaKit

/// One IMAP account: where it lives and who signs in (integrations.md 2.6: set up once, named by binders).
/// Its password is never part of this value; `IMAPPasswords` keeps it.
public struct IMAPAccount: Codable, Sendable, Hashable {
    public enum Security: String, Codable, Sendable, CaseIterable { case tls, startTLS = "starttls" }
    public let host: String
    public let port: Int
    public let security: Security
    /// The SHA-256 of a self-signed certificate the person trusted, hex. Only for this Mac's own bridge.
    public let pin: String?
    public let user: String

    public init?(host: String, port: Int, security: Security, pin: String? = nil, user: String = "") {
        let host = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard Self.validHost(host), (1...65_535).contains(port), user.utf8.count <= 1_024,
              !user.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        if let pin {
            guard Self.isLoopback(host), pin.utf8.count == 64, pin.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        }
        self.host = host; self.port = port; self.security = security; self.pin = pin; self.user = user
    }

    /// The same server, with someone signing in.
    public func signing(in user: String) -> IMAPAccount? { IMAPAccount(host: host, port: port, security: security, pin: pin, user: user) }

    /// The ports to try, in order, when the person names only a host. A local bridge (Proton Mail Bridge) listens on 1143.
    public static func candidates(host: String) -> [(Security, Int)] {
        isLoopback(host.trimmingCharacters(in: .whitespaces).lowercased())
            ? [(.startTLS, 1143), (.tls, 1993), (.tls, 993), (.startTLS, 143)]
            : [(.tls, 993), (.startTLS, 143)]
    }

    public var isLoopback: Bool { Self.isLoopback(host) }

    /// The Keychain account name: host, port and user together, so one sign-in serves every binder that names it.
    var key: String { JSONWriter.compact(.array([.str(host), .int(port), .str(user)])) }

    static func isLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "::1" || host == "127.0.0.1" || (host.hasPrefix("127.") && host.split(separator: ".").count == 4)
    }

    static func validHost(_ host: String) -> Bool {
        !host.isEmpty && host.utf8.count <= 253 && !host.hasPrefix("-") && !host.hasPrefix(".")
            && host.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "." || $0 == "-" || $0 == ":" }
    }

    // A stored value is checked the same way as a new one.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = IMAPAccount(host: try c.decode(String.self, forKey: .host), port: try c.decode(Int.self, forKey: .port),
                                      security: try c.decode(Security.self, forKey: .security), pin: try c.decodeIfPresent(String.self, forKey: .pin),
                                      user: try c.decode(String.self, forKey: .user)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid IMAP account"))
        }
        self = value
    }
}

import Darwin
import Foundation
import Network

/// What the proxy accepts before a byte reaches a host (conversation.md 18.3.1): the request, the name in one form, the
/// vendor's hosts, where the name leads, and where the TLS goes. Each is a pure function, so tests reach it without a network.
extension AgentEgressProxy {
    /// The vendor's own domains. Only a model host, asked for by the agent, passes; nothing under them ever becomes a prompt.
    static let vendorDomains = ["anthropic.com", "claude.ai", "claude.com"]
    /// Names that lead into the person's own network or this Mac, refused whatever they resolve to.
    static let localDomains = ["localhost", "local", "internal", "home.arpa"]

    /// The host of a `CONNECT` to port 443, in its one form, or nil.
    static func host(of head: Data) -> String? {
        guard let line = String(data: head, encoding: .utf8)?.split(separator: "\r\n", omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "CONNECT", parts[2].hasPrefix("HTTP/1."), parts[1].hasSuffix(":443") else { return nil }
        return canonical(String(parts[1].dropLast(4)))
    }

    /// One form for every check, list and summary: lower-case letters, digits and hyphens in two or more non-empty labels
    /// (so no trailing dot), an international name only as `xn--`, at most 253 bytes, a last label that is not all digits
    /// (so no IPv4 address in any spelling), and nothing under a local domain.
    static func canonical(_ raw: String) -> String? {
        let name = raw.lowercased()
        guard (1...253).contains(name.utf8.count) else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, !last.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else { return nil }
        for label in labels {
            guard (1...63).contains(label.utf8.count), label.first != "-", label.last != "-",
                  label.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39) || $0 == 0x2D }) else { return nil }
        }
        guard !localDomains.contains(where: { within(name, $0) }) else { return nil }
        return name
    }

    /// Whether `host` is `domain` or a name under it, label by label.
    static func within(_ host: String, _ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }

    static func isVendor(_ host: String) -> Bool { vendorDomains.contains { within(host, $0) } }

    // MARK: - Where the name leads

    /// Ordinary public IPv4 unicast: none of the special-purpose blocks, nothing from 224/4 up.
    static func isPublic(ipv4 a: [UInt8]) -> Bool {
        guard a.count == 4 else { return false }
        switch (a[0], a[1], a[2]) {
        case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _), (192, 0, 0), (192, 0, 2), (192, 88, 99),
             (198, 51, 100), (203, 0, 113): return false
        case (100, 64...127, _), (172, 16...31, _), (198, 18...19, _): return false
        default: return a[0] < 224
        }
    }

    /// Global IPv6 unicast (`2000::/3`) less its special-purpose blocks, so mapped, unique-local, site-local and link-local
    /// addresses are refused. A NAT64 address (`64:ff9b::/96`) is judged by the IPv4 address inside it.
    static func isPublic(ipv6 a: [UInt8]) -> Bool {
        guard a.count == 16 else { return false }
        if a[0..<12].elementsEqual([0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0]) { return isPublic(ipv4: Array(a[12..<16])) }
        guard a[0] & 0xE0 == 0x20 else { return false }
        if a[0] == 0x20, a[1] == 0x01, a[2] & 0xFE == 0 { return false } // 2001::/23
        if a[0] == 0x20, a[1] == 0x01, a[2] == 0x0d, a[3] == 0xb8 { return false } // 2001:db8::/32
        if a[0] == 0x20, a[1] == 0x02 { return false } // 2002::/16
        if a[0] == 0x3f, a[1] == 0xff, a[2] & 0xF0 == 0 { return false } // 3fff::/20
        return true
    }

    /// The host's addresses when every one is public, else nil: one private answer among public ones refuses the name, so a
    /// site cannot point it at the person's router or at a service on this Mac. The proxy connects only to these.
    static func publicAddresses(of host: String) -> [NWEndpoint.Host]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_ADDRCONFIG
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &list) == 0, let list else { return nil }
        defer { freeaddrinfo(list) }
        var found: [NWEndpoint.Host] = []
        for entry in sequence(first: list, next: { $0.pointee.ai_next }) {
            guard let address = entry.pointee.ai_addr else { continue }
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let bytes = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin_addr) { Array($0) } }
                guard isPublic(ipv4: bytes), let ip = IPv4Address(Data(bytes)) else { return nil }
                found.append(.ipv4(ip))
            case AF_INET6:
                let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { withUnsafeBytes(of: $0.pointee.sin6_addr) { Array($0) } }
                guard isPublic(ipv6: bytes), let ip = IPv6Address(Data(bytes)) else { return nil }
                found.append(.ipv6(ip))
            default: return nil
            }
        }
        var seen = Set<NWEndpoint.Host>()
        let unique = found.filter { seen.insert($0).inserted }
        return unique.isEmpty ? nil : unique
    }

    // MARK: - Where the TLS goes

    enum Hello: Equatable { case incomplete, name(String), refused }

    /// The longest first record a client may send before its name is known.
    static let helloLimit = 5 + 16_384

    /// The server name of a client's first TLS record. A record that is not one whole ClientHello, a hello with no name or
    /// more than one, or one asking for encrypted client hello is refused: otherwise a command could `CONNECT` to an allowed
    /// host and name another site served from the same addresses.
    static func serverName(inHello data: Data) -> Hello {
        let b = [UInt8](data.prefix(helloLimit))
        guard b.count >= 5 else { return b.isEmpty || b[0] == 0x16 ? .incomplete : .refused }
        guard b[0] == 0x16, b[1] == 0x03 else { return .refused }
        let length = Int(b[3]) << 8 | Int(b[4])
        guard length >= 4, length <= 16_384 else { return .refused }
        guard b.count >= 5 + length else { return .incomplete }
        var r = Reader(bytes: Array(b[5..<(5 + length)]))
        guard r.u8() == 0x01, let body = r.u24(), body == r.remaining else { return .refused } // one whole ClientHello, unsplit
        guard r.skip(2 + 32), let session = r.u8(), r.skip(Int(session)), let suites = r.u16(), r.skip(suites),
              let methods = r.u8(), r.skip(Int(methods)), let total = r.u16(), total == r.remaining else { return .refused }
        var name: String?
        while r.remaining > 0 {
            guard let kind = r.u16(), let size = r.u16(), var field = r.sub(size) else { return .refused }
            switch kind {
            case 0xfe0d: return .refused // encrypted client hello
            case 0x0000:
                guard name == nil, let list = field.u16(), list == field.remaining, field.u8() == 0, let count = field.u16(),
                      count == field.remaining, let bytes = field.sub(count), let text = String(bytes: bytes.bytes, encoding: .ascii) else { return .refused }
                name = text
            default: break
            }
        }
        return name.map { .name($0.lowercased()) } ?? .refused
    }

    struct Reader {
        var bytes: [UInt8], at = 0
        var remaining: Int { bytes.count - at }
        mutating func u8() -> UInt8? { guard remaining >= 1 else { return nil }; at += 1; return bytes[at - 1] }
        mutating func u16() -> Int? { guard remaining >= 2 else { return nil }; at += 2; return Int(bytes[at - 2]) << 8 | Int(bytes[at - 1]) }
        mutating func u24() -> Int? { guard let high = u8(), let low = u16() else { return nil }; return Int(high) << 16 | low }
        mutating func skip(_ count: Int) -> Bool { guard count >= 0, remaining >= count else { return false }; at += count; return true }
        mutating func sub(_ count: Int) -> Reader? {
            guard count >= 0, remaining >= count else { return nil }
            at += count; return Reader(bytes: Array(bytes[(at - count)..<at]))
        }
    }
}

import Darwin
import Foundation
import Network
import Testing
@testable import Brains

/// What the agent's proxy accepts before a byte reaches a host (conversation.md 18.3.1). Every name is invented; on the wire
/// a local listener stands in for each host.
@Suite struct AgentEgressRulesTests {
    /// A gate that never asks, over a fixed list.
    static func gate(_ listed: @escaping @Sendable (String, AgentEgressProxy.Caller) -> Bool) -> AgentSiteGate {
        AgentSiteGate(asks: false, listed: listed, remember: { _, _ in false })
    }

    @Test func aHostHasOneFormAndLocalNamesHaveNone() {
        #expect(AgentEgressProxy.canonical("Docs.Example-Invoicing.test") == "docs.example-invoicing.test")
        #expect(AgentEgressProxy.canonical("xn--bcher-kva.example") == "xn--bcher-kva.example")
        for refused in ["docs.example.test.", ".example.test", "docs..example.test", "example", "127.1", "10.0.0.1", "0x7f.1",
                        "[::1]", "::1", "localhost", "printer.local", "nas.home.arpa", "db.internal", "a.localhost", "-a.example.test",
                        "a-.example.test", "a_b.example.test", "bücher.example", "a b.example.test",
                        String(repeating: "a", count: 64) + ".example.test", String(repeating: "a.", count: 127) + "test"] {
            #expect(AgentEgressProxy.canonical(refused) == nil, "\(refused)")
        }
    }

    @Test func theModelHostIsTheAgentsAloneAndTheVendorsOtherHostsNobodys() throws {
        let proxy = try AgentEgressProxy(); defer { proxy.stop() }
        func admits(_ host: String, _ caller: AgentEgressProxy.Caller, _ gate: AgentSiteGate?) -> Bool {
            final class Box: @unchecked Sendable { var allowed: Bool? }
            let box = Box(), done = DispatchSemaphore(value: 0)
            proxy.admit(host, caller, gate: gate) { allowed, _ in box.allowed = allowed; done.signal() }
            _ = done.wait(timeout: .now() + 5)
            return box.allowed == true
        }
        let everything = Self.gate { _, _ in true }
        #expect(admits("api.anthropic.com", .agent, everything))
        #expect(!admits("api.anthropic.com", .command, everything))
        for vendor in ["anthropic.com", "statsig.anthropic.com", "claude.ai", "x.claude.com"] {
            #expect(!admits(vendor, .agent, everything), "\(vendor)")
            #expect(!admits(vendor, .command, everything), "\(vendor)")
        }
        // A name that only ends in the same letters is not the vendor's.
        #expect(admits("notanthropic.com", .command, everything))
        #expect(!admits("docs.example.test", .agent, nil))
        #expect(!admits("docs.example.test", .agent, Self.gate { _, _ in false }))
        let forReading = Self.gate { host, caller in host == "docs.example.test" && caller == .agent }
        #expect(admits("docs.example.test", .agent, forReading))
        #expect(!admits("docs.example.test", .command, forReading))
    }

    @Test func onlyOrdinaryPublicAddressesAreReached() {
        func v4(_ text: String) -> Bool { AgentEgressProxy.isPublic(ipv4: [UInt8](IPv4Address(text)!.rawValue)) }
        func v6(_ text: String) -> Bool { AgentEgressProxy.isPublic(ipv6: [UInt8](IPv6Address(text)!.rawValue)) }
        for open in ["8.8.8.8", "1.1.1.1", "100.63.255.255", "100.128.0.1", "172.15.0.1", "172.32.0.1", "198.17.0.1", "223.255.255.255"] {
            #expect(v4(open), "\(open)")
        }
        for closed in ["0.0.0.0", "0.1.2.3", "10.1.2.3", "100.64.0.1", "127.0.0.1", "169.254.1.1", "172.16.0.1", "172.31.255.255",
                       "192.0.0.8", "192.0.2.1", "192.88.99.1", "192.168.1.1", "198.18.0.1", "198.19.255.255", "198.51.100.1",
                       "203.0.113.1", "224.0.0.1", "240.0.0.1", "255.255.255.255"] {
            #expect(!v4(closed), "\(closed)")
        }
        for open in ["2606:4700::1111", "2a00:1450::1", "2001:4860::8888", "64:ff9b::808:808"] { #expect(v6(open), "\(open)") }
        for closed in ["::1", "::", "::ffff:8.8.8.8", "::ffff:127.0.0.1", "fe80::1", "fc00::1", "fd12::1", "fec0::1", "ff02::1",
                       "2001::1", "2001:1::1", "2001:db8::1", "2002:c0a8:101::1", "3fff::1", "64:ff9b::7f00:1", "64:ff9b::a00:1",
                       "64:ff9b:1::808:808", "100::1"] {
            #expect(!v6(closed), "\(closed)")
        }
        #expect(AgentEgressProxy.publicAddresses(of: "localhost") == nil)
    }

    /// A ClientHello as clients send it: one record, with the extensions asked for.
    static func hello(names: [String] = ["docs.example.test"], ech: Bool = false, split: Bool = false) -> Data {
        func u16(_ n: Int) -> [UInt8] { [UInt8(n >> 8), UInt8(n & 0xff)] }
        var extensions: [UInt8] = []
        if !names.isEmpty {
            var list: [UInt8] = []
            for name in names { list += [0] + u16(name.utf8.count) + Array(name.utf8) }
            let field = u16(list.count) + list
            extensions += u16(0x0000) + u16(field.count) + field
        }
        extensions += u16(0x002b) + u16(3) + [2, 0x03, 0x04]
        if ech { extensions += u16(0xfe0d) + u16(4) + [0, 1, 2, 3] }
        let body: [UInt8] = [0x03, 0x03] + [UInt8](repeating: 7, count: 32) + [0] + u16(2) + [0x13, 0x01] + [1, 0] + u16(extensions.count) + extensions
        let handshake: [UInt8] = [0x01, 0, UInt8(body.count >> 8), UInt8(body.count & 0xff)] + body
        if split {
            let half = handshake.count / 2
            return Data([0x16, 0x03, 0x01] + u16(half) + handshake[..<half] + [0x16, 0x03, 0x01] + u16(handshake.count - half) + handshake[half...])
        }
        return Data([0x16, 0x03, 0x01] + u16(handshake.count) + handshake)
    }

    @Test func theHelloMustNameOneHostInTheClear() {
        #expect(AgentEgressProxy.serverName(inHello: Self.hello()) == .name("docs.example.test"))
        #expect(AgentEgressProxy.serverName(inHello: Self.hello(names: ["Docs.Example.test"])) == .name("docs.example.test"))
        #expect(AgentEgressProxy.serverName(inHello: Self.hello().prefix(40)) == .incomplete)
        #expect(AgentEgressProxy.serverName(inHello: Data([0x16, 0x03])) == .incomplete)
        #expect(AgentEgressProxy.serverName(inHello: Self.hello(names: [])) == .refused)
        #expect(AgentEgressProxy.serverName(inHello: Self.hello(names: ["a.example.test", "b.example.test"])) == .refused)
        #expect(AgentEgressProxy.serverName(inHello: Self.hello(ech: true)) == .refused)
        #expect(AgentEgressProxy.serverName(inHello: Self.hello(split: true)) == .refused)
        #expect(AgentEgressProxy.serverName(inHello: Data("GET / HTTP/1.1\r\n\r\n".utf8)) == .refused)
    }

    /// A local listener standing in for a host, which keeps what it is sent.
    final class Upstream: @unchecked Sendable {
        let listener: NWListener, lock = NSLock()
        var received = Data()
        init() throws {
            listener = try NWListener(using: .tcp)
            listener.newConnectionHandler = { [unowned self] connection in
                connection.start(queue: .global()); self.read(connection)
            }
            let ready = DispatchSemaphore(value: 0)
            listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
            listener.start(queue: .global())
            _ = ready.wait(timeout: .now() + 5)
        }
        var port: UInt16 { listener.port?.rawValue ?? 0 }
        var got: Data { lock.withLock { received } }
        private func read(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, _ in
                guard let self else { return }
                if let data { self.lock.withLock { self.received.append(data) } }
                if !done { self.read(connection) }
            }
        }
        func waitFor(_ count: Int) -> Bool {
            for _ in 0..<100 { if got.count >= count { return true }; usleep(20_000) }
            return false
        }
    }

    /// A CONNECT from this process, then `hello` once the proxy answers; the status line.
    func tunnel(_ proxy: AgentEgressProxy, host: String, hello: Data) throws -> String {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0); defer { close(socket) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(socket, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in(); address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_port = proxy.port.bigEndian
        let joined = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        try #require(joined == 0)
        let request = "CONNECT \(host):443 HTTP/1.1\r\nHost: \(host)\r\n\r\n"
        _ = request.withCString { write(socket, $0, strlen($0)) }
        var buffer = [UInt8](repeating: 0, count: 256)
        let got = read(socket, &buffer, 256)
        let status = got > 0 ? String(decoding: buffer.prefix(got), as: UTF8.self).components(separatedBy: "\r\n")[0] : ""
        if status.contains("200") {
            _ = hello.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
            usleep(300_000)
        }
        return status
    }

    @Test func aTunnelCarriesOnlyAHelloNamingItsOwnHost() throws {
        let upstream = try Upstream(); defer { upstream.listener.cancel() }
        let proxy = try AgentEgressProxy(allowed: ["model.example.test"], upstreamPort: upstream.port, resolve: { _ in [.ipv4(.loopback)] })
        defer { proxy.stop() }
        proxy.authorize(getpid())
        // A hello naming another site behind the same addresses goes nowhere.
        #expect(try tunnel(proxy, host: "model.example.test", hello: Self.hello(names: ["other.example.test"])).contains("200"))
        #expect(try tunnel(proxy, host: "model.example.test", hello: Self.hello(ech: true, split: false)).contains("200"))
        #expect(upstream.got.isEmpty)
        let good = Self.hello(names: ["model.example.test"])
        #expect(try tunnel(proxy, host: "model.example.test", hello: good).contains("200"))
        #expect(upstream.waitFor(good.count))
        #expect(upstream.got == good)
    }

    @Test func aNameLeadingNowherePublicIsRefused() throws {
        let proxy = try AgentEgressProxy(allowed: ["model.example.test"], resolve: { _ in nil }); defer { proxy.stop() }
        proxy.authorize(getpid())
        #expect(try tunnel(proxy, host: "model.example.test", hello: Self.hello()).contains("403"))
    }

    @Test func aCommandInTheAgentsSandboxReachesTheBindersSitesAndNeverTheModel() throws {
        let upstream = try Upstream(); defer { upstream.listener.cancel() }
        let proxy = try AgentEgressProxy(allowed: ["model.example.test"], upstreamPort: upstream.port, resolve: { _ in [.ipv4(.loopback)] })
        defer { proxy.stop() }
        let f = try ClaudeBinderToolsTests.Fixture(proxyPort: proxy.port); defer { f.clean() }
        func status(_ host: String) throws -> String {
            let out = f.binder.appendingPathComponent("connect-\(UUID().uuidString).txt")
            _ = try f.allowed("curl -sS -m 3 --proxy http://127.0.0.1:\(proxy.port) https://\(host)/ -o /dev/null -w '%{http_connect}' > '\(out.path)' || true")
            return (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        }
        let sites = Self.gate { host, caller in host == "site.example.test" && caller == .command }
        // Another session's agent: this sandbox's command is nobody's.
        proxy.authorize(getpid(), session: UUID(), gate: sites)
        #expect(try status("site.example.test") == "403")
        proxy.authorize(getpid(), session: f.session, gate: sites)
        #expect(try status("site.example.test") == "200")
        #expect(upstream.waitFor(1))
        // Counted for the summary: the hello at least went out.
        #expect(sites.uses.contains { $0.host == "site.example.test" && $0.caller == .command && $0.connections == 1 && $0.sent > 0 })
        #expect(try status("model.example.test") == "403")
        #expect(try status("other.example.test") == "403")
    }
}

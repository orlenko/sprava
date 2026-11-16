import Darwin
import Foundation
import Network

/// The only way out of a binder agent's sandbox: its profile allows outbound connections to this loopback port alone, so
/// a shell command, a script or a steered model reaches only what the proxy lets through (conversation.md 18.3.1). Requests
/// are HTTPS `CONNECT`s; past the ClientHello's server name, the bytes pass through unread.
///
/// A host alone is not enough: with someone else's API key, a command could upload a binder's document to that person's
/// account on the model's own host. So the kernel says which process holds the other end of each connection: the agent
/// process itself may reach the model hosts, a command in the agent's sandbox only the binder's sites, and anything else
/// nothing. The proxy offers no tool that makes a request of its own.
package final class AgentEgressProxy: @unchecked Sendable {
    package static let modelHosts: Set<String> = ["api.anthropic.com"]
    /// Who holds a connection: the agent process, or a command it ran, inside its session's sandbox.
    package enum Caller: Sendable, Equatable { case agent, command }

    private let allowed: Set<String>
    private let upstreamPort: UInt16
    private let resolve: @Sendable (String) -> [NWEndpoint.Host]?
    private let lock = NSLock()
    private var agent: (pid: pid_t, session: UUID?, gate: AgentSiteGate?)?
    private let queue = DispatchQueue(label: "sprava.agent-egress")
    private let listener: NWListener
    package private(set) var port: UInt16 = 0

    /// Starts listening on a free loopback port, and returns once it has one. `resolve` returns a host's addresses only when
    /// every one is public; tests point invented names at a local listener through it.
    package init(allowed: Set<String> = AgentEgressProxy.modelHosts, upstreamPort: UInt16 = 443,
                 resolve: @escaping @Sendable (String) -> [NWEndpoint.Host]? = AgentEgressProxy.publicAddresses(of:)) throws {
        self.allowed = allowed; self.upstreamPort = upstreamPort; self.resolve = resolve
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable { var failed = false }
        let box = Box()
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case .failed: box.failed = true; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, !box.failed, let port = listener.port?.rawValue else {
            listener.cancel()
            throw ClaudeReadLaunch.Refused.invalidInput
        }
        self.port = port
    }

    package func stop() { listener.cancel() }

    /// The one agent that may use the proxy from now on, the session whose sandbox holds its commands, and the turn's gate
    /// to the binder's sites. The runtime runs one conversation with tools at a time. Without a session, its commands are
    /// never found; without a gate, no site is reached.
    package func authorize(_ pid: pid_t, session: UUID? = nil, gate: AgentSiteGate? = nil) {
        lock.withLock { agent = (pid, session, gate) }
    }

    /// The turn's gate for the agent `pid`, once the runtime has made it; a later agent's gate is never replaced.
    package func use(_ gate: AgentSiteGate, for pid: pid_t) {
        lock.withLock { if agent?.pid == pid { agent?.gate = gate } }
    }

    /// Whether `pid` holds the local end of a TCP connection from `port`.
    static func holdsConnection(_ pid: pid_t, fromPort port: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var files = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 16)
        let got = files.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return false }
        for file in files.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where file.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let wanted = Int32(MemoryLayout<socket_fdinfo>.size)
            guard proc_pidfdinfo(pid, file.proc_fd, PROC_PIDFDSOCKETINFO, &info, wanted) == wanted,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            if UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport)) == port { return true }
        }
        return false
    }

    /// Who holds the client's end, with the turn's gate, or nil: the agent itself, else a process in its session's sandbox.
    private func caller(of client: NWConnection) -> (Caller, AgentSiteGate?)? {
        guard case .hostPort(_, let port) = client.endpoint, let agent = lock.withLock({ agent }) else { return nil }
        if Self.holdsConnection(agent.pid, fromPort: port.rawValue) { return (.agent, agent.gate) }
        guard let session = agent.session else { return nil }
        let command = AgentContainment.running(session: session).contains { $0 != agent.pid && Self.holdsConnection($0, fromPort: port.rawValue) }
        return command ? (.command, agent.gate) : nil
    }

    /// Whether `caller` may reach `host`: a model host for the agent alone, nothing else of the vendor's, and the binder's
    /// sites as the turn's gate decides, perhaps after asking the person. `done` gets the gate's counter for a site.
    func admit(_ host: String, _ caller: Caller, gate: AgentSiteGate?, _ done: @escaping @Sendable (Bool, AgentSiteGate?) -> Void) {
        if allowed.contains(host) { done(caller == .agent, nil); return }
        guard !Self.isVendor(host), let gate else { done(false, nil); return }
        gate.decide(host, caller) { done($0, gate) }
    }

    /// One per runtime: every binder's agent shares the same wall, told which agent and session it serves.
    package static func shared() throws -> AgentEgressProxy { try sharedResult.get() }
    private static let sharedResult = Result { try AgentEgressProxy() }

    private func accept(_ client: NWConnection) {
        client.start(queue: queue)
        readRequest(client, Data())
    }

    private func readRequest(_ client: NWConnection, _ soFar: Data) {
        client.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, done, error in
            guard let self else { client.cancel(); return }
            var request = soFar
            if let data { request.append(data) }
            if let end = request.range(of: Data("\r\n\r\n".utf8)) {
                self.answer(client, head: request[request.startIndex..<end.lowerBound], rest: Data(request[end.upperBound...]))
            } else if done || error != nil || request.count > 8192 {
                client.cancel()
            } else {
                self.readRequest(client, request)
            }
        }
    }

    private func refuse(_ client: NWConnection) {
        client.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in client.cancel() })
    }

    private func answer(_ client: NWConnection, head: Data, rest: Data) {
        guard let host = Self.host(of: head), let (caller, gate) = caller(of: client) else { refuse(client); return }
        admit(host, caller, gate: gate) { [weak self] allowed, counter in
            guard let self else { client.cancel(); return }
            self.queue.async {
                guard allowed else { self.refuse(client); return }
                var count: Count?
                if let counter { count = { sent, received in counter.count(host, caller, sent: sent, received: received) } }
                self.reach(client, host: host, rest: rest, count: count)
            }
        }
    }

    typealias Count = @Sendable (_ sent: Int, _ received: Int) -> Void

    private func reach(_ client: NWConnection, host: String, rest: Data, count: Count?) {
        let resolve = self.resolve
        // A name lookup can take seconds; it never holds up another connection.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let addresses = resolve(host)
            guard let self else { client.cancel(); return }
            self.queue.async {
                guard let addresses, !addresses.isEmpty else { self.refuse(client); return }
                self.open(client, host: host, addresses: addresses[...], rest: rest, count: count)
            }
        }
    }

    /// Connects to the checked addresses in turn, then lets the client speak, and passes its hello on only if it names `host`.
    private func open(_ client: NWConnection, host: String, addresses: ArraySlice<NWEndpoint.Host>, rest: Data, count: Count?) {
        guard let address = addresses.first, let port = NWEndpoint.Port(rawValue: upstreamPort) else { client.cancel(); return }
        let server = NWConnection(host: address, port: port, using: .tcp)
        final class Phase: @unchecked Sendable { var ready = false }
        let phase = Phase()
        server.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready where !phase.ready:
                phase.ready = true
                client.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    self?.passHello(client, to: server, host: host, rest, count: count)
                })
            case .waiting where !phase.ready, .failed where !phase.ready:
                server.stateUpdateHandler = nil; server.cancel()
                self?.open(client, host: host, addresses: addresses.dropFirst(), rest: rest, count: count)
            case .failed, .cancelled:
                client.cancel()
            default: break
            }
        }
        client.stateUpdateHandler = { state in
            switch state {
            case .failed, .cancelled: server.cancel()
            default: break
            }
        }
        server.start(queue: queue)
    }

    private func passHello(_ client: NWConnection, to server: NWConnection, host: String, _ soFar: Data, count: Count?) {
        switch Self.serverName(inHello: soFar) {
        case .name(let name) where name == host:
            server.send(content: soFar, completion: .contentProcessed { [weak self] sent in
                guard sent == nil else { client.cancel(); server.cancel(); return }
                count?(soFar.count, 0)
                self?.pipe(client, to: server) { count?($0, 0) }; self?.pipe(server, to: client) { count?(0, $0) }
            })
        case .incomplete where soFar.count < Self.helloLimit:
            client.receive(minimumIncompleteLength: 1, maximumLength: Self.helloLimit - soFar.count) { [weak self] data, _, done, error in
                guard let self, let data, !data.isEmpty, error == nil else { client.cancel(); server.cancel(); return }
                if done { client.cancel(); server.cancel(); return }
                self.passHello(client, to: server, host: host, soFar + data, count: count)
            }
        default:
            client.cancel(); server.cancel()
        }
    }

    private func pipe(_ from: NWConnection, to: NWConnection, passed: @escaping @Sendable (Int) -> Void = { _ in }) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            if let data, !data.isEmpty {
                passed(data.count)
                to.send(content: data, completion: .contentProcessed { sent in
                    if sent != nil { from.cancel(); to.cancel() } else if !done && error == nil { self?.pipe(from, to: to, passed: passed) } else { from.cancel(); to.cancel() }
                })
            } else if done || error != nil {
                from.cancel(); to.cancel()
            } else {
                self?.pipe(from, to: to, passed: passed)
            }
        }
    }
}

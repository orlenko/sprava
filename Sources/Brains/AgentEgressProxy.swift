import Foundation
import Network

/// The only way out of a binder agent's sandbox: its profile allows outbound connections to this loopback port alone, so
/// a shell command, a script or a steered model reaches only the hosts named here (conversation.md 18.3). Requests are
/// HTTPS `CONNECT`s; the bytes pass through unread. Web access with its per-domain prompt comes later on this same wall.
package final class AgentEgressProxy: @unchecked Sendable {
    package static let modelHosts: Set<String> = ["api.anthropic.com"]
    private let allowed: Set<String>
    private let queue = DispatchQueue(label: "sprava.agent-egress")
    private let listener: NWListener
    package private(set) var port: UInt16 = 0

    /// Starts listening on a free loopback port, and returns once it has one.
    package init(allowed: Set<String> = AgentEgressProxy.modelHosts) throws {
        self.allowed = allowed
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

    /// One per runtime: every binder's agent shares the same wall.
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
                self.answer(client, head: request[request.startIndex..<end.lowerBound])
            } else if done || error != nil || request.count > 8192 {
                client.cancel()
            } else {
                self.readRequest(client, request)
            }
        }
    }

    /// The host a request may reach, or nil: a `CONNECT` to port 443 of an allowed host, exactly.
    static func target(of head: Data, allowed: Set<String>) -> String? {
        guard let line = String(data: head, encoding: .utf8)?.split(separator: "\r\n", omittingEmptySubsequences: false).first else { return nil }
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "CONNECT", parts[2].hasPrefix("HTTP/1.") else { return nil }
        let host = parts[1].lowercased()
        guard host.hasSuffix(":443") else { return nil }
        let name = String(host.dropLast(4))
        return allowed.contains(name) ? name : nil
    }

    private func answer(_ client: NWConnection, head: Data) {
        guard let host = Self.target(of: head, allowed: allowed) else {
            client.send(content: Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), completion: .contentProcessed { _ in client.cancel() })
            return
        }
        let server = NWConnection(host: .init(host), port: 443, using: .tcp)
        server.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                client.send(content: Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8), completion: .contentProcessed { _ in
                    self?.pipe(client, to: server); self?.pipe(server, to: client)
                })
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

    private func pipe(_ from: NWConnection, to: NWConnection) {
        from.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, done, error in
            if let data, !data.isEmpty {
                to.send(content: data, completion: .contentProcessed { sent in
                    if sent != nil { from.cancel(); to.cancel() } else if !done && error == nil { self?.pipe(from, to: to) } else { from.cancel(); to.cancel() }
                })
            } else if done || error != nil {
                from.cancel(); to.cancel()
            } else {
                self?.pipe(from, to: to)
            }
        }
    }
}

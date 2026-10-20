import BinderStore
import Darwin
import Foundation
import Shelf
import SpravaKit

/// Line framing over a socket file descriptor, with a byte limit per line.
public final class LineReader {
    let fd: Int32
    var buffer: [UInt8] = []
    /// When set, reading past this moment reports a timeout however the bytes arrive.
    public var deadline: Date? {
        didSet {
            deadlineUptime = deadline.map { ProcessInfo.processInfo.systemUptime + max(0, $0.timeIntervalSinceNow) }
        }
    }
    private var deadlineUptime: TimeInterval?

    public init(fd: Int32) { self.fd = fd }

    public enum Outcome { case line(String), end, tooLong, timeout }

    public func next(limit: Int) -> Outcome {
        while true {
            if let deadlineUptime, ProcessInfo.processInfo.systemUptime >= deadlineUptime { return .timeout }
            if let nl = buffer.firstIndex(of: 0x0A) {
                // A whole line that arrived in one read is held to the limit too.
                if nl > limit { return .tooLong }
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                return .line(line)
            }
            if buffer.count > limit { return .tooLong }
            if let deadlineUptime {
                let remaining = deadlineUptime - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { return .timeout }
                var ready = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let result = poll(&ready, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
                if result == 0 { continue }
                if result < 0, errno == EINTR { continue }
                guard result > 0, ready.revents & Int16(POLLIN | POLLHUP) != 0 else { return .end }
            }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let n = read(fd, &chunk, chunk.count)
            if n == 0 { return .end }
            if n < 0 {
                if errno == EINTR { continue }
                return errno == EAGAIN || errno == EWOULDBLOCK ? .timeout : .end
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }
}

public func writeLine(_ fd: Int32, _ text: String) -> Bool {
    let bytes = Array((text + "\n").utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
        if n < 0 { if errno == EINTR { continue }; return false }
        offset += n
    }
    return true
}

/// A timeout for each read (or, with `SO_SNDTIMEO`, each write) on a socket; zero waits forever.
package func setTimeout(_ fd: Int32, seconds: TimeInterval, option: Int32 = SO_RCVTIMEO) {
    let whole = seconds.rounded(.down)
    var tv = timeval(tv_sec: Int(whole), tv_usec: Int32((seconds - whole) * 1_000_000))
    setsockopt(fd, SOL_SOCKET, option, &tv, socklen_t(MemoryLayout<timeval>.size))
}

func unixAddress(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }   // 104 bytes on macOS
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
        for (i, b) in bytes.enumerated() { raw[i] = b }
        raw[bytes.count] = 0
    }
    return addr
}

/// The runtime's MCP listener (architecture 7.2): a Unix socket, mode 0600 in a 0700 folder; the peer must be
/// this user; one preamble line authenticates a registered client; then newline-delimited JSON-RPC.
public final class MCPListener: @unchecked Sendable {
    public let socketURL: URL
    let support: URL
    private let runtimeSessions: MCPRuntimeSessions?
    let commands: Commands
    let shelf: @Sendable () -> [ShelfRow]
    let queue: DispatchQueue
    let log: @Sendable (String) -> Void
    let limits: Limits
    var fd: Int32 = -1
    /// The accept call; a test swaps it to fail the way a process out of descriptors does.
    package var acceptCall: @Sendable (Int32) -> Int32 = { Darwin.accept($0, nil, nil) }
    private let lock = NSLock()
    private var unauthenticated = 0
    private var authenticated: [String: Int] = [:]

    public static let preambleLimit = 4096
    public static let lineLimit = 4 * 1024 * 1024

    /// Every connection holds a thread and a descriptor in the runtime, so each is counted for its whole life and a
    /// peer that stops sending or reading is closed: a client that connects again and again cannot exhaust either.
    public struct Limits: Sendable {
        /// Connections that have not authenticated yet.
        public var unauthenticated = 8
        /// Authenticated connections, of all clients together and of one client.
        public var authenticated = 32
        public var perClient = 8
        /// The whole preamble, however its bytes arrive.
        public var preamble: TimeInterval = 5
        /// An authenticated connection whose peer sends nothing for this long is closed; its shim exits, as when the
        /// runtime restarts.
        public var idle: TimeInterval = 3600
        /// A reply the peer does not read for this long ends the connection.
        public var write: TimeInterval = 30

        public init() {}
    }

    public init(support: URL, commands: Commands, queue: DispatchQueue, shelf: @escaping @Sendable () -> [ShelfRow],
                limits: Limits = Limits(), runtimeSessions: MCPRuntimeSessions? = nil,
                log: @escaping @Sendable (String) -> Void) {
        self.support = support
        self.runtimeSessions = runtimeSessions
        socketURL = support.appendingPathComponent("mcp/mcp.sock")
        self.commands = commands
        self.queue = queue
        self.shelf = shelf
        self.limits = limits
        self.log = log
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Binds the socket. A stale socket file from a crash is removed first; the caller holds the runtime lease.
    public func start() throws {
        try AtomicFile.makePrivateFolder(socketURL.deletingLastPathComponent())
        guard chmod(socketURL.deletingLastPathComponent().path, 0o700) == 0 else { throw Failure(message: "chmod: \(errno)") }
        guard var addr = unixAddress(socketURL.path) else { throw Failure(message: "socket path longer than 103 bytes") }
        unlink(socketURL.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket: \(errno)") }
        // No umask here (it is process-wide): the 0700 folder keeps others out until the socket is chmod 0600 below.
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else { close(fd); throw Failure(message: "bind: \(errno)") }
        guard chmod(socketURL.path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(socketURL.path)
            throw Failure(message: "chmod: \(code)")
        }
        guard listen(fd, 16) == 0 else { close(fd); throw Failure(message: "listen: \(errno)") }
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "sprava.mcp.accept"
        thread.start()
    }

    public func stop() {
        if fd >= 0 { close(fd); fd = -1 }
        unlink(socketURL.path)
    }

    func acceptLoop() {
        var backoff: useconds_t = 0
        while fd >= 0 {
            let conn = acceptCall(fd)
            if conn < 0 {
                let code = errno
                if code == EINTR { continue }
                // Only a closed listener ends the loop. Anything else (no descriptor left in the process or the
                // system, a peer gone before its accept) passes: back off and go on, so later clients still connect.
                if fd < 0 || code == EBADF || code == EINVAL || code == ENOTSOCK { return }
                if backoff == 0 { log("mcp accept error=\(code)") }
                backoff = min(max(backoff * 2, 10_000), 1_000_000)
                usleep(backoff)
                continue
            }
            backoff = 0
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            setTimeout(conn, seconds: limits.write, option: SO_SNDTIMEO)
            lock.lock()
            let crowded = unauthenticated >= limits.unauthenticated
            if !crowded { unauthenticated += 1 }
            lock.unlock()
            if crowded { close(conn); continue }
            let thread = Thread { [weak self] in self?.serve(conn) }
            thread.name = "sprava.mcp.conn"
            thread.start()
        }
    }

    package func serve(_ conn: Int32) {
        defer { close(conn) }
        var counted = true
        func release() {
            if counted { lock.lock(); unauthenticated -= 1; lock.unlock(); counted = false }
        }
        defer { release() }
        // The peer must run as this user.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(conn, &uid, &gid) == 0, uid == getuid() else { return }
        setTimeout(conn, seconds: min(3, limits.preamble))
        let reader = LineReader(fd: conn)
        reader.deadline = Date().addingTimeInterval(limits.preamble)   // the whole preamble, not each read (a peer dripping bytes)
        guard case .line(let preamble) = reader.next(limit: Self.preambleLimit),
              let value = try? JSONParser.parse(preamble).value, let auth = value["sprava_auth"],
              let clientID = auth["client_id"]?.stringValue, let token = auth["token"]?.stringValue else {
            _ = writeLine(conn, #"{"sprava_auth":{"ok":false,"code":"bad_preamble"}}"#)
            return
        }
        // Runtime sessions live in memory and never require reading the registered clients' file.
        // A role/session field supplied by the peer grants no authority; only the token lookup does.
        let session = runtimeSessions?.authenticate(clientID: clientID, token: token)
        let registry = session == nil ? (try? MCPClients.load(support)) : nil
        guard let client = session?.client ?? registry?.authenticate(clientID: clientID, token: token) else {
            // The id came from the peer: it reaches the log only when it names a registered client, so no text a
            // peer chose is ever written there.
            let known = registry?.clients.first { $0.id == clientID }
            log("mcp \(known.map { "client=\($0.id) " } ?? "")auth=refused code=token_refused")
            _ = writeLine(conn, #"{"sprava_auth":{"ok":false,"code":"token_refused"}}"#)
            return
        }
        guard admit(client.id) else {
            log("mcp client=\(client.id) auth=refused code=busy")
            _ = writeLine(conn, #"{"sprava_auth":{"ok":false,"code":"busy"}}"#)
            return
        }
        defer { leave(client.id) }
        _ = writeLine(conn, #"{"sprava_auth":{"ok":true}}"#)
        reader.deadline = nil
        release()
        setTimeout(conn, seconds: limits.idle)
        log("mcp client=\(client.id) connected")
        let server: MCPServer
        if let session {
            let sessions = runtimeSessions
            server = MCPServer(session: session, commands: commands, shelf: shelf,
                               sessionReady: { sessions?.isActive(session) == true })
        }
        else { server = MCPServer(client: client, commands: commands, shelf: shelf) }
        while true {
            switch reader.next(limit: Self.lineLimit) {
            case .line(let line):
                // Revocation is immediate (architecture 7.5): the record is checked again before every call, on the
                // command queue just before dispatch, so a revocation queued ahead of the call is always seen.
                enum Gate { case revoked, changed, reply(String?) }
                let started = Date()
                let gate = queue.sync { () -> Gate in
                    if let session {
                        // Never fall back to a persisted client after this runtime lease was revoked/replaced.
                        guard runtimeSessions?.isCurrent(session) == true else { return .revoked }
                    } else {
                        guard let current = (try? MCPClients.load(support))?.clients.first(where: { $0.id == client.id && $0.tokenSHA256 == client.tokenSHA256 }),
                              !current.revoked else { return .revoked }
                        // Other changes to registered rights also end the old connection.
                        guard current == client else { return .changed }
                    }
                    return .reply(server.handle(line: line))
                }
                let reply: String
                switch gate {
                case .revoked:
                    log("mcp client=\(client.id) closed=revoked")
                    return
                case .changed:
                    log("mcp client=\(client.id) closed=changed")
                    return
                case .reply(nil):
                    continue
                case .reply(let r?):
                    reply = r
                }
                if !writeLine(conn, reply) { return }
                // Names, sizes and durations only, never content (architecture 3.7, 7.5): a method name the server
                // does not know is logged as unknown_method, so no text a client chose reaches the log.
                log("mcp client=\(client.id) method=\(MCPServer.loggedMethod(line)) bytes=\(reply.utf8.count) ms=\(Int(Date().timeIntervalSince(started) * 1000))")
            case .tooLong:
                log("mcp client=\(client.id) closed=line_too_long")
                return
            case .timeout:
                log("mcp client=\(client.id) closed=idle")
                return
            case .end:
                return
            }
        }
    }

    /// Takes one of the authenticated places, overall and the client's own, for the connection's whole life.
    func admit(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard authenticated.values.reduce(0, +) < limits.authenticated, authenticated[id, default: 0] < limits.perClient else { return false }
        authenticated[id, default: 0] += 1
        return true
    }

    func leave(_ id: String) {
        lock.lock()
        authenticated[id, default: 1] -= 1
        if authenticated[id] == 0 { authenticated[id] = nil }
        lock.unlock()
    }
}

/// The client side, used by the `sprava-mcp` shim.
public enum MCPShimConnection {
    /// The startup failure still frames the client's request with the normal 4 MiB limit (architecture 7.2).
    /// Oversized or malformed input gets no reply; the shim reports the startup error and exits nonzero.
    public static func failureReply(_ message: String, from fd: Int32, timeout: TimeInterval = 3) -> String? {
        guard timeout.isFinite, timeout >= 0 else { return nil }
        let reader = LineReader(fd: fd)
        reader.deadline = Date().addingTimeInterval(timeout)
        guard case .line(let line) = reader.next(limit: MCPListener.lineLimit),
              let value = try? JSONParser.parse(line).value, let id = value["id"] else { return nil }
        return JSONWriter.compact(.obj([("jsonrpc", .str("2.0")), ("id", id),
                                       ("error", .obj([("code", .int(-32000)), ("message", .string(message))]))]))
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var description: String { message }
    }

    public static func connect(socket path: String, clientID: String, token: String) -> Result<Int32, Failure> {
        guard var addr = unixAddress(path) else { return .failure(Failure("the Sprava socket path is too long")) }
        guard FileManager.default.fileExists(atPath: path) else { return .failure(Failure("the Sprava runtime is not running")) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(Failure("cannot create a socket")) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(fd); return .failure(Failure("the Sprava runtime is not answering")) }
        setTimeout(fd, seconds: 3)
        let preamble = JSONWriter.compact(.obj([("sprava_auth", .obj([("client_id", .string(clientID)), ("token", .string(token)),
                                                                     ("shim_version", .str("0.1.0"))]))]))
        guard writeLine(fd, preamble) else { close(fd); return .failure(Failure("the Sprava runtime is not answering")) }
        let reader = LineReader(fd: fd)
        guard case .line(let reply) = reader.next(limit: 4096), let value = try? JSONParser.parse(reply).value else {
            close(fd)
            return .failure(Failure("the Sprava runtime is not answering"))
        }
        guard value["sprava_auth"]?["ok"] == .bool(true) else {
            close(fd)
            if value["sprava_auth"]?["code"]?.stringValue == "busy" {
                return .failure(Failure("this client has too many Sprava connections open; close one and try again"))
            }
            return .failure(Failure("Sprava client token expired or revoked; renew it in Sprava"))
        }
        setTimeout(fd, seconds: 0)
        return .success(fd)
    }
}

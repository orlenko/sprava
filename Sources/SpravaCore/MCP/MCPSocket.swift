import Darwin
import Foundation

/// Line framing over a socket file descriptor, with a byte limit per line.
public final class LineReader {
    let fd: Int32
    var buffer: [UInt8] = []
    /// When set, reading past this moment reports a timeout however the bytes arrive.
    public var deadline: Date?

    public init(fd: Int32) { self.fd = fd }

    public enum Outcome { case line(String), end, tooLong, timeout }

    public func next(limit: Int) -> Outcome {
        while true {
            if let nl = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[..<nl], as: UTF8.self)
                buffer.removeSubrange(...nl)
                return .line(line)
            }
            if buffer.count > limit { return .tooLong }
            if let deadline, Date() > deadline { return .timeout }
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

func setTimeout(_ fd: Int32, seconds: Int) {
    var tv = timeval(tv_sec: seconds, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
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
    let commands: Commands
    let shelf: @Sendable () -> [ShelfRow]
    let queue: DispatchQueue
    let log: @Sendable (String) -> Void
    var fd: Int32 = -1
    private let lock = NSLock()
    private var unauthenticated = 0

    public static let preambleLimit = 4096
    public static let lineLimit = 4 * 1024 * 1024

    public init(support: URL, commands: Commands, queue: DispatchQueue, shelf: @escaping @Sendable () -> [ShelfRow],
                log: @escaping @Sendable (String) -> Void) {
        self.support = support
        socketURL = support.appendingPathComponent("mcp/mcp.sock")
        self.commands = commands
        self.queue = queue
        self.shelf = shelf
        self.log = log
    }

    public struct Failure: Error, CustomStringConvertible {
        public let message: String
        public var description: String { message }
    }

    /// Binds the socket. A stale socket file from a crash is removed first; the caller holds the runtime lease.
    public func start() throws {
        try AtomicFile.makePrivateFolder(socketURL.deletingLastPathComponent())
        chmod(socketURL.deletingLastPathComponent().path, 0o700)
        guard var addr = unixAddress(socketURL.path) else { throw Failure(message: "socket path longer than 103 bytes") }
        unlink(socketURL.path)
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(message: "socket: \(errno)") }
        let old = umask(0o177)
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        umask(old)
        guard bound == 0 else { close(fd); throw Failure(message: "bind: \(errno)") }
        chmod(socketURL.path, 0o600)
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
        while fd >= 0 {
            let conn = accept(fd, nil, nil)
            if conn < 0 { if errno == EINTR { continue }; return }
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.lock()
            let crowded = unauthenticated >= 8
            if !crowded { unauthenticated += 1 }
            lock.unlock()
            if crowded { close(conn); continue }
            let thread = Thread { [weak self] in self?.serve(conn) }
            thread.name = "sprava.mcp.conn"
            thread.start()
        }
    }

    func serve(_ conn: Int32) {
        defer { close(conn) }
        var counted = true
        func release() {
            if counted { lock.lock(); unauthenticated -= 1; lock.unlock(); counted = false }
        }
        defer { release() }
        // The peer must run as this user.
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(conn, &uid, &gid) == 0, uid == getuid() else { return }
        setTimeout(conn, seconds: 3)
        let reader = LineReader(fd: conn)
        reader.deadline = Date().addingTimeInterval(5)   // the whole preamble, not each read (a peer dripping bytes)
        guard case .line(let preamble) = reader.next(limit: Self.preambleLimit),
              let value = try? JSONParser.parse(preamble).value, let auth = value["sprava_auth"],
              let clientID = auth["client_id"]?.stringValue, let token = auth["token"]?.stringValue else {
            _ = writeLine(conn, #"{"sprava_auth":{"ok":false,"code":"bad_preamble"}}"#)
            return
        }
        // A registry that cannot be read authenticates no one.
        guard let client = (try? MCPClients.load(support))?.authenticate(clientID: clientID, token: token) else {
            _ = writeLine(conn, #"{"sprava_auth":{"ok":false,"code":"token_refused"}}"#)
            // The id came from the peer: only safe characters reach the log.
            log("mcp client=\(String(clientID.prefix(41).filter { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) })) auth=refused")
            return
        }
        _ = writeLine(conn, #"{"sprava_auth":{"ok":true}}"#)
        reader.deadline = nil
        release()
        setTimeout(conn, seconds: 0)
        log("mcp client=\(client.id) connected")
        let server = MCPServer(client: client, commands: commands, shelf: shelf)
        while true {
            switch reader.next(limit: Self.lineLimit) {
            case .line(let line):
                // Revocation is immediate (architecture 7.5): the record is checked again before every call, on the
                // command queue just before dispatch, so a revocation queued ahead of the call is always seen.
                enum Gate { case revoked, changed, reply(String?) }
                let started = Date()
                let gate = queue.sync { () -> Gate in
                    guard let current = (try? MCPClients.load(support))?.clients.first(where: { $0.id == client.id && $0.tokenSHA256 == client.tokenSHA256 }),
                          !current.revoked else { return .revoked }
                    // So is any other change to its rights (scope, documents): the connection ends, and the next one
                    // gets the new record.
                    guard current == client else { return .changed }
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
            case .end, .timeout:
                return
            }
        }
    }
}

/// The client side, used by the `sprava-mcp` shim.
public enum MCPShimConnection {
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
            return .failure(Failure("Sprava client token expired or revoked; renew it in Sprava"))
        }
        setTimeout(fd, seconds: 0)
        return .success(fd)
    }
}

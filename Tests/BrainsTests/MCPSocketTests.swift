import BinderStore
@testable import Brains
import Darwin
import Foundation
import SpravaKit
import Testing

/// The runtime's MCP listener over a real Unix socket in a temporary support folder (architecture 7.2): its
/// modes, the line limits, the preamble that authenticates a registered client, and a revocation that cuts the
/// connection at the next call. Invented clients only.
@Suite(.serialized) struct MCPSocketTests {
    /// Short, so the socket path stays under the 104-byte limit.
    func support() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sps-\(UUID().uuidString.prefix(8))")
    }

    func listener(_ support: URL, limits: MCPListener.Limits = .init(), log: Lines = Lines(),
                  configure: (MCPListener) -> Void = { _ in }) throws -> MCPListener {
        let listener = MCPListener(support: support, commands: Commands(support: support, deviceID: "t"),
                                   queue: DispatchQueue(label: "test.mcp.socket"), shelf: { [] }, limits: limits,
                                   log: { log.append($0) })
        configure(listener)
        try listener.start()
        return listener
    }

    /// The listener's log, as it was written.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.lock(); lines.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return lines }

        /// Waits up to two seconds for a line that contains `text`.
        func wait(for text: String) -> Bool {
            for _ in 0..<200 {
                if all.contains(where: { $0.contains(text) }) { return true }
                usleep(10_000)
            }
            return false
        }
    }

    /// Sends a preamble on a new connection and returns the answer's line, with the connection still open.
    func authenticate(_ listener: MCPListener, id: String, token: String) throws -> (Int32, String?) {
        let fd = try connect(listener)
        send(fd, #"{"sprava_auth":{"client_id":"\#(id)","token":"\#(token)"}}"#)
        guard case .line(let answer) = LineReader(fd: fd).next(limit: 4096) else { return (fd, nil) }
        return (fd, answer)
    }

    func connect(_ listener: MCPListener) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = try #require(unixAddress(listener.socketURL.path))
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        try #require(ok == 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    func send(_ fd: Int32, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress!, bytes.count) }
    }

    @Test func theSocketIsPrivateInAPrivateFolder() throws {
        let listener = try listener(support())
        defer { listener.stop() }
        var st = stat()
        #expect(lstat(listener.socketURL.path, &st) == 0)
        #expect(st.st_mode & S_IFMT == S_IFSOCK)
        #expect(st.st_mode & 0o777 == 0o600)
        #expect(lstat(listener.socketURL.deletingLastPathComponent().path, &st) == 0)
        #expect(st.st_mode & 0o777 == 0o700)
    }

    func reader(sending bytes: [UInt8]) throws -> (LineReader, [Int32]) {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        #expect(bytes.withUnsafeBytes { write(fds[1], $0.baseAddress!, bytes.count) } == bytes.count)
        return (LineReader(fd: fds[0]), fds)
    }

    @Test func aCompleteLineOverTheLimitIsTooLong() throws {
        let (over, a) = try reader(sending: [UInt8](repeating: 0x61, count: MCPListener.preambleLimit + 904) + [0x0A])
        defer { a.forEach { close($0) } }
        guard case .tooLong = over.next(limit: MCPListener.preambleLimit) else { Issue.record("a 5,000-byte line passed a 4,096-byte limit"); return }

        let (exact, b) = try reader(sending: [UInt8](repeating: 0x61, count: MCPListener.preambleLimit) + [0x0A])
        defer { b.forEach { close($0) } }
        guard case .line(let line) = exact.next(limit: MCPListener.preambleLimit) else { Issue.record("a line at the limit was refused"); return }
        #expect(line.utf8.count == MCPListener.preambleLimit)
    }

    @Test func aStartupFailureBoundsItsFirstRequestEvenWithoutANewline() throws {
        let dir = support()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard case .failure(let failure) = MCPShimConnection.connect(socket: dir.appendingPathComponent("absent.sock").path,
                                                                     clientID: "brain-1", token: "invented") else {
            Issue.record("connected to an absent runtime"); return
        }
        let input = dir.appendingPathComponent("input")
        try Data(repeating: 0x61, count: MCPListener.lineLimit + 1).write(to: input)
        let fd = open(input.path, O_RDONLY | O_CLOEXEC)
        defer { close(fd) }
        #expect(fd >= 0)
        #expect(MCPShimConnection.failureReply(failure.message, from: fd) == nil)
        // An ordinary request still receives the same startup error with its own id.
        try Data((#"{"jsonrpc":"2.0","id":7,"method":"initialize"}"# + "\n").utf8).write(to: input)
        let ordinary = open(input.path, O_RDONLY | O_CLOEXEC)
        defer { close(ordinary) }
        #expect(ordinary >= 0)
        let reply = try #require(MCPShimConnection.failureReply(failure.message, from: ordinary))
        let value = try JSONParser.parse(reply).value
        #expect(value["id"] == .int(7))
        #expect(value["error"]?["message"] == .str(failure.message))
    }

    @Test func aRegisteredClientTalksMCPAndARevokedOneIsCutOff() throws {
        let support = support()
        var clients = MCPClients()
        let token = try clients.register(id: "brain-1", name: "Invented brain", binders: [:])
        try clients.save(support)
        let listener = try listener(support)
        defer { listener.stop() }

        // A wrong token is refused before any MCP.
        let refused = try connect(listener)
        defer { close(refused) }
        send(refused, #"{"sprava_auth":{"client_id":"brain-1","token":"not-the-token"}}"#)
        guard case .line(let no) = LineReader(fd: refused).next(limit: 4096) else { Issue.record("no answer to a wrong token"); return }
        #expect(no.contains(#""ok":false"#) && no.contains("token_refused"))

        let fd = try connect(listener)
        defer { close(fd) }
        let reader = LineReader(fd: fd)
        send(fd, #"{"sprava_auth":{"client_id":"brain-1","token":"\#(token)"}}"#)
        guard case .line(let yes) = reader.next(limit: 4096) else { Issue.record("no answer to the preamble"); return }
        #expect(yes.contains(#""ok":true"#))
        let meta = #""_meta": {"io.modelcontextprotocol/protocolVersion": "2026-07-28", "io.modelcontextprotocol/clientCapabilities": {}}"#
        send(fd, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{\#(meta)}}"#)
        guard case .line(let listed) = reader.next(limit: MCPListener.lineLimit) else { Issue.record("no tools listed"); return }
        #expect(listed.contains("propose_ops"))

        // Revoked while connected: the next call ends the connection unanswered.
        var current = try MCPClients.load(support)
        current.revoke(id: "brain-1")
        try current.save(support)
        send(fd, #"{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{\#(meta)}}"#)
        guard case .end = reader.next(limit: MCPListener.lineLimit) else { Issue.record("a revoked client's call ran"); return }
    }

    @Test func aRefusedPreambleLogsNoTextThePeerChose() throws {
        let support = support()
        var clients = MCPClients()
        _ = try clients.register(id: "brain-1", name: "Invented brain", binders: [:])
        try clients.save(support)
        let log = Lines()
        let listener = try listener(support, log: log)
        defer { listener.stop() }

        // An id that names no registered client: only letters, which a character filter would let through.
        let (unknown, no) = try authenticate(listener, id: "inventedsecretwords", token: "not-a-token")
        defer { close(unknown) }
        #expect(no?.contains("token_refused") == true)
        // A registered id with a wrong token is named: the id is Sprava's own.
        let (known, also) = try authenticate(listener, id: "brain-1", token: "not-the-token")
        defer { close(known) }
        #expect(also?.contains("token_refused") == true)

        #expect(log.wait(for: "mcp client=brain-1 auth=refused code=token_refused"))
        #expect(log.all.contains("mcp auth=refused code=token_refused"))
        #expect(!log.all.contains { $0.contains("invented") || $0.contains("secret") || $0.contains("words") })
    }

    @Test func authenticatedConnectionsStayCountedUntilTheyClose() throws {
        let support = support()
        var clients = MCPClients()
        let one = try clients.register(id: "brain-1", name: "Invented brain", binders: [:])
        let two = try clients.register(id: "brain-2", name: "Another invented brain", binders: [:])
        try clients.save(support)
        var limits = MCPListener.Limits()
        limits.authenticated = 3
        limits.perClient = 2
        let log = Lines()
        let listener = try listener(support, limits: limits, log: log)
        defer { listener.stop() }

        var open: [Int32] = []
        defer { open.forEach { close($0) } }
        for _ in 0..<2 {
            let (fd, answer) = try authenticate(listener, id: "brain-1", token: one)
            open.append(fd)
            #expect(answer?.contains(#""ok":true"#) == true)
        }
        // A third connection of one client is over its own limit.
        let (third, busy) = try authenticate(listener, id: "brain-1", token: one)
        open.append(third)
        #expect(busy?.contains("busy") == true)
        let (other, yes) = try authenticate(listener, id: "brain-2", token: two)
        open.append(other)
        #expect(yes?.contains(#""ok":true"#) == true)
        // A second one of another client is over the limit of all clients together.
        let (fourth, full) = try authenticate(listener, id: "brain-2", token: two)
        open.append(fourth)
        #expect(full?.contains("busy") == true)
        #expect(log.all.contains("mcp client=brain-2 auth=refused code=busy"))

        // A connection that closes gives its place back.
        close(open.removeFirst())
        var again: String?
        for _ in 0..<200 where again?.contains(#""ok":true"#) != true {
            let (fd, answer) = try authenticate(listener, id: "brain-1", token: one)
            open.append(fd)
            again = answer
            usleep(10_000)
        }
        #expect(again?.contains(#""ok":true"#) == true)
    }

    @Test func anIdleAuthenticatedConnectionIsClosed() throws {
        let support = support()
        var clients = MCPClients()
        let token = try clients.register(id: "brain-1", name: "Invented brain", binders: [:])
        try clients.save(support)
        var limits = MCPListener.Limits()
        limits.idle = 0.3
        let log = Lines()
        let listener = try listener(support, limits: limits, log: log)
        defer { listener.stop() }

        let (fd, answer) = try authenticate(listener, id: "brain-1", token: token)
        defer { close(fd) }
        #expect(answer?.contains(#""ok":true"#) == true)
        let started = Date()
        guard case .end = LineReader(fd: fd).next(limit: MCPListener.lineLimit) else { Issue.record("an idle connection stayed open"); return }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(log.wait(for: "mcp client=brain-1 closed=idle"))
    }

    @Test func theListenerKeepsAcceptingAfterATransientError() throws {
        let support = support()
        var clients = MCPClients()
        let token = try clients.register(id: "brain-1", name: "Invented brain", binders: [:])
        try clients.save(support)
        let log = Lines()
        let failures = Lines()
        let listener = try listener(support, log: log) { listener in
            // The first accept fails as in a process out of descriptors.
            listener.acceptCall = { fd in
                if failures.all.isEmpty {
                    failures.append("EMFILE")
                    errno = EMFILE
                    return -1
                }
                return Darwin.accept(fd, nil, nil)
            }
        }
        defer { listener.stop() }

        let (fd, answer) = try authenticate(listener, id: "brain-1", token: token)
        defer { close(fd) }
        #expect(answer?.contains(#""ok":true"#) == true)
        #expect(log.all.contains("mcp accept error=\(EMFILE)"))
    }
}

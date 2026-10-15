@testable import Brains
import Darwin
import Foundation
import SpravaKit

/// A stand-in for llama-server on a Unix socket: it records each request and answers as its handler says. It plays
/// the running helper too, so `LLMHelper` starts and stops it as it would `sprava-llm`. Invented replies only.
final class FakeLLMServer: LLMProcess, @unchecked Sendable {
    struct Request {
        let method: String
        let target: String
        let head: String
        let body: Data
        var json: JSONValue? { try? JSONParser.parse(body).value }
    }

    /// A JSON body with its status, raw bytes, or nothing until the server is stopped.
    enum Action { case json(Int, String), raw([UInt8]), hang }

    let path: String
    let handler: @Sendable (Request) -> Action
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var running = true
    private var seen: [Request] = []

    init(path: String, handler: @escaping @Sendable (Request) -> Action = FakeLLMServer.healthy()) throws {
        self.path = path
        self.handler = handler
        guard var addr = unixAddress(path) else { throw LLMHelper.Failure(.socketPath) }
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw LLMHelper.Failure(.startFailed) }
        Thread { [self] in acceptLoop() }.start()
    }

    var requests: [Request] { lock.lock(); defer { lock.unlock() }; return seen }
    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }

    func stop(grace: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        running = false
        close(fd)
        unlink(path)
    }

    /// The server's answers when nothing goes wrong: healthy, the prompt rendered from the last message, and `reply`.
    static func healthy(reply: String = #"{"answer":"invented"}"#, stop: String = "eos", truncated: Bool = false)
        -> @Sendable (Request) -> Action {
        { request in
            switch request.target {
            case "/health": return .json(200, #"{"status":"ok"}"#)
            case "/apply-template":
                let last = request.json?["messages"]?.arrayValue?.last?["content"]?.stringValue ?? ""
                return .json(200, JSONWriter.compact(.obj([("prompt", .str("<turn>" + last + "<turn>"))])))
            case "/completion":
                return .json(200, JSONWriter.compact(.obj([("content", .str(reply)), ("stop_type", .str(stop)),
                                                          ("truncated", .bool(truncated))])))
            default: return .json(404, "{}")
            }
        }
    }

    /// `healthy()`, except that `/completion` is answered by `action`.
    static func completion(_ action: @escaping @Sendable (Request) -> Action) -> @Sendable (Request) -> Action {
        { request in request.target == "/completion" ? action(request) : healthy()(request) }
    }

    private func acceptLoop() {
        while isRunning {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 50) > 0, isRunning else { continue }
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { continue }
            _ = fcntl(conn, F_SETFL, fcntl(conn, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread { [self] in serve(conn) }.start()
        }
    }

    private func serve(_ conn: Int32) {
        defer { close(conn) }
        guard let request = read(conn) else { return }
        lock.lock()
        seen.append(request)
        lock.unlock()
        let bytes: [UInt8]
        switch handler(request) {
        case .json(let status, let body):
            let data = Array(body.utf8)
            bytes = Array("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n".utf8) + data
        case .raw(let raw): bytes = raw
        case .hang:
            while isRunning { usleep(20_000) }
            return
        }
        _ = bytes.withUnsafeBytes { write(conn, $0.baseAddress!, bytes.count) }   // blocking: all of it, or the client left
    }

    private func read(_ conn: Int32) -> Request? {
        var bytes = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let end = LLMHTTP.headerEnd(bytes),
               bytes.count - end - 4 >= LLMHTTP.header("content-length", in: bytes[..<end]).flatMap(Int.init) ?? 0 {
                let head = String(decoding: bytes[..<end], as: UTF8.self)
                let line = (head.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
                guard line.count == 3 else { return nil }
                return Request(method: String(line[0]), target: String(line[1]), head: head, body: Data(bytes[(end + 4)...]))
            }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(conn, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return nil }
            bytes.append(contentsOf: chunk[0..<n])
        }
    }
}

/// A value several threads share: log lines, the servers a helper started, a test's clock or counter.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    /// Changes the value and returns what it was.
    @discardableResult func update(_ change: (inout Value) -> Void) -> Value {
        lock.lock()
        defer { lock.unlock() }
        let old = stored
        change(&stored)
        return old
    }
}

/// A short socket path in the temporary folder, under the 104-byte limit.
func llmSocketPath() -> String {
    NSTemporaryDirectory() + "llm-\(UUID().uuidString.prefix(8)).sock"
}

/// An `LLMHelper` that starts a `FakeLLMServer` with `handler` wherever it would start `sprava-llm`; `clock` replaces
/// the uptime clock.
func fakeHelper(limits: LLMHelper.Limits = .init(), log: Locked<[String]> = Locked([]), clock: Locked<TimeInterval>? = nil,
                handler: @escaping @Sendable (FakeLLMServer.Request) -> FakeLLMServer.Action = FakeLLMServer.healthy())
    -> (LLMHelper, Locked<[FakeLLMServer]>) {
    let launches = Locked<[FakeLLMServer]>([])
    let now: @Sendable () -> TimeInterval
    if let clock { now = { clock.value } } else { now = { ProcessInfo.processInfo.systemUptime } }
    let helper = LLMHelper(socket: llmSocketPath(), limits: limits, log: { line in log.update { $0.append(line) } }, now: now) { socket, _ in
        let server = try FakeLLMServer(path: socket, handler: handler)
        launches.update { $0.append(server) }
        return server
    }
    return (helper, launches)
}

let inventedSchema: JSONValue = .obj([
    ("type", .str("object")),
    ("properties", .obj([("answer", .obj([("type", .str("string"))]))])),
    ("required", .array([.str("answer")])),
    ("additionalProperties", .bool(false)),
])

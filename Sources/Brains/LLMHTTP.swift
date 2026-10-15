import Darwin
import Foundation

/// One HTTP/1.1 exchange with the local model helper over its Unix socket (docs/conversation.md 11.2): one request with
/// `Connection: close`, its answer read to the end or to its `Content-Length`, under one deadline and one size cap.
/// Nothing else of HTTP is spoken: no keep-alive, no chunked answers, no redirects.
enum LLMHTTP {
    struct Reply: Equatable { let status: Int; let body: Data }

    /// `unreachable`: no helper answers on the socket; `malformed`: not an HTTP/1.1 answer this client reads.
    enum Failure: Error, Equatable { case unreachable, timedOut, tooLarge, malformed }

    /// A moment on the uptime clock, which a change of the wall clock does not move.
    struct Deadline {
        let uptime: TimeInterval
        init(in seconds: TimeInterval) { uptime = ProcessInfo.processInfo.systemUptime + seconds }
        var remaining: TimeInterval { uptime - ProcessInfo.processInfo.systemUptime }
    }

    static func exchange(socket path: String, method: String, target: String, body: Data? = nil,
                         until deadline: Deadline, maxReply: Int) -> Result<Reply, Failure> {
        guard var addr = unixAddress(path) else { return .failure(.unreachable) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.unreachable) }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if connected != 0 {
            guard errno == EINPROGRESS else { return .failure(.unreachable) }
            guard wait(fd, for: POLLOUT, until: deadline) else { return .failure(.timedOut) }
            var code: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else { return .failure(.unreachable) }
        }
        var head = "\(method) \(target) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        let request = Array((head + "\r\n").utf8) + Array(body ?? Data())
        var sent = 0
        while sent < request.count {
            let n = request.withUnsafeBytes { write(fd, $0.baseAddress! + sent, request.count - sent) }
            if n > 0 { sent += n; continue }
            if n < 0, errno == EINTR { continue }
            guard n < 0, errno == EAGAIN else { return .failure(.unreachable) }
            guard wait(fd, for: POLLOUT, until: deadline) else { return .failure(.timedOut) }
        }
        var answer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            if let reply = complete(answer) { return reply }
            let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                answer.append(contentsOf: chunk[0..<n])
                if answer.count > maxReply { return .failure(.tooLarge) }
                continue
            }
            if n == 0 { return parse(answer) }
            if errno == EINTR { continue }
            guard errno == EAGAIN else { return .failure(.unreachable) }
            guard wait(fd, for: POLLIN, until: deadline) else { return .failure(.timedOut) }
        }
    }

    /// Waits in `poll` until the socket is ready or the deadline passes; a hang-up counts as ready, so the next call
    /// sees it.
    static func wait(_ fd: Int32, for event: Int32, until deadline: Deadline) -> Bool {
        while true {
            let left = deadline.remaining
            guard left > 0 else { return false }
            var p = pollfd(fd: fd, events: Int16(event), revents: 0)
            let ready = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
            if ready > 0 { return true }
            if ready < 0, errno != EINTR { return true }
        }
    }

    /// The reply, once the bytes read hold a whole one by its `Content-Length`; nil while more are needed.
    static func complete(_ bytes: [UInt8]) -> Result<Reply, Failure>? {
        guard let split = headerEnd(bytes), let length = header("content-length", in: bytes[..<split]).flatMap(Int.init),
              bytes.count - split - 4 >= length else { return nil }
        return parse(bytes)
    }

    /// Reads a status line, headers and a body. A body longer than its `Content-Length`, a chunked body, or an answer
    /// cut off before its length is malformed; without a length, the body is what came before the connection closed.
    static func parse(_ bytes: [UInt8]) -> Result<Reply, Failure> {
        guard let split = headerEnd(bytes) else { return .failure(.malformed) }
        let head = bytes[..<split]
        guard let line = String(bytes: head.prefix { $0 != 0x0D }, encoding: .ascii) else { return .failure(.malformed) }
        let parts = line.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, parts[0] == "HTTP/1.1" || parts[0] == "HTTP/1.0", parts[1].count == 3,
              let status = Int(parts[1]) else { return .failure(.malformed) }
        guard header("transfer-encoding", in: head) == nil else { return .failure(.malformed) }
        let body = Data(bytes[(split + 4)...])
        if let value = header("content-length", in: head), Int(value) != body.count { return .failure(.malformed) }
        return .success(Reply(status: status, body: body))
    }

    static func headerEnd(_ bytes: [UInt8]) -> Int? {
        bytes.count < 4 ? nil : (0...(bytes.count - 4)).first { bytes[$0...($0 + 3)].elementsEqual([0x0D, 0x0A, 0x0D, 0x0A]) }
    }

    /// The value of the header `name` (lowercase), from the lines after the status line.
    static func header(_ name: String, in head: ArraySlice<UInt8>) -> String? {
        let text = String(decoding: head, as: UTF8.self)
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            if line[..<colon].lowercased() == name { return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }
}

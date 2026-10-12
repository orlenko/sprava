import Darwin
import Foundation

extension MCPShimConnection {
    /// The shim must exit when its host stops reading stdout, even while stdin stays open (architecture 7.2).
    /// The caller ignores SIGPIPE; nonblocking writes and one deadline bound the entire supplied chunk.
    package static func writeOutput(_ fd: Int32, bytes: [UInt8], timeout: TimeInterval = 30) -> Bool {
        guard timeout.isFinite, timeout >= 0 else { return false }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        defer { _ = fcntl(fd, F_SETFL, flags) }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var offset = 0
        while offset < bytes.count {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return false }
            let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress! + offset, bytes.count - offset) }
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            var ready = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let result = poll(&ready, 1, Int32(min(remaining * 1000, 1000).rounded(.up)))
            if result < 0, errno == EINTR { continue }
            if result < 0 || ready.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
        }
        return true
    }
}

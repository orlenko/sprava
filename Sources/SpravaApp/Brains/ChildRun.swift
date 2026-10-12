import Darwin
import Foundation

/// A short program the app runs for the person (`claude mcp add`), so that nothing waits on it without a bound: it
/// runs off the main actor, its standard output and error are read while it runs (a child that fills a pipe never
/// blocks on it), only the last `keep` bytes of each are kept, and one still there after `timeout` gets SIGTERM, then
/// SIGKILL, which cannot be caught or ignored, after `grace`. A process it left holding a pipe open is not waited for.
struct ChildRun: Sendable {
    enum Ending: Equatable, Sendable {
        case exited(Int32)
        case timedOut
    }

    struct Outcome: Sendable {
        let ending: Ending
        let stdout: Data
        let stderr: Data
    }

    let executable: URL
    let arguments: [String]
    var timeout: TimeInterval = 60
    var grace: TimeInterval = 2
    var keep = 64 * 1024

    /// Throws only when the program cannot be started.
    func run() async throws -> Outcome {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global().async { c.resume(with: Result { try runWaiting() }) }
        }
    }

    /// Runs the program on the calling thread, reading both pipes in `poll` until it has exited and they are closed
    /// (or `grace` after it exited), or until `timeout`.
    func runWaiting() throws -> Outcome {
        let task = Process()
        task.executableURL = executable
        task.arguments = arguments
        task.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        task.standardOutput = out
        task.standardError = err
        let readers = [out.fileHandleForReading, err.fileHandleForReading]
        defer { for r in readers { try? r.close() } }
        let deadline = Date() + timeout
        try task.run()
        var fds = readers.map { $0.fileDescriptor }
        var kept = [Data(), Data()]
        var exitedAt: Date?
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if exitedAt == nil, !task.isRunning { exitedAt = Date() }
            if let exitedAt, fds.allSatisfy({ $0 < 0 }) || Date().timeIntervalSince(exitedAt) > grace { break }
            if exitedAt == nil, Date() > deadline {
                Self.stop(task, grace: grace)
                return Outcome(ending: .timedOut, stdout: kept[0], stderr: kept[1])
            }
            // A closed pipe is -1, which poll skips; with both closed it only waits.
            var p = fds.map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
            guard poll(&p, nfds_t(p.count), 100) > 0 else { continue }
            for i in p.indices where p[i].fd >= 0 && p[i].revents != 0 {
                let n = buffer.withUnsafeMutableBytes { Darwin.read(p[i].fd, $0.baseAddress, $0.count) }
                if n < 0, errno == EINTR || errno == EAGAIN { continue }
                guard n > 0 else { fds[i] = -1; continue }
                kept[i].append(contentsOf: buffer[0..<n])
                if kept[i].count > keep { kept[i] = Data(kept[i].suffix(keep)) }
            }
        }
        return Outcome(ending: .exited(task.terminationStatus), stdout: kept[0], stderr: kept[1])
    }

    /// SIGTERM, then SIGKILL if it is still there after `grace`, then a last bounded wait for it to go.
    static func stop(_ task: Process, grace: TimeInterval) {
        guard task.isRunning else { return }
        task.terminate()
        var until = Date() + grace
        while task.isRunning, Date() < until { usleep(10_000) }
        guard task.isRunning else { return }
        kill(task.processIdentifier, SIGKILL)
        until = Date() + grace
        while task.isRunning, Date() < until { usleep(10_000) }
    }
}

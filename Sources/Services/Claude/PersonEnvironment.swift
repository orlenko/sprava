import Brains
import Foundation

/// The person's shell environment, for a binder's commands (decisions.md D50, conversation.md §18.3.3).
///
/// The runtime is started by launchd and holds nothing the person's shell exports, so this asks their login shell: it is
/// started as a login and interactive shell, which reads the same profile files a new terminal window does, and prints
/// its environment between two marks. Whatever the profile itself prints stays outside the marks. Nothing here waits
/// without a bound: a profile that hangs, asks a question or never ends costs `timeout` and gives the last environment
/// that was read, or none. No name and no value is logged.
final class PersonEnvironment: @unchecked Sendable {
    static let shared = PersonEnvironment()
    static let maximumBytes = 1 << 20

    private let shell: String?
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var last: [String: String] = [:]

    init(shell: String? = PersonEnvironment.loginShell(), timeout: TimeInterval = 10) {
        self.shell = shell
        self.timeout = timeout
    }

    /// The login shell in this user's account record. Never `SHELL`, which launchd does not set and a caller could.
    static func loginShell() -> String? {
        guard let record = getpwuid(getuid()), let path = record.pointee.pw_shell else { return nil }
        let shell = String(cString: path)
        return shell.hasPrefix("/") ? shell : nil
    }

    /// What commands get: the shell's exports cut by `CommandVariables.passable`. When the shell cannot be read now,
    /// what it gave last time in this run of the runtime.
    func forCommands() -> [String: String] {
        guard let read = read() else { return lock.withLock { last } }
        let kept = CommandVariables.passable(read)
        lock.withLock { last = kept }
        return kept
    }

    /// The shell's whole environment, or nil when it did not give one within the limits.
    func read() -> [String: String]? {
        guard let shell, FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let mark = "sprava-env-" + UUID().uuidString
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: shell)
        // `printf` and `;` mean the same in zsh, bash, sh and fish; `env -0` ends each variable with a NUL, so a value
        // with line breaks cannot pass for two variables.
        process.arguments = ["-l", "-i", "-c", "printf %s \(mark); /usr/bin/env -0; printf %s \(mark)"]
        // Only what a login starts from. Nothing of the runtime's own environment reaches the profile or comes back as the person's.
        let home = NSHomeDirectory(), user = NSUserName()
        process.environment = ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.currentDirectoryURL = URL(fileURLWithPath: home, isDirectory: true)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        defer { Self.stop(process) }
        let data = Self.collect(out.fileHandleForReading.fileDescriptor, mark: Data(mark.utf8), until: Date() + timeout)
        return data.flatMap { Self.parse($0, mark: Data(mark.utf8)) }
    }

    /// Reads until the second mark has come. Nil at the deadline, at the size limit, or when the shell closed its end
    /// first. It stops at the mark, so a program the profile left running with the pipe open is not waited for.
    static func collect(_ fd: Int32, mark: Data, until deadline: Date) -> Data? {
        var all = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let left = deadline.timeIntervalSinceNow
            guard left > 0 else { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(left, 1) * 1000) + 1)
            if ready < 0, errno != EINTR { return nil }
            guard ready > 0 else { continue }
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
            if n == 0 { return nil }
            all.append(contentsOf: buffer[0..<n])
            guard all.count <= maximumBytes else { return nil }
            if let first = all.range(of: mark), all.range(of: mark, in: first.upperBound..<all.endIndex) != nil { return all }
        }
    }

    /// The variables between the two marks: `NAME=value` records, each ended by a NUL. Nil unless both marks are there.
    static func parse(_ data: Data, mark: Data) -> [String: String]? {
        guard let first = data.range(of: mark), let second = data.range(of: mark, in: first.upperBound..<data.endIndex) else { return nil }
        var found: [String: String] = [:]
        for record in data[first.upperBound..<second.lowerBound].split(separator: 0) {
            guard let equals = record.firstIndex(of: UInt8(ascii: "=")), equals > record.startIndex,
                  let name = String(data: record[..<equals], encoding: .utf8),
                  let value = String(data: record[record.index(after: equals)...], encoding: .utf8) else { continue }
            found[name] = value
        }
        return found
    }

    /// SIGTERM, then SIGKILL after a second, with a bounded wait each time.
    static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        var until = Date() + 1
        while process.isRunning, Date() < until { usleep(10_000) }
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
        until = Date() + 1
        while process.isRunning, Date() < until { usleep(10_000) }
    }
}

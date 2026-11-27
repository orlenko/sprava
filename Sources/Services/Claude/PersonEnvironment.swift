import Brains
import Foundation

/// The person's shell environment, for a binder's commands (decisions.md D50, conversation.md §18.3.3).
///
/// The runtime is started by launchd and holds nothing the person's shell exports, so this asks their login shell: it is
/// started as a login and interactive shell, which reads the same profile files a new terminal window does, and prints
/// its environment between two marks. Whatever the profile itself prints stays outside the marks. Nothing here waits
/// without a bound: a profile that hangs, asks a question or never ends costs `timeout`, and then the quarter second at
/// most it takes to kill the shell and what it started, and gives the last environment that was read, or none. No name
/// and no value is logged.
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

    /// The shell's whole environment, or nil when it did not give one within the limits. One deadline, on a clock that
    /// does not jump, covers starting the shell and reading its answer. At the end, in time or not, the shell and whatever
    /// its profile started are killed outright: it only printed, so there is nothing for it to finish.
    func read() -> [String: String]? {
        guard let shell, FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        let mark = "sprava-env-" + UUID().uuidString
        var ends: [Int32] = [0, 0]
        guard pipe(&ends) == 0 else { return nil }
        defer { close(ends[0]) }
        _ = fcntl(ends[0], F_SETFD, FD_CLOEXEC); _ = fcntl(ends[1], F_SETFD, FD_CLOEXEC)
        // Only what a login starts from. Nothing of the runtime's own environment reaches the profile or comes back as the person's.
        let home = NSHomeDirectory(), user = NSUserName()
        // `printf` and `;` mean the same in zsh, bash, sh and fish; `env -0` ends each variable with a NUL, so a value
        // with line breaks cannot pass for two variables.
        let pid = Self.start(shell, arguments: ["-l", "-i", "-c", "printf %s \(mark); /usr/bin/env -0; printf %s \(mark)"],
                             environment: ["HOME": home, "USER": user, "LOGNAME": user, "SHELL": shell, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
                             directory: home, output: ends[1])
        close(ends[1])
        guard let pid else { return nil }
        defer { Self.end(pid) }
        let data = Self.collect(ends[0], mark: Data(mark.utf8), until: deadline)
        return data.flatMap { Self.parse($0, mark: Data(mark.utf8)) }
    }

    /// Starts the shell as the leader of a process group of its own, with no file of this process but the pipe: nothing
    /// on its input, its errors dropped. Nil when it cannot be started.
    static func start(_ shell: String, arguments: [String], environment: [String: String], directory: String, output: Int32) -> pid_t? {
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        var all = sigset_t(), none = sigset_t(); sigfillset(&all); sigemptyset(&none)
        guard posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0) == 0,
              posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0) == 0,
              posix_spawn_file_actions_addchdir(&actions, directory) == 0,
              posix_spawnattr_setsigdefault(&attributes, &all) == 0,
              posix_spawnattr_setsigmask(&attributes, &none) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0 else {
            return nil
        }
        let argv = ([shell] + arguments).map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        guard posix_spawn(&pid, shell, &actions, &attributes, argv, envp) == 0 else { return nil }
        return pid
    }

    /// Kills the shell's whole group, which SIGKILL ends at once, and collects the shell so it does not stay as a dead
    /// entry. The wait is one that never blocks, repeated for at most a quarter of a second; past that, which a killed
    /// process does not reach, the collecting is left to a thread of its own.
    static func end(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
        var status: Int32 = 0
        for _ in 0..<50 {
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid || (result < 0 && errno != EINTR) { return }
            usleep(5_000)
        }
        DispatchQueue.global(qos: .utility).async { var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
    }

    /// Reads until the second mark has come. Nil at the deadline, at the size limit, or when the shell closed its end
    /// first. It stops at the mark, so a program the profile left running with the pipe open is not waited for.
    static func collect(_ fd: Int32, mark: Data, until deadline: ContinuousClock.Instant) -> Data? {
        var all = Data()
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let left = ContinuousClock.now.duration(to: deadline)
            guard left > .zero else { return nil }
            let milliseconds = left.components.seconds * 1000 + left.components.attoseconds / 1_000_000_000_000_000
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, Int32(min(milliseconds, 1000)) + 1)
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
}

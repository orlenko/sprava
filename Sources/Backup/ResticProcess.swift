import Darwin
import Foundation

/// One restic process, run so that nothing waits on it without a bound (docs/backup.md §3.3; issue #205). restic leads
/// a process group of its own, so a stop reaches whatever it started too. Its output is read in `poll`, against a
/// deadline and a no-progress cutoff; a process that is to stop gets SIGTERM, then SIGKILL, for the whole group. When
/// restic has exited, a process it left holding its output open is stopped, never waited for.
struct ResticProcess {
    let binary: URL
    let arguments: [String]
    let environment: [String: String]
    let cwd: URL?
    /// The longest the whole run may take (nil: no limit).
    let timeout: TimeInterval?
    /// The longest restic may go without progress (nil: no limit).
    let stall: TimeInterval?
    /// A line of output after which the no-progress cutoff no longer holds (nil: it holds to the end).
    let stallEndsAt: String?
    /// How long a process asked to stop gets before it is killed, and a killed one before it is given up on.
    let grace: TimeInterval
    /// Seconds on a clock that stops while the Mac sleeps (`uptime`), so a Mac asleep through a run never counts as
    /// a run that made no progress, nor as one past its deadline; tests pass their own.
    var clock: @Sendable () -> TimeInterval = ResticProcess.uptime

    static func uptime() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    enum Ending: Equatable {
        case exited(Int32)
        case stopped(Stop)
    }

    /// Why restic was stopped before it exited.
    enum Stop: Equatable {
        case timedOut
        case stalled
        case failedWrite
    }

    /// Runs restic with standard input from /dev/null, standard error into `stderr` (an open file), and standard output
    /// either collected and returned, or written to `sink` (an open file) as it comes. Throws only when restic cannot
    /// be started, or does not stop when told to.
    func run(stderr: Int32, sink: Int32? = nil) throws -> (Ending, Data) {
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { throw Restic.Failure(message: "restic's output cannot be read (\(String(cString: strerror(errno))))") }
        let (reader, writer) = (fds[0], fds[1])
        _ = fcntl(reader, F_SETFD, FD_CLOEXEC)
        _ = fcntl(writer, F_SETFD, FD_CLOEXEC)
        let pid: pid_t
        do { pid = try spawn(stdout: writer, stderr: stderr) } catch {
            close(reader); close(writer)
            throw error
        }
        close(writer)
        defer { close(reader) }
        let (stop, out) = watch(pid, reader: reader, stderr: stderr, sink: sink)
        guard let stop else {
            // restic is gone; whatever it left in its group (holding the pipe, say) goes too.
            killpg(pid, SIGKILL)
            return (.exited(reap(pid)), out)
        }
        // Asked to stop: SIGTERM, then SIGKILL, which cannot be caught or ignored, each to the whole group.
        killpg(pid, SIGTERM)
        if !exited(pid, within: grace) {
            killpg(pid, SIGKILL)
            guard exited(pid, within: grace) else {
                throw Restic.Failure(message: "restic \(arguments.first ?? "") did not stop when told to; it is left running")
            }
        }
        killpg(pid, SIGKILL)
        _ = reap(pid)
        return (.stopped(stop), out)
    }

    func spawn(stdout: Int32, stderr: Int32) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A group of its own; no descriptor of this process but the three below; signals as a new process has them.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t(0)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD] { defaults |= sigset_t(1) << sigset_t(signal - 1) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t(0)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let cwd { posix_spawn_file_actions_addchdir_np(&actions, cwd.path) }
        let argv: [UnsafeMutablePointer<CChar>?] = ([binary.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, binary.path, &actions, &attributes, argv, envp)
        guard rc == 0 else { throw Restic.Failure(message: "restic could not be started (\(String(cString: strerror(rc))))") }
        return pid
    }

    /// Reads restic's output until restic exits (and, briefly, whatever it left still writing), the deadline passes,
    /// or it makes no progress for `stall`. Progress is output that says something new: a status line that only
    /// counts the seconds (`progressKey`) is not, since restic prints one every few seconds also while it waits on
    /// a disk or a cloud that does not answer. Its error output growing is. Nil when restic exited.
    func watch(_ pid: pid_t, reader: Int32, stderr: Int32, sink: Int32?) -> (Stop?, Data) {
        let start = clock()
        var lastProgress = start
        var out = Data()
        var line: [UInt8] = []
        var lastKey: String?
        var errSize: off_t = 0
        var open = true
        var exitedAt: TimeInterval?
        var stall = self.stall
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            if exitedAt == nil, exited(pid) { exitedAt = clock() }
            if let exitedAt, !open || clock() - exitedAt > 1 { return (nil, out) }
            var info = stat()
            if fstat(stderr, &info) == 0, info.st_size > errSize { errSize = info.st_size; lastProgress = clock() }
            if open {
                var p = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 200) > 0 {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress, $0.count) }
                    if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { open = false }
                    if n > 0 {
                        let chunk = buffer[0..<n]
                        if let sink {
                            guard Self.writeAll(sink, chunk) else { return (.failedWrite, out) }
                            lastProgress = clock()
                        } else {
                            out.append(contentsOf: chunk)
                            line.append(contentsOf: chunk)
                            var moved = false
                            while let end = line.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                                let text = String(decoding: line[..<end], as: UTF8.self)
                                line.removeSubrange(...end)
                                guard !text.isEmpty else { continue }
                                if let stallEndsAt, text.contains(stallEndsAt) { stall = nil }
                                let key = Self.progressKey(text)
                                if key != lastKey { lastKey = key; moved = true }
                            }
                            // A long line still coming (a long listing) is data arriving.
                            if line.count > 1 << 16 { line.removeAll(); moved = true }
                            if moved { lastProgress = clock() }
                        }
                    }
                }
            } else {
                usleep(50_000)
            }
            if let timeout, clock() - start > timeout { return (.timedOut, out) }
            if let stall, clock() - lastProgress > stall {
                // Output that came in while the clock ran on (or the Mac slept) is read first: it may be progress.
                var p = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                if open, poll(&p, 1, 0) > 0 { continue }
                return (.stalled, out)
            }
        }
    }

    /// A line of restic's output without what changes with the clock alone: the elapsed and remaining seconds of a
    /// JSON status, the "[0:05]" a progress line starts with, and its "ETA 0:20".
    static func progressKey(_ line: String) -> String {
        line.replacing(/"seconds_(?:elapsed|remaining)":[0-9.]+,?/, with: "")
            .replacing(/^\[[0-9:]+\]\s*/, with: "")
            .replacing(/\s*ETA\s+[0-9:]+\s*$/, with: "")
    }

    static func writeAll(_ fd: Int32, _ bytes: ArraySlice<UInt8>) -> Bool {
        var rest = bytes
        while !rest.isEmpty {
            let n = rest.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return false }
            rest = rest.dropFirst(n)
        }
        return true
    }

    /// Whether restic has exited, without reaping it: until it is reaped its process id, and so its group's, cannot
    /// name another process.
    func exited(_ pid: pid_t) -> Bool {
        while true {
            var info = siginfo_t()
            if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 { return info.si_pid == pid }
            if errno != EINTR { return true }   // ECHILD: no such child any more
        }
    }

    func exited(_ pid: pid_t, within seconds: TimeInterval) -> Bool {
        let until = clock() + seconds
        while !exited(pid) {
            guard clock() < until else { return false }
            usleep(20_000)
        }
        return true
    }

    /// Reaps restic, already exited, and returns its exit status (128 plus the signal for one a signal ended).
    func reap(_ pid: pid_t) -> Int32 {
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 {
            if errno != EINTR { return -1 }
        }
        return status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
    }
}

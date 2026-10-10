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
    /// A line after which silent disk I/O also counts as progress (restic's restore verification).
    let observeIOAfter: String?
    /// How long a process asked to stop gets before it is killed, and a killed one before it is given up on.
    let grace: TimeInterval
    /// Seconds on a clock that stops while the Mac sleeps (`uptime`), so a Mac asleep through a run never counts as
    /// a run that made no progress, nor as one past its deadline; tests pass their own.
    var clock: @Sendable () -> TimeInterval = ResticProcess.uptime
    var diskProgress: @Sendable (pid_t) -> UInt64? = ResticProcess.diskProgress
    var sinkWriterBinary = URL(fileURLWithPath: "/usr/bin/tee")
    /// Tests can shorten the final drain; production uses its stall policy, with a finite fallback when disabled.
    var drainLimit: TimeInterval?

    static func uptime() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9 }

    static func diskProgress(_ pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) {
            proc_pid_rusage(pid, RUSAGE_INFO_V4, UnsafeMutableRawPointer($0).assumingMemoryBound(to: rusage_info_t?.self))
        }
        guard result == 0 else { return nil }
        return verificationReads(usage)
    }

    /// Restic refreshes its repository lock by writing every five minutes. Those writes are not verification
    /// progress; counting only reads keeps a stuck verification bounded even while lock maintenance continues.
    static func verificationReads(_ usage: rusage_info_v4) -> UInt64 {
        usage.ri_diskio_bytesread
    }

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
        // The helper performs sink writes in the child's process group. A filesystem write may block even on a
        // nonblocking regular descriptor, so the supervisor itself only reads a pipe and can always stop the group.
        var transfer: [Int32] = [-1, -1]
        if sink != nil {
            guard pipe(&transfer) == 0 else {
                close(reader); close(writer)
                throw Restic.Failure(message: "restic's streamed output cannot be piped")
            }
            _ = fcntl(transfer[0], F_SETFD, FD_CLOEXEC)
            _ = fcntl(transfer[1], F_SETFD, FD_CLOEXEC)
        }
        defer { for fd in transfer where fd >= 0 { close(fd) } }
        let pid: pid_t
        do { pid = try spawn(stdout: sink == nil ? writer : transfer[1], stderr: stderr) } catch {
            close(reader); close(writer)
            throw error
        }
        var sinkWriter: pid_t?
        if let sink {
            do {
                sinkWriter = try spawn(stdout: writer, stderr: stderr, input: transfer[0], sink: sink,
                                       binary: sinkWriterBinary, arguments: ["/dev/fd/3"], group: pid)
            } catch {
                killpg(pid, SIGKILL)
                close(reader); close(writer)
                if exited(pid, within: grace) { _ = reap(pid) }
                throw error
            }
            close(transfer[1]); transfer[1] = -1
            close(transfer[0]); transfer[0] = -1
        }
        close(writer)
        defer { close(reader) }
        let (stop, out) = watch(pid, reader: reader, stderr: stderr, sinkWriter: sinkWriter)
        guard let stop else {
            // restic is gone; whatever it left in its group (holding the pipe, say) goes too.
            killpg(pid, SIGKILL)
            if let sinkWriter { _ = reap(sinkWriter) }
            return (.exited(reap(pid)), out)
        }
        // Asked to stop: SIGTERM, then SIGKILL, which cannot be caught or ignored, each to the whole group.
        killpg(pid, SIGTERM)
        if !exited(pid, within: grace, other: sinkWriter) {
            killpg(pid, SIGKILL)
            guard exited(pid, within: grace, other: sinkWriter) else {
                throw Restic.Failure(message: "restic \(arguments.first ?? "") did not stop when told to; it is left running")
            }
        }
        killpg(pid, SIGKILL)
        if let sinkWriter { _ = reap(sinkWriter) }
        _ = reap(pid)
        return (.stopped(stop), out)
    }

    func spawn(stdout: Int32, stderr: Int32, input: Int32? = nil, sink: Int32? = nil,
               binary overrideBinary: URL? = nil, arguments overrideArguments: [String]? = nil, group: pid_t = 0) throws -> pid_t {
        let binary = overrideBinary ?? self.binary
        let arguments = overrideArguments ?? self.arguments
        var copies: [Int32] = []
        defer { for fd in copies { close(fd) } }
        func copy(_ fd: Int32) throws -> Int32 {
            let duplicate = fcntl(fd, F_DUPFD_CLOEXEC, 4)
            guard duplicate >= 0 else { throw Restic.Failure(message: "restic's input and output could not be prepared") }
            copies.append(duplicate)
            return duplicate
        }
        // Sources may occupy 0–3 if this host started with closed standard descriptors. Preserve every source
        // above all destinations before any spawn action overwrites those descriptor numbers.
        let stdout = try copy(stdout), stderr = try copy(stderr)
        let input = try input.map { try copy($0) }, sink = try sink.map { try copy($0) }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A group of its own; no descriptor of this process but the three below; signals as a new process has them.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, group)
        var defaults = sigset_t(0)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD] { defaults |= sigset_t(1) << sigset_t(signal - 1) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var mask = sigset_t(0)
        posix_spawnattr_setsigmask(&attributes, &mask)
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if let input { posix_spawn_file_actions_adddup2(&actions, input, 0) }
        else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        if let sink { posix_spawn_file_actions_adddup2(&actions, sink, 3) }
        if let cwd { posix_spawn_file_actions_addchdir(&actions, cwd.path) }
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
    func watch(_ pid: pid_t, reader: Int32, stderr: Int32, sinkWriter: pid_t?) -> (Stop?, Data) {
        let start = clock()
        var lastProgress = start
        var out = Data()
        var line: [UInt8] = []
        var lastKey: String?
        var errSize: off_t = 0
        var open = true
        var exitedAt: TimeInterval?
        var resticExitedAt: TimeInterval?
        var observesIO = false
        var lastIO: UInt64?
        let drain = drainLimit ?? stall ?? Restic.stallLimit
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let writerExited = sinkWriter.map { exited($0) } ?? true
            if let sinkWriter, writerExited, !succeeded(sinkWriter) { return (.failedWrite, out) }
            if resticExitedAt == nil, exited(pid) { resticExitedAt = clock() }
            if exitedAt == nil, resticExitedAt != nil, writerExited { exitedAt = clock() }
            if let exitedAt, !open || clock() - exitedAt > 1 { return (nil, out) }
            if let resticExitedAt, sinkWriter != nil, !writerExited, clock() - max(resticExitedAt, lastProgress) > drain {
                // A held-open pipe or a blocked final sink write cannot keep tee alive after restic has exited.
                // Without confirmed helper completion the streamed file may be partial, so fail closed.
                return (.failedWrite, out)
            }
            if observesIO, let progress = diskProgress(pid), progress != lastIO {
                lastIO = progress
                lastProgress = clock()
            }
            var info = stat()
            if fstat(stderr, &info) == 0, info.st_size > errSize { errSize = info.st_size; lastProgress = clock() }
            if open {
                var p = pollfd(fd: reader, events: Int16(POLLIN), revents: 0)
                if poll(&p, 1, 200) > 0 {
                    let n = buffer.withUnsafeMutableBytes { Darwin.read(reader, $0.baseAddress, $0.count) }
                    if n == 0 || (n < 0 && errno != EINTR && errno != EAGAIN) { open = false }
                    if n > 0 {
                        let chunk = buffer[0..<n]
                        if sinkWriter != nil {
                            // tee sends the same bytes through this pipe; discard them after observing progress.
                            lastProgress = clock()
                        } else {
                            out.append(contentsOf: chunk)
                            line.append(contentsOf: chunk)
                            var moved = false
                            while let end = line.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                                let text = String(decoding: line[..<end], as: UTF8.self)
                                line.removeSubrange(...end)
                                guard !text.isEmpty else { continue }
                                if let observeIOAfter, text.contains(observeIOAfter) {
                                    observesIO = true
                                    lastIO = diskProgress(pid)
                                }
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

    func succeeded(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0
            && info.si_pid == pid && info.si_code == CLD_EXITED && info.si_status == 0
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

    func exited(_ pid: pid_t, within seconds: TimeInterval, other: pid_t? = nil) -> Bool {
        let until = clock() + seconds
        while !exited(pid) || !(other.map { exited($0) } ?? true) {
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

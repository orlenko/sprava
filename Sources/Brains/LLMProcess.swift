import Darwin
import Foundation

/// A running helper, as `LLMHelper` sees it: whether it is still there, and a way to end it.
protocol LLMProcess: AnyObject {
    var isRunning: Bool { get }
    /// SIGTERM, then SIGKILL after `grace`, then a bounded wait for it to go.
    func stop(grace: TimeInterval)
}

/// The sandboxed `sprava-llm` started with `posix_spawn` (docs/conversation.md 11.2): the model on descriptor 3, the
/// three standard descriptors on /dev/null, no other descriptor and no environment.
final class SpawnedLLM: LLMProcess {
    let pid: pid_t
    private let lock = NSLock()
    private var ended = false

    init(pid: pid_t) { self.pid = pid }

    /// Reaps the helper once it has exited, so no zombie is left.
    var isRunning: Bool {
        lock.withLock {
            var status: Int32 = 0
            if !ended, case let r = waitpid(pid, &status, WNOHANG), r == pid || (r < 0 && errno == ECHILD) { ended = true }
            return !ended
        }
    }

    func stop(grace: TimeInterval) {
        guard isRunning else { return }
        kill(pid, SIGTERM)
        var until = Date() + grace
        while isRunning, Date() < until { usleep(10_000) }
        guard isRunning else { return }
        kill(pid, SIGKILL)
        until = Date() + grace
        while isRunning, Date() < until { usleep(10_000) }
    }

    /// Spawns `executable` with `arguments`, `fd` as its descriptor 3 and nothing else inherited
    /// (`POSIX_SPAWN_CLOEXEC_DEFAULT`); signals start at their defaults and unblocked.
    static func spawn(_ executable: URL, arguments: [String], fd: Int32) throws -> SpawnedLLM {
        // Moved above 3 first: dup2 of a descriptor onto itself would keep its close-on-exec flag.
        let source = fcntl(fd, F_DUPFD_CLOEXEC, 10)
        guard source >= 0 else { throw LLMHelper.Failure(.startFailed) }
        defer { close(source) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer {
            posix_spawn_file_actions_destroy(&actions)
            posix_spawnattr_destroy(&attributes)
        }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 2, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, source, 3)
        var all = sigset_t(), none = sigset_t()
        sigfillset(&all)
        sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all)
        posix_spawnattr_setsigmask(&attributes, &none)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        let envp: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard code == 0 else { throw LLMHelper.Failure(.startFailed) }
        return SpawnedLLM(pid: pid)
    }

    /// Ends helpers left by an earlier runtime that stopped without stopping them: processes of this user running
    /// `executable` whose parent is gone (adopted by launchd), each holding a model in memory that nothing uses.
    /// Returns how many were sent SIGKILL.
    @discardableResult
    static func endOrphans(of executable: URL) -> Int {
        guard let real = realpath(executable.path, nil) else { return 0 }
        let want = String(cString: real)
        free(real)
        var pids = [pid_t](repeating: 0, count: 8192)
        let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var ended = 0
        for pid in pids.prefix(max(0, count)) where pid > 1 {
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == Int32(MemoryLayout<proc_bsdinfo>.size),
                  info.pbi_ppid == 1, info.pbi_uid == getuid() else { continue }
            var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  String(decoding: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self) == want else { continue }
            if kill(pid, SIGKILL) == 0 { ended += 1 }
        }
        return ended
    }
}

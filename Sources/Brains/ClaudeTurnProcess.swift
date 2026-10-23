import Darwin
import Foundation

/// Dedicated standard pipes and process group; only these descriptors and the supplied environment survive exec.
final class ClaudeTurnProcess {
    let pid: pid_t
    var input: Int32
    let output: Int32
    let error: Int32
    private var reaped = false
    private var exitStatus: Int32?
    private var cleanupDone = false
    init(_ launch: ClaudeReadOnlyTurn.Launch, resume: Bool) throws {
        let arguments = [launch.executable.path] + launch.arguments + [resume ? "--resume" : "--session-id", launch.sessionID.uuidString.lowercased()]
        guard arguments.allSatisfy({ !$0.contains("\0") }), !launch.directory.path.contains("\0"),
              launch.environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.contains("\0") && !$0.value.contains("\0") }) else {
            throw ClaudeReadOnlyTurn.Failure.startFailed
        }
        func channel() throws -> [Int32] {
            var pair: [Int32] = [0, 0]
            guard pipe(&pair) == 0 else { throw ClaudeReadOnlyTurn.Failure.startFailed }
            let a = fcntl(pair[0], F_DUPFD_CLOEXEC, 10), b = fcntl(pair[1], F_DUPFD_CLOEXEC, 10)
            close(pair[0]); close(pair[1])
            guard a >= 0, b >= 0 else { if a >= 0 { close(a) }; if b >= 0 { close(b) }; throw ClaudeReadOnlyTurn.Failure.startFailed }
            return [a, b]
        }
        let incoming = try channel()
        var descriptors = incoming
        defer { descriptors.forEach { close($0) } }
        let outgoing = try channel(); descriptors += outgoing
        let diagnostic = try channel(); descriptors += diagnostic
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw ClaudeReadOnlyTurn.Failure.startFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw ClaudeReadOnlyTurn.Failure.startFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, diagnostic[1], STDERR_FILENO) == 0,
              posix_spawn_file_actions_addchdir(&actions, launch.directory.path) == 0 else {
            throw ClaudeReadOnlyTurn.Failure.startFailed
        }
        var all = sigset_t(), none = sigset_t(); sigfillset(&all); sigemptyset(&none)
        guard posix_spawnattr_setsigdefault(&attributes, &all) == 0,
              posix_spawnattr_setsigmask(&attributes, &none) == 0,
              posix_spawnattr_setpgroup(&attributes, 0) == 0,
              posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0 else {
            throw ClaudeReadOnlyTurn.Failure.startFailed
        }
        // Configure the parent's ends before spawning; a setup error can never leave a child behind.
        for fd in [incoming[1], outgoing[0], diagnostic[0]] {
            let flags = fcntl(fd, F_GETFL)
            guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { throw ClaudeReadOnlyTurn.Failure.startFailed }
        }
        guard fcntl(incoming[1], F_SETNOSIGPIPE, 1) == 0 else { throw ClaudeReadOnlyTurn.Failure.startFailed }
        let argv = arguments.map { strdup($0) } + [nil]
        let envp = launch.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var spawned: pid_t = 0
        guard posix_spawn(&spawned, launch.executable.path, &actions, &attributes, argv, envp) == 0 else { throw ClaudeReadOnlyTurn.Failure.startFailed }
        pid = spawned; input = incoming[1]; output = outgoing[0]; error = diagnostic[0]
        descriptors.removeAll { [input, output, error].contains($0) }
    }
    var exited: Bool {
        if !reaped {
            var status: Int32 = 0
            let result = waitpid(pid, &status, WNOHANG)
            if result == pid { reaped = true; exitStatus = status }
            else if result < 0 && errno == ECHILD { reaped = true }
        }
        return reaped
    }
    var successfulExit: Bool { exited && exitStatus == 0 }
    func signal(_ value: Int32) { if !exited { killpg(pid, value) } }
    @discardableResult func finish() -> Bool {
        if cleanupDone { return exited }
        if input >= 0 { close(input); input = -1 }
        for value in [Int32(0), SIGTERM, SIGKILL] {
            if value != 0 { signal(value) }
            // Let the CLI persist its native session after the result before escalating.
            for _ in 0..<(value == 0 ? 200 : 50) {
                if exited { cleanupDone = true; return true }; usleep(10_000)
            }
        }
        cleanupDone = true
        return exited
    }
    deinit { _ = finish(); close(output); close(error) }
}

import AgentSandboxProbe
import Darwin
import Foundation

/// Ends every process a binder agent started, before its turn is recorded or its binder is released. A shell command can
/// fork, start a new session, close its streams and change its environment, and it would go on changing files after the turn;
/// the one thing it cannot leave is its sandbox. So each session's profile denies a service name of its own, and the
/// kernel can be asked which processes that holds for.
package enum AgentContainment {
    static func marker(session: UUID) -> String { "ca.orlenko.sprava.agent.\(session.uuidString.lowercased())" }

    /// The sandbox rule that marks a session's processes.
    static func rule(session: UUID) -> String {
        let marker = marker(session: session)
        return "(allow mach-lookup (global-name \"\(marker).allow\"))\n(deny mach-lookup (global-name \"\(marker).deny\"))"
    }

    /// The processes in this session's sandbox. Another sandbox denies names it never heard of too, so the marker's sibling,
    /// which only a deny-by-default sandbox would refuse, must be allowed.
    static func running(session: UUID) -> [pid_t] {
        let marker = marker(session: session), me = getpid(), uid = getuid()
        let capacity = proc_listallpids(nil, 0) * 2
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity))
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).filter { pid in
            guard pid > 0, pid != me, sprava_is_sandboxed(pid) == 1 else { return false }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size, info.pbi_uid == uid else { return false }
            return sprava_sandbox_denies_name(pid, marker + ".deny") == 1 && sprava_sandbox_denies_name(pid, marker + ".allow") == 0
        }
    }

    /// Kills them until none is left, a fork in flight included. False when some would not go, which the caller treats like a
    /// process whose exit it could not confirm.
    @discardableResult
    package static func sweep(session: UUID) -> Bool {
        for _ in 0..<100 {
            let left = running(session: session)
            if left.isEmpty { return true }
            for pid in left { kill(pid, SIGKILL) }
            usleep(20_000)
        }
        return running(session: session).isEmpty
    }
}

import Darwin
import Foundation

/// Is the recorded pid alive, and is it the same process? A pid can be reused, so the process's start time must
/// match the heartbeat's `started_at` within a few seconds (architecture 3.3).
public enum ProcessCheck {
    public static func startTime(pid: Int32) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let tv = info.kp_proc.p_un.__p_starttime
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec) + TimeInterval(tv.tv_usec) / 1_000_000)
    }

    public static func isAlive(pid: Int32, startedAt: Date?) -> Bool {
        guard pid > 0, kill(pid, 0) == 0 || errno == EPERM else { return false }
        guard let startedAt, let actual = startTime(pid: pid) else { return startedAt == nil }
        return abs(actual.timeIntervalSince(startedAt)) < 5
    }
}

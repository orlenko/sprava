import Darwin
import Foundation

/// Reads files in the capture folder without following symbolic links, accepting only regular files owned by
/// this user (architecture 8, step 1).
public enum SafeFile {
    public enum Outcome { case ok(Data), refused(String), missing }

    public static func read(_ url: URL, limit: Int = 16 * 1024 * 1024) -> Outcome {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 { return errno == ELOOP ? .refused("a symbolic link") : .missing }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .missing }
        guard st.st_mode & S_IFMT == S_IFREG else { return .refused("not a plain file") }
        guard st.st_uid == getuid() else { return .refused("owned by another user") }
        guard st.st_size <= limit else { return .refused("larger than \(limit) bytes") }
        var data = Data(count: Int(st.st_size))
        var off = 0
        let ok = data.withUnsafeMutableBytes { b -> Bool in
            while off < b.count {
                let n = Darwin.read(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                if n == 0 { break }
                off += n
            }
            return true
        }
        guard ok else { return .missing }
        return .ok(data.prefix(off))
    }

    /// A folder the watcher may read: a real folder (not a link), owned by this user, not writable by others.
    public static func isTrustedFolder(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid() && st.st_mode & 0o022 == 0
    }
}

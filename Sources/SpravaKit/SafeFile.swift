import Darwin
import Foundation

/// Reads files in the capture folder without following symbolic links, accepting only regular files owned by
/// this user (architecture 8, step 1).
public enum SafeFile {
    /// `missing` means only that no file is there. A file that is there but may not be read (a link, another
    /// owner, no read permission, too large) is `refused`; one that could not be read just now (an I/O or
    /// resource error) is `unreadable`, worth trying again later.
    public enum Outcome { case ok(Data), refused(String), missing, unreadable(String) }

    public static func read(_ url: URL, limit: Int = 16 * 1024 * 1024) -> Outcome {
        var fd: Int32
        repeat { fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) } while fd < 0 && errno == EINTR
        if fd < 0 { return openFailure(errno) }
        defer { close(fd) }
        return read(fd: fd, limit: limit)
    }

    /// What a failed `open` means for the caller.
    static func openFailure(_ code: Int32) -> Outcome {
        switch code {
        case ENOENT, ENOTDIR: .missing
        case ELOOP: .refused("a symbolic link")
        case EACCES, EPERM: .refused("not readable by this user")
        default: .unreadable(String(cString: strerror(code)))
        }
    }

    /// Checks and reads an open file; split out so a test can hand in a descriptor that fails.
    static func read(fd: Int32, limit: Int) -> Outcome {
        var st = stat()
        guard fstat(fd, &st) == 0 else { return .unreadable(String(cString: strerror(errno))) }
        guard st.st_mode & S_IFMT == S_IFREG else { return .refused("not a plain file") }
        guard st.st_uid == getuid() else { return .refused("owned by another user") }
        guard st.st_size <= limit else { return .refused("larger than \(limit) bytes") }
        var data = Data(count: Int(st.st_size))
        var off = 0
        var failure: Int32 = 0
        data.withUnsafeMutableBytes { b in
            while off < b.count {
                let n = Darwin.read(fd, b.baseAddress! + off, b.count - off)
                if n < 0 { if errno == EINTR { continue }; failure = errno; return }
                if n == 0 { break }
                off += n
            }
        }
        guard failure == 0 else { return .unreadable(String(cString: strerror(failure))) }
        return .ok(data.prefix(off))
    }

    /// A folder the watcher may read: a real folder (not a link), owned by this user, not writable by others.
    public static func isTrustedFolder(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return st.st_mode & S_IFMT == S_IFDIR && st.st_uid == getuid() && st.st_mode & 0o022 == 0
    }
}

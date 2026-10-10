import Darwin
import Foundation

/// A retained handle to a trusted state directory. Reads, temporary writes and renames use this handle rather
/// than resolving its path again, so replacing a directory entry with a link cannot redirect those operations.
public final class StateDirectory: @unchecked Sendable {
    private let fd: Int32
    private let device: dev_t
    private let inode: ino_t
    private let root: URL?
    private let parent: StateDirectory?
    private let name: String?
    private let flush: Flush

    struct Flush: Sendable {
        var directory: @Sendable (Int32) throws -> Void = { try AtomicFile.flushToDisk($0, step: "flush state directory") }
    }

    private init(fd: Int32, root: URL? = nil, parent: StateDirectory? = nil, name: String? = nil, flush: Flush) throws {
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw AtomicFile.Failure(step: "inspect state directory", code: errno) }
        guard Self.trusted(info) else { throw AtomicFile.Failure(step: "untrusted state directory", code: EPERM) }
        self.fd = fd
        device = info.st_dev
        inode = info.st_ino
        self.root = root
        self.parent = parent
        self.name = name
        self.flush = flush
    }

    deinit { close(fd) }

    private static func trusted(_ info: stat) -> Bool {
        info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid() && info.st_mode & 0o022 == 0
    }

    private static func component(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
            throw AtomicFile.Failure(step: "invalid state entry name", code: EINVAL)
        }
    }

    /// Only an absent directory returns nil. Links, invalid parents and untrusted entries throw.
    public static func open(_ url: URL, create: Bool = false) throws -> StateDirectory? {
        try open(url, create: create, flush: Flush())
    }

    static func open(_ url: URL, create: Bool, flush: Flush) throws -> StateDirectory? {
        guard url.isFileURL else { throw AtomicFile.Failure(step: "state directory needs a file URL", code: EINVAL) }
        var descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT, create {
            try createRoot(url, flush: flush)
            descriptor = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT, !create { return nil }
            throw AtomicFile.Failure(step: "open state directory", code: errno)
        }
        let directory: StateDirectory
        do { directory = try StateDirectory(fd: descriptor, root: url, flush: flush) }
        catch { close(descriptor); throw error }
        try directory.validate()
        if create { try flushParent(url, flush: flush) }
        return directory
    }

    /// Create one entry at a time, flushing its parent before creating descendants. Failed creation may leave an
    /// empty directory: deleting by name could delete another process's replacement. Retries reflush the chain.
    private static func createRoot(_ url: URL, flush: Flush) throws {
        try component(url.lastPathComponent)
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        guard parent.path != url.path else { throw AtomicFile.Failure(step: "create state root", code: EINVAL) }
        var descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT {
            try createRoot(parent, flush: flush)
            descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        guard descriptor >= 0 else { throw AtomicFile.Failure(step: "open state root's parent", code: errno) }
        defer { close(descriptor) }
        try flushParent(parent, flush: flush)
        let made = mkdirat(descriptor, url.lastPathComponent, 0o700) == 0
        guard made || errno == EEXIST else { throw AtomicFile.Failure(step: "create state root", code: errno) }
        try flush.directory(descriptor)
    }

    private static func flushParent(_ url: URL, flush: Flush) throws {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath()
        let descriptor = Darwin.open(parent.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw AtomicFile.Failure(step: "open state root's parent", code: errno) }
        defer { close(descriptor) }
        try flush.directory(descriptor)
    }

    public func directory(_ name: String, create: Bool = false) throws -> StateDirectory? {
        try directory(name, create: create, beforeOpen: {})
    }

    func directory(_ name: String, create: Bool, beforeOpen: () throws -> Void) throws -> StateDirectory? {
        try Self.component(name)
        try validate()
        try beforeOpen()
        var descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT, create {
            try validate()
            let made = mkdirat(fd, name, 0o700) == 0
            guard made || errno == EEXIST else {
                throw AtomicFile.Failure(step: "create state directory", code: errno)
            }
            descriptor = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        }
        if descriptor < 0 {
            if errno == ENOENT, !create { try validate(); return nil }
            throw AtomicFile.Failure(step: "open child state directory", code: errno)
        }
        let child: StateDirectory
        do { child = try StateDirectory(fd: descriptor, parent: self, name: name, flush: flush) }
        catch { close(descriptor); throw error }
        try child.validate()
        if create { try flush.directory(fd) }
        return child
    }

    /// The retained inode must still occupy its original trusted directory entry.
    private func validate() throws {
        var info = stat()
        let result: Int32
        if let parent, let name {
            try parent.validate()
            result = fstatat(parent.fd, name, &info, AT_SYMLINK_NOFOLLOW)
        } else if let root {
            result = lstat(root.path, &info)
        } else { throw AtomicFile.Failure(step: "state directory has no anchor", code: EINVAL) }
        guard result == 0, Self.trusted(info), info.st_dev == device, info.st_ino == inode else {
            throw AtomicFile.Failure(step: "state directory changed", code: ESTALE)
        }
    }

    public func read(_ name: String, limit: Int = 16 * 1024 * 1024) throws -> SafeFile.Outcome {
        try read(name, limit: limit, beforeOpen: {})
    }

    /// Test boundary: the directory can be replaced after validation and before openat.
    func read(_ name: String, limit: Int, beforeOpen: () throws -> Void) throws -> SafeFile.Outcome {
        try Self.component(name)
        try validate()
        try beforeOpen()
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        let outcome: SafeFile.Outcome
        if file < 0 { outcome = SafeFile.openFailure(errno) }
        else {
            defer { close(file) }
            outcome = SafeFile.read(fd: file, limit: limit)
        }
        try validate()
        return outcome
    }

    public func write(_ data: Data, to name: String) throws {
        try write(data, to: name, beforeOpen: {})
    }

    private func flushAnchors() throws {
        if let parent {
            try parent.flushAnchors()
            try flush.directory(parent.fd)
        } else if let root { try Self.flushParent(root, flush: flush) }
    }

    func write(_ data: Data, to name: String, beforeOpen: () throws -> Void,
               beforePublish: (String) throws -> Void = { _ in }) throws {
        try Self.component(name)
        try validate()
        try flushAnchors()
        try beforeOpen()
        let temporary = ".\(UUID().uuidString).tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw AtomicFile.Failure(step: "create state temporary file", code: errno) }
        var renamed = false
        defer { close(file); if !renamed { unlinkat(fd, temporary, 0) } }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw AtomicFile.Failure(step: "write state file", code: errno)
                }
                guard written > 0 else { throw AtomicFile.Failure(step: "write state file", code: EIO) }
                offset += written
            }
        }
        try AtomicFile.flushToDisk(file, step: "flush state file")
        try beforePublish(temporary)
        try validate()
        guard renameat(fd, temporary, fd, name) == 0 else { throw AtomicFile.Failure(step: "rename state file", code: errno) }
        renamed = true
        try flush.directory(fd)
        try validate()
    }
}

import Darwin
import Foundation
import SpravaKit

/// A binder's `.sprava` folder, held open with the binder folder that contains it. Backup reads and writes its
/// files (`backup-id`, `folder-metadata.json`) through these handles, so a link put in place of `.sprava` after it
/// was checked, or a binder moved away meanwhile, is never followed or written into. The binder folder itself may
/// be reached through a link (the Shelf allows that) and may be writable by its group: it is opened by its
/// resolved path, without the trust rules for Sprava's private state.
final class BinderSprava {
    private let binder: Int32
    private let fd: Int32

    private init(binder: Int32, fd: Int32) {
        self.binder = binder
        self.fd = fd
    }

    deinit {
        close(fd)
        close(binder)
    }

    /// Nil when the binder has no `.sprava` and `create` is false. Throws when the binder or `.sprava` is not a
    /// folder (a link in place of `.sprava` among them); a new `.sprava` is flushed into the binder before it is used.
    static func open(_ folder: URL, create: Bool) throws -> BinderSprava? {
        let resolved = folder.resolvingSymlinksInPath().path
        let binder = Darwin.open(resolved, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard binder >= 0 else { throw Backup.Failure(message: "\(folder.lastPathComponent) is not there any more, or is not a folder") }
        var created = false
        var fd = openat(binder, ".sprava", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT {
            guard create else { close(binder); return nil }
            guard mkdirat(binder, ".sprava", 0o700) == 0 || errno == EEXIST else {
                close(binder)
                throw Backup.Failure(message: "\(folder.lastPathComponent)/.sprava could not be made")
            }
            created = true
            fd = openat(binder, ".sprava", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fd >= 0 else {
            close(binder)
            throw Backup.Failure(message: "\(folder.lastPathComponent)/.sprava is not a folder")
        }
        let handle = BinderSprava(binder: binder, fd: fd)
        if created { try AtomicFile.flushToDisk(binder, step: "flush the binder folder after making .sprava") }
        return handle
    }

    /// A regular file of this user in `.sprava`, never through a link.
    func read(_ name: String, limit: Int) -> SafeFile.Outcome {
        var file: Int32
        repeat { file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK) } while file < 0 && errno == EINTR
        if file < 0 { return SafeFile.openFailure(errno) }
        defer { close(file) }
        return SafeFile.read(fd: file, limit: limit)
    }

    /// Replaces `name` in `.sprava` atomically: a new file, flushed, renamed over the old one, and the folder flushed.
    func write(_ data: Data, to name: String) throws {
        let temporary = ".\(UUID().uuidString).tmp"
        let file = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw Backup.Failure(message: ".sprava/\(name) could not be written (\(String(cString: strerror(errno))))") }
        var renamed = false
        defer {
            close(file)
            if !renamed { unlinkat(fd, temporary, 0) }
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(file, bytes.baseAddress! + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                guard written > 0 else { throw Backup.Failure(message: ".sprava/\(name) could not be written") }
                offset += written
            }
        }
        try AtomicFile.flushToDisk(file, step: "flush .sprava/\(name)")
        guard renameat(fd, temporary, fd, name) == 0 else {
            throw Backup.Failure(message: ".sprava/\(name) could not be replaced (\(String(cString: strerror(errno))))")
        }
        renamed = true
        try AtomicFile.flushToDisk(fd, step: "flush .sprava")
    }
}
